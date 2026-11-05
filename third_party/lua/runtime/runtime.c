#define _POSIX_C_SOURCE 200809L
#include "internal.h"
#include <stdatomic.h>
#include <strings.h>

unsigned char es_null_token;
static _Atomic size_t es_detached_bytes;
static _Thread_local uint64_t es_random_state;
static _Thread_local int es_random_initialized;
static eslua_number_fn es_number_hook;
static eslua_log_fn es_load_log_hook;
lua_State *es_module_bind(lua_State *L);

void eslua_set_number_format(eslua_number_fn format) { es_number_hook = format; }
void eslua_set_load_log(eslua_log_fn log) { es_load_log_hook = log; }

size_t es_number_text(double value, int argument, char *out, size_t capacity) {
    if (capacity < 64) return 0;
    if (es_number_hook) {
        size_t written = es_number_hook(value, argument, (unsigned char *)out, capacity);
        if (written && written < capacity) return written;
    }
    int n;
    if (isnan(value)) n = snprintf(out, capacity, "%snan", argument && signbit(value) ? "-" : "");
    else if (isinf(value)) n = snprintf(out, capacity, "%sinf", value < 0 ? "-" : "");
    else n = snprintf(out, capacity, "%.17g", argument && value == 0 ? 0.0 : value);
    if (n < 0 || (size_t)n >= capacity) return 0;
    return (size_t)n;
}

static uint64_t es_clock(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0;
    return (uint64_t)now.tv_sec * UINT64_C(1000000000) + (uint64_t)now.tv_nsec;
}

es_context *es_context_of(lua_State *L) {
    void *ud = NULL;
    lua_getallocf(L, &ud);
    return ud;
}

void *es_allocate(es_context *ctx, void *old, size_t size) {
    es_block *block = old ? (es_block *)old - 1 : NULL;
    size_t before = block ? block->h.size + sizeof(*block) : 0;
    if (size == 0) { es_release(ctx, old); return NULL; }
    if (size > SIZE_MAX - sizeof(*block) || ctx->stats.current_bytes < before || ctx->stats.current_bytes - before > ctx->options.memory_limit ||
        size + sizeof(*block) > ctx->options.memory_limit - (ctx->stats.current_bytes - before)) {
        ctx->sticky = ESLUA_MEMORY;
        ctx->failure = "script memory limit exceeded";
        return NULL;
    }
    es_block *prev = block ? block->h.prev : NULL;
    es_block *next = block ? block->h.next : ctx->blocks;
    es_block *temporary_prev = block ? block->h.temporary_prev : NULL;
    es_block *temporary_next = block ? block->h.temporary_next : NULL;
    uint64_t transient = block ? block->h.transient : 0;
    es_block *grown = realloc(block, sizeof(*grown) + size);
    if (!grown) {
        ctx->sticky = ESLUA_MEMORY;
        ctx->failure = "script allocation failed";
        return NULL;
    }
    grown->h.prev = prev;
    grown->h.next = next;
    grown->h.size = size;
    grown->h.transient = transient;
    grown->h.temporary_prev = temporary_prev;
    grown->h.temporary_next = temporary_next;
    if (prev) prev->h.next = grown; else ctx->blocks = grown;
    if (next) next->h.prev = grown;
    if (transient) {
        if (temporary_prev) temporary_prev->h.temporary_next = grown; else ctx->temporaries = grown;
        if (temporary_next) temporary_next->h.temporary_prev = grown;
    }
    ctx->stats.current_bytes = ctx->stats.current_bytes - before + sizeof(*grown) + size;
    if (ctx->stats.current_bytes > ctx->stats.peak_bytes) ctx->stats.peak_bytes = ctx->stats.current_bytes;
    return grown + 1;
}

static void es_unlink(es_context *ctx, es_block *block) {
    if (block->h.prev) block->h.prev->h.next = block->h.next; else ctx->blocks = block->h.next;
    if (block->h.next) block->h.next->h.prev = block->h.prev;
    if (block->h.transient) {
        if (block->h.temporary_prev) block->h.temporary_prev->h.temporary_next = block->h.temporary_next; else ctx->temporaries = block->h.temporary_next;
        if (block->h.temporary_next) block->h.temporary_next->h.temporary_prev = block->h.temporary_prev;
    }
    ctx->stats.current_bytes -= sizeof(*block) + block->h.size;
}

static void es_detach(es_context *ctx, void *ptr) {
    if (!ptr) return;
    es_block *block = (es_block *)ptr-1;
    size_t bytes = sizeof(*block)+block->h.size;
    es_unlink(ctx, block);
    atomic_fetch_add_explicit(&es_detached_bytes, bytes, memory_order_relaxed);
}

static void es_detach_errors(es_context *ctx, eslua_result *result) {
    if (ctx->errors) {
        es_detach(ctx, ctx->errors);
        result->errors = ctx->errors;
        result->error_count = ctx->error_count;
    }
    ctx->errors = NULL;
    ctx->error_count = ctx->error_capacity = 0;
}

void es_release(es_context *ctx, void *ptr) {
    if (!ptr) return;
    es_block *block = (es_block *)ptr - 1;
    es_unlink(ctx, block);
    free(block);
}

void es_transient(es_context *ctx, void *ptr) {
    if (!ptr) return;
    es_block *block = (es_block *)ptr - 1;
    if (!block->h.transient) {
        block->h.temporary_prev = NULL;
        block->h.temporary_next = ctx->temporaries;
        if (ctx->temporaries) ctx->temporaries->h.temporary_prev = block;
        ctx->temporaries = block;
    }
    block->h.transient = ++ctx->module_serial;
}

static void *es_lua_allocate(void *ud, void *ptr, size_t old_size, size_t new_size) {
    (void)old_size;
    return es_allocate(ud, ptr, new_size);
}

int es_fail(lua_State *L, int status, const char *message) {
    es_context *ctx = es_context_of(L);
    if (!ctx->sticky) { ctx->sticky = status; ctx->failure = message; }
    return luaL_error(L, "%s", ctx->failure ? ctx->failure : message);
}

static void es_check_abort(lua_State *L) {
    es_debug_check(L);
    es_context *ctx = es_context_of(L);
    if (ctx->sticky) es_fail(L, ctx->sticky, ctx->failure ? ctx->failure : "script aborted");
}

void es_append(lua_State *L, es_buffer *out, const void *data, size_t len) {
    es_context *ctx = es_context_of(L);
    if (len > ctx->options.output_limit || out->len > ctx->options.output_limit - len)
        es_fail(L, ESLUA_LIMIT, "script output limit exceeded");
    size_t need = out->len + len;
    if (need > out->cap) {
        size_t cap = out->cap ? out->cap : 128;
        while (cap < need) {
            if (cap > ctx->options.output_limit / 2) { cap = ctx->options.output_limit; break; }
            cap *= 2;
        }
        void *grown = es_allocate(ctx, out->data, cap);
        if (!grown) es_fail(L, ESLUA_MEMORY, "script allocation failed");
        out->data = grown;
        out->cap = cap;
    }
    if (len) memcpy(out->data + out->len, data, len);
    out->len = need;
}

void es_byte(lua_State *L, es_buffer *out, unsigned char value) { es_append(L, out, &value, 1); }

static void es_snapshot(es_context *ctx) { ctx->stats.elapsed_ns = es_clock() - ctx->started; }

static void es_kill(lua_State *L) {
    es_context *ctx = es_context_of(L);
    const char *text = "Script killed by user with SCRIPT KILL...";
    if (!ctx->options.identifier.len) { es_fail(L, ESLUA_KILLED, text); return; }
    const char *source = ctx->library ? "@user_function" : "@user_script";
    int line = 1;
    lua_Debug frame;
    for (int level = 0; lua_getstack(L, level, &frame); level++) {
        lua_getinfo(L, "Sl", &frame);
        if (frame.currentline > 0 && frame.what && strcmp(frame.what, "C")) { line = frame.currentline; if (frame.source) source = frame.source; break; }
    }
    size_t need = strlen(text) + strlen(source) + ctx->options.identifier.len + 64;
    char *message = es_allocate(ctx, NULL, need);
    if (!message) { es_fail(L, ESLUA_MEMORY, "script memory limit exceeded"); return; }
    es_transient(ctx, message);
    int n = snprintf(message, need, "%s script: %.*s, on %s:%d.", text, (int)ctx->options.identifier.len, (const char *)ctx->options.identifier.data, source, line);
    if (n < 0) message[0] = 0;
    es_fail(L, ESLUA_KILLED, message);
}

static void es_hook(lua_State *L, lua_Debug *debug) {
    es_context *ctx = es_context_of(L);
    if (debug->event == LUA_HOOKCOUNT) {
        if (UINT64_MAX - ctx->stats.instructions < ctx->options.hook_count) ctx->stats.instructions = UINT64_MAX;
        else ctx->stats.instructions += ctx->options.hook_count;
    }
    es_debug_hook(L, debug);
    es_check_abort(L);
    if (ctx->options.instruction_limit && ctx->stats.instructions >= ctx->options.instruction_limit)
        es_fail(L, ESLUA_LIMIT, "script instruction limit exceeded");
    es_snapshot(ctx);
    if (ctx->loading && ctx->stats.elapsed_ns / UINT64_C(1000000) >= 500) es_fail(L, ESLUA_LIMIT, "FUNCTION LOAD timeout");
    if (!es_debug_active(L) && ctx->callbacks.busy && ctx->options.busy_threshold_ms &&
        ctx->stats.elapsed_ns / UINT64_C(1000000) >= ctx->options.busy_threshold_ms) {
        int32_t action = ctx->callbacks.busy(ctx->callbacks.opaque, ctx->wrote, &ctx->stats);
        if (action == ESLUA_ABORT) es_fail(L, ESLUA_KILLED, "script aborted by host policy");
        if (action == ESLUA_KILL_READONLY && !ctx->wrote) es_kill(L);
    }
}

static int es_pcall(lua_State *L) {
    int n = lua_gettop(L);
    luaL_checkany(L, 1);
    int status = lua_pcall(L, n - 1, LUA_MULTRET, 0);
    es_context_of(L)->host_error_origin = 0;
    es_check_abort(L);
    lua_pushboolean(L, status == LUA_OK);
    lua_insert(L, 1);
    return lua_gettop(L);
}

static int es_xpcall_error(lua_State *L) {
    es_context *ctx = es_context_of(L);
    ctx->host_error_origin = 0;
    if (ctx->sticky) {
        lua_pushstring(L, ctx->failure ? ctx->failure : "script aborted");
        return 1;
    }
    lua_pushvalue(L, lua_upvalueindex(1));
    lua_pushvalue(L, 1);
    lua_call(L, 1, 1);
    return 1;
}

static int es_xpcall(lua_State *L) {
    lua_settop(L, 2);
    int n = 2;
    luaL_checktype(L, 2, LUA_TFUNCTION);
    lua_pushvalue(L, 2);
    lua_pushcclosure(L, es_xpcall_error, 1);
    lua_remove(L, 2);
    lua_insert(L, 1);
    int status = lua_pcall(L, n - 2, LUA_MULTRET, 1);
    es_context_of(L)->host_error_origin = 0;
    lua_remove(L, 1);
    es_check_abort(L);
    lua_pushboolean(L, status == LUA_OK);
    lua_insert(L, 1);
    return lua_gettop(L);
}

static int es_global_read(lua_State *L) { return luaL_error(L, "Script attempted to access nonexistent global variable '%s'", lua_tostring(L, 2)); }


static eslua_arg *es_arguments(lua_State *L, int first, int *count) {
    es_context *ctx = es_context_of(L);
    int n = lua_gettop(L) - first + 1;
    if (n < 0 || (size_t)n > SIZE_MAX / sizeof(eslua_arg)) luaL_error(L, "invalid argument count");
    for (int i = 0; i < n; i++) {
        int type = lua_type(L, first + i);
        if (type != LUA_TSTRING && type != LUA_TNUMBER) luaL_error(L, "Lua redis arguments must be strings or integers");
    }
    eslua_arg *args = n ? es_allocate(ctx, NULL, (size_t)n * sizeof(*args)) : NULL;
    if (n && !args) es_fail(L, ESLUA_MEMORY, "script allocation failed");
    es_transient(ctx, args);
    for (int i = 0; i < n; i++) {
        int numeric = lua_type(L, first + i) == LUA_TNUMBER;
        if (numeric) {
            char text[64];
            size_t written = es_number_text(lua_tonumber(L, first + i), 1, text, sizeof(text));
            if (!written) luaL_error(L, "number conversion failed");
            lua_pushlstring(L, text, written);
            lua_replace(L, first + i);
        }
        args[i].data = (const unsigned char *)lua_tolstring(L, first + i, &args[i].len);
    }
    *count = n;
    return args;
}

static int es_command_error(lua_State *L, int catch_error, const char *text) {
    lua_pushfstring(L, "ERR %s", text);
    if (!catch_error) { es_context_of(L)->host_error_origin = 1; return lua_error(L); }
    lua_newtable(L); lua_pushvalue(L, -2); lua_setfield(L, -2, "err"); return 1;
}

static int es_command(lua_State *L, int catch_error) {
    es_context *ctx = es_context_of(L);
    es_check_abort(L);
    if (lua_gettop(L) < 1) return es_command_error(L, catch_error, "Please specify at least one argument for this redis lib call");
    for (int i = 1; i <= lua_gettop(L); i++) if (lua_type(L, i) != LUA_TSTRING && lua_type(L, i) != LUA_TNUMBER) return es_command_error(L, catch_error, "Lua redis lib command arguments must be strings or integers");
    int n;
    if (!ctx->callbacks.command) return luaL_error(L, "command bridge unavailable");
    eslua_arg *args = es_arguments(L, 1, &n);
    es_snapshot(ctx);
    es_debug_command(L, n, args);
    eslua_result result = ctx->callbacks.command(ctx->callbacks.opaque, ctx->script_resp, (size_t)n, args, &ctx->stats);
    if (result.write_effect) ctx->wrote = 1;
    es_debug_reply(L, &result);
    es_release(ctx, args);
    lua_settop(L, 0);
    if (result.status != ESLUA_OK) return es_fail(L, ESLUA_BRIDGE, "command bridge failed");
    if (!result.data || result.len == 0 || result.len > ctx->options.output_limit)
        return es_fail(L, ESLUA_BRIDGE, "invalid command bridge response");
    es_parse_response(L, result.data, result.len);
    if (!catch_error && lua_type(L, -1) == LUA_TTABLE) {
        lua_pushliteral(L, "err"); lua_rawget(L, -2);
        if (lua_type(L, -1) == LUA_TSTRING) {
            ctx->host_error_origin = 1;
            return lua_error(L);
        }
        lua_pop(L, 1);
    }
    es_check_abort(L);
    return 1;
}

static int es_call(lua_State *L) { return es_command(L, 0); }
int es_debug_call(lua_State *L) { return es_command(L, 0); }
static int es_command_pcall(lua_State *L) { return es_command(L, 1); }
static int es_setresp(lua_State *L) {
    if (lua_gettop(L) != 1) return es_command_error(L, 0, "redis.setresp() requires one argument.");
    lua_Integer resp = lua_tointeger(L, 1);
    if (resp != 2 && resp != 3) return es_command_error(L, 0, "RESP version must be 2 or 3.");
    es_context_of(L)->script_resp = (int32_t)resp;
    return 0;
}

static int es_tagged_reply(lua_State *L, const char *key) {
    if (lua_gettop(L) != 1 || lua_type(L, 1) != LUA_TSTRING) {
        lua_newtable(L); lua_pushliteral(L, "ERR wrong number or type of arguments"); lua_setfield(L, -2, "err"); return 1;
    }
    size_t len;
    const char *text = luaL_checklstring(L, 1, &len);
    const char *zero=memchr(text,0,len);if(zero)len=(size_t)(zero-text);
    if(!strcmp(key,"err")&&len&&text[0]=='-'){text++;len--;}
    lua_newtable(L);
    if(!strcmp(key,"err")) {
        int prefixed=!memchr(text,' ',len);
        size_t trimmed=len;while(trimmed&&(text[trimmed-1]=='\r'||text[trimmed-1]=='\n'))trimmed--;
        if(prefixed){lua_pushliteral(L,"ERR ");lua_pushlstring(L,text,trimmed);lua_concat(L,2);}
        else lua_pushlstring(L,text,trimmed);
    } else lua_pushlstring(L, text, len);
    lua_setfield(L, -2, key);
    return 1;
}
static int es_status_reply(lua_State *L) { return es_tagged_reply(L, "ok"); }
static int es_error_reply(lua_State *L) { return es_tagged_reply(L, "err"); }
static int es_replicate_commands(lua_State *L) { lua_pushboolean(L, 1); return 1; }
static int es_set_repl(lua_State *L) {
    es_context *ctx = es_context_of(L);
    if (lua_gettop(L) != 1) return es_command_error(L, 0, "redis.set_repl() requires one argument.");
    lua_Integer mask = lua_tointeger(L, 1);
    if (mask < 0 || mask > 3) return es_command_error(L, 0, "Invalid replication flags. Use REPL_AOF, REPL_REPLICA, REPL_ALL or REPL_NONE.");
    if (ctx->callbacks.propagation && !ctx->callbacks.propagation(ctx->callbacks.opaque, (int32_t)mask)) return es_command_error(L, 0, "Invalid replication flags");
    return 0;
}
static int es_acl_check(lua_State *L) {
    es_context *ctx = es_context_of(L);
    if (lua_gettop(L) < 1) return es_command_error(L, 0, "Please specify at least one argument for this redis lib call");
    for (int i = 1; i <= lua_gettop(L); i++) if (lua_type(L, i) != LUA_TSTRING && lua_type(L, i) != LUA_TNUMBER) return es_command_error(L, 0, "Lua redis lib command arguments must be strings or integers");
    int count;
    eslua_arg *args = es_arguments(L, 1, &count);
    if (!ctx->callbacks.acl_check) return luaL_error(L, "ACL check is unavailable");
    eslua_result result = ctx->callbacks.acl_check(ctx->callbacks.opaque, (size_t)count, args);
    es_release(ctx, args);
    if (result.status) return es_fail(L, result.status, "ACL check failed");
    if (result.len && result.data[0] == '-') {
        lua_pushlstring(L, (const char *)result.data + 1, result.len > 3 ? result.len - 3 : 0);
        ctx->host_error_origin = 1;
        return lua_error(L);
    }
    lua_pushboolean(L, result.len >= 2 && result.data[1] == '1'); return 1;
}
static int es_os_clock(lua_State *L) { lua_pushnumber(L, (lua_Number)clock()/CLOCKS_PER_SEC); return 1; }
static int es_randomseed(lua_State *L) {
    uint32_t seed = (uint32_t)luaL_checknumber(L, 1);
    es_random_state = ((uint64_t)seed << 16) | 0x330e;
    es_random_initialized = 1;
    return 0;
}
static int es_random(lua_State *L) {
    if (!es_random_initialized) { es_random_state = UINT64_C(0x1234abcd330e); es_random_initialized = 1; }
    es_random_state = (es_random_state * UINT64_C(0x5deece66d) + 11) & UINT64_C(0xffffffffffff);
    double r = (double)(es_random_state >> 17) / 2147483647.0;
    switch (lua_gettop(L)) {
    case 0: lua_pushnumber(L, r); break;
    case 1: { int u = luaL_checkint(L, 1); luaL_argcheck(L, u >= 1, 1, "interval is empty"); lua_pushnumber(L, floor(r*u)+1); break; }
    case 2: { int lo = luaL_checkint(L, 1), hi = luaL_checkint(L, 2); luaL_argcheck(L, lo <= hi, 2, "interval is empty"); lua_pushnumber(L, floor(r*((double)hi-lo+1))+lo); break; }
    default: return luaL_error(L, "wrong number of arguments");
    }
    return 1;
}
typedef struct es_registered {
    eslua_function_info info;
    int reference;
} es_registered;

struct eslua_library {
    es_context context;
    es_registered *functions;
    size_t count;
    eslua_library *engine, *engine_next;
    size_t references;
    int retired, active;
};

static _Thread_local eslua_library *es_functions_engine, *es_functions_engines;

static es_context *es_library_context(eslua_library *library) { return library->engine ? &library->engine->context : &library->context; }

static eslua_arg es_copy_arg(lua_State *L, int index) {
    size_t len;
    const char *text = luaL_checklstring(L, index, &len);
    unsigned char *copy = es_allocate(es_context_of(L), NULL, len ? len : 1);
    if (!copy) es_fail(L, ESLUA_MEMORY, "script memory limit exceeded");
    if (len) memcpy(copy, text, len);
    return (eslua_arg){copy, len};
}

static void es_error_location(lua_State *L,const char **source,int *line) {
    *source=es_context_of(L)->library?"@user_function":"@user_script";*line=1;
    lua_Debug debug;
    for(int level=1;lua_getstack(L,level,&debug);level++){
        lua_getinfo(L,"Sl",&debug);
        if(debug.currentline>0&&debug.what&&strcmp(debug.what,"C")){
            *line=debug.currentline;if(debug.source)*source=debug.source;break;
        }
    }
}

static int es_internal_error_handler(lua_State *L) {
    lua_settop(L,1);
    int type=lua_type(L,1);
    if(type==LUA_TTABLE)lua_pushvalue(L,1);
    else{
        lua_newtable(L);
        if(type==LUA_TSTRING||type==LUA_TNUMBER){lua_pushliteral(L,"ERR ");lua_pushvalue(L,1);lua_concat(L,2);}
        else if(type==LUA_TNIL)lua_pushliteral(L,"ERR nil");
        else if(type==LUA_TBOOLEAN)lua_pushstring(L,lua_toboolean(L,1)?"ERR true":"ERR false");
        else lua_pushfstring(L,"ERR %s: %p",lua_typename(L,type),lua_topointer(L,1));
        lua_setfield(L,-2,"err");
    }
    int table=lua_gettop(L),line;const char *source;es_error_location(L,&source,&line);
    lua_pushliteral(L,"source");lua_pushstring(L,source);lua_rawset(L,table);
    lua_pushliteral(L,"line");lua_pushinteger(L,line);lua_rawset(L,table);
    return 1;
}

static uint32_t es_flag_bit(const char *flag, size_t len) {
    const char *names[] = {"no-writes", "allow-oom", "allow-stale", "no-cluster", "allow-cross-slot-keys"};
    for (int j = 0; j < 5; j++) if (strlen(names[j]) == len && !strncasecmp(flag, names[j], len)) return 1u << j;
    return 0;
}

static int es_register_key(const char *key, size_t len) {
    const char *names[] = {"function_name", "callback", "description", "flags"};
    for (int j = 0; j < 4; j++) if (strlen(names[j]) == len && !strncasecmp(key, names[j], len)) return j;
    return -1;
}

static int es_register(lua_State *L) {
    es_context *ctx = es_context_of(L);
    if (!ctx->loading || !ctx->library) return luaL_error(L, "redis.register_function can only be called on FUNCTION LOAD command");
    eslua_library *library = ctx->library;
    int argc = lua_gettop(L), named = 0;
    int name_index = 1, callback_index = 2, desc_index = 0;
    uint32_t flags = 0;
    if (argc == 1) {
        if (lua_type(L, 1) != LUA_TTABLE) return es_command_error(L, 0, "calling redis.register_function with a single argument is only applicable to Lua table (representing named arguments).");
        named = 1;
        lua_settop(L, 1);
        for (int i = 0; i < 4; i++) lua_pushnil(L);
        name_index = 2; callback_index = 3; desc_index = 4;
        lua_pushnil(L);
        while (lua_next(L, 1)) {
            size_t key_len = 0;
            const char *key = lua_type(L, -2) == LUA_TSTRING ? lua_tolstring(L, -2, &key_len) : NULL;
            int slot = key ? es_register_key(key, key_len) : -1;
            if (slot < 0) return es_command_error(L, 0, "unknown argument given to redis.register_function");
            lua_replace(L, 2 + slot);
        }
        if (!lua_isnil(L, desc_index) && !lua_isstring(L, desc_index)) return es_command_error(L, 0, "description argument given to redis.register_function must be a string");
        if (!lua_isnil(L, 5)) {
            if (lua_type(L, 5) != LUA_TTABLE) return es_command_error(L, 0, "flags argument to redis.register_function must be a table representing function flags");
            size_t count = lua_objlen(L, 5);
            for (size_t i = 1; i <= count; i++) {
                lua_rawgeti(L, 5, (int)i);
                size_t flag_len = 0;
                const char *flag = lua_type(L, -1) == LUA_TSTRING ? lua_tolstring(L, -1, &flag_len) : NULL;
                uint32_t bit = flag ? es_flag_bit(flag, flag_len) : 0;
                if (!bit) return es_command_error(L, 0, "unknown flag given");
                flags |= bit; lua_pop(L, 1);
            }
        }
        if (lua_isnil(L, name_index)) return es_command_error(L, 0, "redis.register_function must get a function name argument");
        if (lua_isnil(L, callback_index)) return es_command_error(L, 0, "redis.register_function must get a callback argument");
    } else if (argc != 2) return es_command_error(L, 0, "wrong number of arguments to redis.register_function");
    if (!lua_isstring(L, name_index)) return es_command_error(L, 0, named ? "function_name argument given to redis.register_function must be a string" : "first argument to redis.register_function must be a string");
    if (lua_type(L, callback_index) != LUA_TFUNCTION) return es_command_error(L, 0, named ? "callback argument given to redis.register_function must be a function" : "second argument to redis.register_function must be a function");
    size_t len;
    const unsigned char *name = (const unsigned char *)lua_tolstring(L, name_index, &len);
    if (!len) return es_command_error(L, 0, "Library names can only contain letters, numbers, or underscores(_) and must be at least one character long");
    for (size_t i = 0; i < len; i++) if (!((name[i] >= 'A' && name[i] <= 'Z') || (name[i] >= 'a' && name[i] <= 'z') || (name[i] >= '0' && name[i] <= '9') || name[i] == '_')) return es_command_error(L, 0, "Library names can only contain letters, numbers, or underscores(_) and must be at least one character long");
    for (size_t i = 0; i < library->count; i++) if (library->functions[i].info.name.len == len && !strncasecmp((const char *)library->functions[i].info.name.data, (const char *)name, len)) return es_command_error(L, 0, "Function already exists in the library");
    if (library->count >= SIZE_MAX/sizeof(es_registered)-1) return es_fail(L, ESLUA_MEMORY, "too many functions");
    es_registered *grown = es_allocate(ctx, library->functions, (library->count+1)*sizeof(*grown));
    if (!grown) return es_fail(L, ESLUA_MEMORY, "script memory limit exceeded");
    library->functions = grown;
    es_registered *item = &grown[library->count++]; memset(item, 0, sizeof(*item)); item->reference = LUA_NOREF;
    item->info.name = es_copy_arg(L, name_index);
    if (desc_index && !lua_isnil(L, desc_index)) item->info.description = es_copy_arg(L, desc_index);
    item->info.flags = flags;
    lua_pushvalue(L, callback_index); item->reference = luaL_ref(L, LUA_REGISTRYINDEX);
    return 0;
}

static void es_readonly_visit(lua_State *L, int index, int visited) {
    lua_pushvalue(L, index); lua_rawget(L, visited);
    int seen = lua_toboolean(L, -1);
    lua_pop(L, 1);
    if (seen) return;
    lua_pushvalue(L, index); lua_pushboolean(L, 1); lua_rawset(L, visited);
    if (lua_isreadonlytable(L, index)) return;
    lua_enablereadonlytable(L, index, 1);
    luaL_checkstack(L, 4, "nested tables too deep");
    lua_pushnil(L);
    while (lua_next(L, index)) {
        if (lua_type(L, -1) == LUA_TTABLE) es_readonly_visit(L, lua_gettop(L), visited);
        lua_pop(L, 1);
    }
}
static void es_readonly(lua_State *L, int index) {
    index = lua_absindex(L, index);
    lua_newtable(L);
    es_readonly_visit(L, index, lua_gettop(L));
    lua_pop(L, 1);
}
static int es_log(lua_State *L) {
    es_context *ctx = es_context_of(L);
    es_check_abort(L);
    int argc = lua_gettop(L);
    if (argc < 2) return es_command_error(L, 0, "redis.log() requires two arguments or more.");
    if (!lua_isnumber(L, 1)) return es_command_error(L, 0, "First argument must be a number (log level).");
    lua_Integer level = lua_tointeger(L, 1);
    if (level < 0 || level > 3) return es_command_error(L, 0, "Invalid log level.");
    eslua_log_fn log = ctx->callbacks.log ? ctx->callbacks.log : es_load_log_hook;
    if (!log) return 0;
    eslua_arg *args = es_allocate(ctx, NULL, (size_t)(argc - 1) * sizeof(*args));
    if (!args) es_fail(L, ESLUA_MEMORY, "script allocation failed");
    es_transient(ctx, args);
    size_t n = 0;
    for (int i = 2; i <= argc; i++) {
        int type = lua_type(L, i);
        if (type != LUA_TSTRING && type != LUA_TNUMBER) continue;
        args[n].data = (const unsigned char *)lua_tolstring(L, i, &args[n].len);
        n++;
    }
    log(ctx->callbacks.log ? ctx->callbacks.opaque : NULL, (int32_t)level, n, args);
    es_release(ctx, args);
    return 0;
}

static void es_function(lua_State *L, const char *name, lua_CFunction fn) { lua_pushcfunction(L, fn); lua_setfield(L, -2, name); }

static int es_library_global_read(lua_State *L) {
    es_context *ctx = es_context_of(L);
    if (ctx->loading) {
        size_t len = 0;
        const char *name = lua_tolstring(L, 2, &len);
        if (name && len == 5 && !memcmp(name, "redis", 5)) {
            lua_pushvalue(L, lua_upvalueindex(1));
            return 1;
        }
        return es_global_read(L);
    }
    lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->globals_reference);
    lua_pushvalue(L, 2); lua_gettable(L, -2); return 1;
}

static int es_unregister_library(lua_State *L);

static void es_setup_load_environment(lua_State *L) {
        es_context *ctx = es_context_of(L);
        if (ctx->load_globals_reference) {
            lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->load_globals_reference);
            lua_replace(L, LUA_GLOBALSINDEX);
            return;
        }
        lua_newtable(L);
        int load_globals = lua_gettop(L);
        lua_newtable(L);
        int load_redis = lua_gettop(L);
        es_function(L, "register_function", es_register);
        es_function(L, "log", es_log);
        const char *levels[] = {"LOG_DEBUG", "LOG_VERBOSE", "LOG_NOTICE", "LOG_WARNING"};
        for (int i = 0; i < 4; i++) { lua_pushinteger(L, i); lua_setfield(L, -2, levels[i]); }
        lua_pushliteral(L, "7.4.11"); lua_setfield(L, -2, "REDIS_VERSION");
        lua_pushinteger(L, 459787); lua_setfield(L, -2, "REDIS_VERSION_NUM");
        lua_newtable(L); es_function(L, "__index", es_global_read); lua_setmetatable(L, -2);
        lua_enablereadonlytable(L, -1, 1);
        lua_newtable(L);
        lua_pushvalue(L, load_redis); lua_pushcclosure(L, es_library_global_read, 1); lua_setfield(L, -2, "__index");
        lua_setmetatable(L, load_globals);
        lua_pop(L, 1);
        lua_enablereadonlytable(L, load_globals, 1);
        lua_pushvalue(L, load_globals); ctx->load_globals_reference = luaL_ref(L, LUA_REGISTRYINDEX);
        lua_replace(L, LUA_GLOBALSINDEX);
}

static void es_setup(lua_State *L) {
    es_context *ctx = es_context_of(L);
    const struct { const char *name; lua_CFunction open; } libs[] = {
        {"", luaopen_base}, {LUA_TABLIBNAME, luaopen_table}, {LUA_STRLIBNAME, luaopen_string}, {LUA_MATHLIBNAME, luaopen_math}
    };
    for (size_t i = 0; i < sizeof(libs)/sizeof(*libs); i++) {
        lua_pushcfunction(L, libs[i].open); lua_pushstring(L, libs[i].name); lua_call(L, 1, 0);
    }
    lua_getglobal(L, "math"); es_function(L, "random", es_random); es_function(L, "randomseed", es_randomseed); lua_pop(L, 1);
    lua_pushliteral(L, "");
    if (lua_getmetatable(L, -1)) { es_readonly(L, -1); lua_pop(L, 1); }
    lua_pop(L, 1);
    if(!ctx->library){lua_pushcfunction(L,es_internal_error_handler);lua_setglobal(L,"__redis__err__handler");}
    lua_pushcfunction(L, es_pcall); lua_setglobal(L, "pcall");
    lua_pushcfunction(L, es_xpcall); lua_setglobal(L, "xpcall");
    lua_newtable(L);
    es_function(L, "call", es_call); es_function(L, "pcall", es_command_pcall);
    es_function(L, "setresp", es_setresp); es_function(L, "status_reply", es_status_reply);
    es_function(L, "error_reply", es_error_reply); es_function(L, "sha1hex", es_sha1hex); es_function(L, "log", es_log);
    if (!ctx->library) es_function(L, "replicate_commands", es_replicate_commands);
    es_function(L, "set_repl", es_set_repl);
    const char *levels[] = {"LOG_DEBUG", "LOG_VERBOSE", "LOG_NOTICE", "LOG_WARNING"};
    for (int i = 0; i < 4; i++) { lua_pushinteger(L, i); lua_setfield(L, -2, levels[i]); }
    es_function(L, "acl_check_cmd", es_acl_check);
    if (!ctx->library) { es_function(L, "debug", es_debug_log); es_function(L, "breakpoint", es_debug_breakpoint); }
    lua_pushliteral(L, "7.4.11"); lua_setfield(L, -2, "REDIS_VERSION");
    lua_pushinteger(L, 459787); lua_setfield(L, -2, "REDIS_VERSION_NUM");
    const char *repl[] = {"REPL_NONE", "REPL_AOF", "REPL_REPLICA", "REPL_ALL"};
    for (int i = 0; i < 4; i++) { lua_pushinteger(L, i); lua_setfield(L, -2, repl[i]); }
    lua_pushinteger(L,2);lua_setfield(L,-2,"REPL_SLAVE");
    lua_setglobal(L, "redis");
    es_install_libraries(L);
    lua_newtable(L); es_function(L, "clock", es_os_clock); lua_setglobal(L, "os");
    if (ctx->numkeys > INT_MAX || ctx->argc > INT_MAX) es_fail(L, ESLUA_ARGUMENT, "too many script arguments");
    lua_createtable(L, (int)ctx->numkeys, 0);
    for (size_t i = 0; i < ctx->numkeys; i++) { lua_pushlstring(L, ctx->keys[i].data ? (const char *)ctx->keys[i].data : "", ctx->keys[i].len); lua_rawseti(L, -2, (lua_Integer)i + 1); }
    lua_setglobal(L, "KEYS");
    lua_createtable(L, (int)ctx->argc, 0);
    for (size_t i = 0; i < ctx->argc; i++) { lua_pushlstring(L, ctx->args[i].data ? (const char *)ctx->args[i].data : "", ctx->args[i].len); lua_rawseti(L, -2, (lua_Integer)i + 1); }
    lua_setglobal(L, "ARGV");
    lua_pushglobaltable(L);
    int original = lua_absindex(L, -1);
    lua_newtable(L);
    int globals = lua_absindex(L, -1);
    const char *allowed[] = {"__redis__err__handler", "_VERSION", "assert", "error", "load", "loadstring", "collectgarbage", "gcinfo", "coroutine", "ipairs", "next", "pairs", "pcall", "rawequal", "rawget", "rawset", "getmetatable", "setmetatable", "select", "tonumber", "tostring", "type", "xpcall", "unpack", "table", "string", "math", "os", "redis", "bit", "cjson", "cmsgpack", "struct", "KEYS", "ARGV", NULL};
    for (size_t i = 0; allowed[i]; i++) {
        lua_pushstring(L, allowed[i]); lua_rawget(L, original); lua_setfield(L, globals, allowed[i]);
    }
    if (ctx->options.enable_deprecated_api) {
        const char *deprecated[] = {"getfenv", "setfenv", "newproxy"};
        for (size_t i = 0; i < sizeof(deprecated)/sizeof(*deprecated); i++) {
            lua_pushstring(L, deprecated[i]); lua_rawget(L, original); lua_setfield(L, globals, deprecated[i]);
        }
    }
    lua_pushvalue(L, globals); lua_setfield(L, globals, "_G");
    if (ctx->library) {
        lua_pushnil(L); lua_setfield(L, globals, "KEYS");
        lua_pushnil(L); lua_setfield(L, globals, "ARGV");
    }
    lua_pushvalue(L, globals); lua_replace(L, LUA_GLOBALSINDEX);
    lua_newtable(L);
    es_function(L, "__index", es_global_read);
    lua_setmetatable(L, globals);
    if (lua_getmetatable(L, globals)) { es_readonly(L, -1); lua_pop(L, 1); }
    lua_pushnil(L);
    while (lua_next(L, globals)) {
        if (lua_type(L, -1) == LUA_TTABLE && !lua_rawequal(L, -1, globals)) {
            lua_pushvalue(L, -2);
            const char *name = lua_tostring(L, -1);
            int argument_table = name && (!strcmp(name, "KEYS") || !strcmp(name, "ARGV"));
            lua_pop(L, 1);
            if (!argument_table) es_readonly(L, -1);
        }
        lua_pop(L, 1);
    }
    lua_enablereadonlytable(L, globals, 1);
    lua_pushvalue(L, globals); ctx->globals_reference = luaL_ref(L, LUA_REGISTRYINDEX);
    if (ctx->library) {
        lua_pushinteger(L,0);lua_rawseti(L,LUA_REGISTRYINDEX,0);
        lua_pushcfunction(L,es_unregister_library);ctx->cleanup_reference=luaL_ref(L,LUA_REGISTRYINDEX);
        es_setup_load_environment(L);
    }
    lua_pop(L, 2);
}

static void es_load(lua_State *L, es_context *ctx) {
    const char *source = ctx->source.data ? (const char *)ctx->source.data : "";
    int status = luaL_loadbuffer(L, source, ctx->source.len, ctx->library ? "@user_function" : "@user_script");
    if (status != LUA_OK) { ctx->compile_failed=1; lua_error(L); }
}

static void es_load_cached(lua_State *L, es_context *ctx) {
    if (!ctx->scripts_reference) { lua_newtable(L); ctx->scripts_reference = luaL_ref(L, LUA_REGISTRYINDEX); }
    lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->scripts_reference);
    lua_pushlstring(L, (const char *)ctx->digest.data, ctx->digest.len);
    lua_pushvalue(L, -1); lua_rawget(L, -3);
    if (lua_type(L, -1) != LUA_TFUNCTION) {
        lua_pop(L, 1);
        es_load(L, ctx);
        lua_pushvalue(L, -2); lua_pushvalue(L, -2); lua_rawset(L, -5);
    }
    lua_replace(L, -3); lua_pop(L, 1);
}

static int es_run(lua_State *L) {
    es_context *ctx = es_context_of(L);
    if (!ctx->compile_only && !ctx->library) es_debug_begin(L);
    if (ctx->calling) {
        lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->library->functions[ctx->function_index].reference);
        lua_createtable(L, (int)ctx->numkeys, 0);
        for (size_t i = 0; i < ctx->numkeys; i++) { lua_pushlstring(L, (const char *)ctx->keys[i].data, ctx->keys[i].len); lua_rawseti(L, -2, (int)i + 1); }
        lua_createtable(L, (int)ctx->argc, 0);
        for (size_t i = 0; i < ctx->argc; i++) { lua_pushlstring(L, (const char *)ctx->args[i].data, ctx->args[i].len); lua_rawseti(L, -2, (int)i + 1); }
        lua_sethook(L, es_hook, LUA_MASKCOUNT | (ctx->debug ? LUA_MASKLINE : 0), (int)ctx->options.hook_count);
        lua_call(L, 2, 1);
        es_check_abort(L); es_serialize(L, -1, ctx->client_resp, &ctx->output); return 0;
    }
    if (ctx->loading && ctx->globals_reference) es_setup_load_environment(L);
    else if (!ctx->compile_only && !ctx->eval_reuse) es_setup(L);
    if (ctx->eval_reuse && !ctx->compile_only) {
        lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->globals_reference);
        int globals = lua_gettop(L);
        lua_enablereadonlytable(L, globals, 0);
        lua_createtable(L, (int)ctx->numkeys, 0);
        for (size_t i = 0; i < ctx->numkeys; i++) { lua_pushlstring(L, (const char *)ctx->keys[i].data, ctx->keys[i].len); lua_rawseti(L, -2, (int)i + 1); }
        lua_setfield(L, globals, "KEYS");
        lua_createtable(L, (int)ctx->argc, 0);
        for (size_t i = 0; i < ctx->argc; i++) { lua_pushlstring(L, (const char *)ctx->args[i].data, ctx->args[i].len); lua_rawseti(L, -2, (int)i + 1); }
        lua_setfield(L, globals, "ARGV");
        lua_enablereadonlytable(L, globals, 1); lua_pop(L, 1);
    }
    es_check_abort(L);
    if (ctx->digest.len) {
        es_load_cached(L, ctx);
        if (!ctx->compile_only) { lua_pushvalue(L, LUA_GLOBALSINDEX); lua_setfenv(L, -2); }
    } else es_load(L, ctx);
    es_check_abort(L);
    if (ctx->compile_only) { es_append(L, &ctx->output, "+OK\r\n", 5); return 0; }
    lua_sethook(L, es_hook, LUA_MASKCOUNT | (ctx->debug ? LUA_MASKLINE : 0), (int)ctx->options.hook_count);
    lua_call(L, 0, ctx->loading ? 0 : 1);
    es_check_abort(L);
    if (ctx->loading) {
        if (!ctx->library->count) { ctx->load_plain = 1; return luaL_error(L, "No functions registered"); }
        es_append(L, &ctx->output, "+OK\r\n", 5); return 0;
    }
    es_serialize(L, -1, ctx->client_resp, &ctx->output);
    es_check_abort(L);
    return 0;
}

static int es_outer_error(lua_State *L) {
    es_context *ctx = es_context_of(L);
    ctx->error_passthrough = ctx->host_error_origin;
    ctx->forwarded_error = ctx->host_error_origin;
    int type=lua_type(L,1);
    if(type==LUA_TTABLE){
        lua_pushliteral(L,"ignore_error_stats_update");lua_rawget(L,1);
        ctx->forwarded_error=lua_type(L,-1)==LUA_TBOOLEAN&&lua_toboolean(L,-1);lua_pop(L,1);
        lua_pushliteral(L,"err");lua_rawget(L,1);
        if(lua_isstring(L,-1)){lua_tolstring(L,-1,NULL);ctx->error_passthrough=1;}
        else{lua_pop(L,1);lua_pushliteral(L,"unknown error");}
    } else if(type==LUA_TSTRING||type==LUA_TNUMBER){lua_pushvalue(L,1);lua_tolstring(L,-1,NULL);}
    else if(type==LUA_TNIL)lua_pushliteral(L,"nil");
    else if(type==LUA_TBOOLEAN)lua_pushstring(L,lua_toboolean(L,1)?"true":"false");
    else lua_pushfstring(L,"%s: %p",lua_typename(L,type),lua_topointer(L,1));
    if(lua_type(L,-1)==LUA_TSTRING){
        size_t len;const char *text=lua_tolstring(L,-1,&len);const char *zero=memchr(text,0,len);
        if(zero){lua_pushlstring(L,text,(size_t)(zero-text));lua_replace(L,-2);}
    }
    if ((!ctx->sticky || !ctx->failure) && !ctx->loading && !ctx->compile_failed && ctx->options.identifier.len && lua_type(L, -1) == LUA_TSTRING) {
        int line;const char *source;es_error_location(L,&source,&line);
        lua_pushliteral(L, " script: ");
        lua_pushlstring(L, (const char *)ctx->options.identifier.data, ctx->options.identifier.len);
        lua_pushfstring(L, ", on %s:%d.", source, line);
        lua_concat(L, 4);
    }
    return 1;
}

static int es_protected(lua_State *L) {
    lua_settop(L, 0);
    lua_pushcfunction(L, es_outer_error);
    lua_pushcfunction(L, es_run);
    int status = lua_pcall(L, 0, 0, 1);
    es_debug_finish(L);
    lua_gc(L, status || es_context_of(L)->sticky ? LUA_GCCOLLECT : LUA_GCSTEP, 1);
    if (status) return lua_error(L);
    return 0;
}

static eslua_options es_options(const eslua_options *input) {
    eslua_options out = input ? *input : (eslua_options){0};
    if (!out.memory_limit) out.memory_limit = INT64_MAX;
    if (!out.output_limit) out.output_limit = 512 * 1024 * 1024;
    if (!out.max_depth) out.max_depth = UINT32_MAX;
    if (!out.hook_count) out.hook_count = 1000;
    if (out.hook_count > INT_MAX) out.hook_count = INT_MAX;
    return out;
}

static void es_error_output(es_context *ctx,eslua_result *result,const char *error,size_t len,int passthrough) {
    es_release(ctx,ctx->output.data);ctx->output=(es_buffer){0};
    es_release(ctx,ctx->errors);ctx->errors=NULL;ctx->error_count=ctx->error_capacity=0;
    const char *header="";
    if(ctx->compile_failed&&result->status==ESLUA_ERROR){header=ctx->library?"Error compiling function: ":"Error compiling script (new function): ";passthrough=0;}
    else if(ctx->loading&&!ctx->load_plain){header=passthrough&&len?"Error registering functions: ":"Error registering functions: ERR ";passthrough=0;}
    size_t head=strlen(header),prefix=passthrough&&len?1:5;
    if(head>SIZE_MAX-prefix-2 || len>SIZE_MAX-prefix-2-head || len+head+prefix+2>ctx->options.output_limit){
        result->status=ESLUA_LIMIT;error="script output limit exceeded";len=strlen(error);prefix=5;header="";head=0;
    }
    if(len>SIZE_MAX-prefix-2-head || len+head+prefix+2>ctx->options.output_limit)return;
    unsigned char *data=es_allocate(ctx,NULL,len+head+prefix+2);
    if(!data){
        result->status=ESLUA_MEMORY;error="script memory limit exceeded";len=strlen(error);prefix=5;header="";head=0;
        if(len+prefix+2>ctx->options.output_limit)return;
        data=es_allocate(ctx,NULL,len+prefix+2);if(!data)return;
    }
    memcpy(data,"-ERR ",prefix);if(head)memcpy(data+prefix,header,head);
    for(size_t i=0;i<len;i++)data[prefix+head+i]=error[i]=='\r'||error[i]=='\n'?' ':(unsigned char)error[i];
    memcpy(data+prefix+head+len,"\r\n",2);
    ctx->output=(es_buffer){data,len+head+prefix+2,len+head+prefix+2};
}

static eslua_result es_invoke(eslua_arg source, size_t numkeys, const eslua_arg *keys,
                              size_t argc, const eslua_arg *args, int32_t client_resp,
                              const eslua_options *options, const eslua_callbacks *callbacks, int compile_only) {
    es_context ctx = {0};
    ctx.options = es_options(options);
    if (callbacks) ctx.callbacks = *callbacks;
    ctx.source = source; ctx.keys = keys; ctx.numkeys = numkeys; ctx.args = args; ctx.argc = argc;
    ctx.client_resp = client_resp; ctx.script_resp = 2; ctx.compile_only = compile_only; ctx.started = es_clock();
    eslua_result result = {0};
    const char *error = NULL;
    size_t error_len = 0;
    int error_passthrough = 0;
    int invalid = (!source.data && source.len) || (numkeys && !keys) || (argc && !args) || (client_resp != 2 && client_resp != 3) || numkeys > INT_MAX || argc > INT_MAX;
    if (!invalid) {
        for (size_t i = 0; i < numkeys; i++) if (!keys[i].data && keys[i].len) invalid = 1;
        for (size_t i = 0; i < argc; i++) if (!args[i].data && args[i].len) invalid = 1;
    }
    if (!invalid) {
        size_t input_bytes = source.len;
        if (input_bytes > ctx.options.memory_limit) invalid = 1;
        for (size_t i = 0; i < numkeys && !invalid; i++) {
            if (keys[i].len > ctx.options.memory_limit - input_bytes) invalid = 1;
            else input_bytes += keys[i].len;
        }
        for (size_t i = 0; i < argc && !invalid; i++) {
            if (args[i].len > ctx.options.memory_limit - input_bytes) invalid = 1;
            else input_bytes += args[i].len;
        }
    }
    if (invalid) {
        result.status = ESLUA_ARGUMENT; error = "invalid runtime arguments";
    } else {
        ctx.L = lua_newstate(es_lua_allocate, &ctx);
        if (!ctx.L) { result.status = ESLUA_MEMORY; error = "script VM allocation failed"; }
        else {
            es_module_bind(ctx.L);
            int status = lua_cpcall(ctx.L, es_protected, &ctx);
            if (status != LUA_OK || ctx.sticky) {
                result.status = ctx.sticky ? ctx.sticky : (status == LUA_ERRMEM ? ESLUA_MEMORY : ESLUA_ERROR);
                error = ctx.failure;
                if (!error && lua_type(ctx.L, -1) == LUA_TSTRING) {
                    error = lua_tolstring(ctx.L, -1, &error_len);
                    error_passthrough = ctx.error_passthrough;
                }
                if (!error) error = "script execution failed";
            }
        }
    }
    if (result.status != ESLUA_OK) {
        if(!error){error="script execution failed";error_len=strlen(error);}
        else if(!error_len)error_len=strlen(error);
        es_error_output(&ctx,&result,error,error_len,error_passthrough);
    }
    result.forwarded_error = ctx.forwarded_error;
    if(ctx.L){lua_close(ctx.L);ctx.L=NULL;}
    if (ctx.output.data) {
        es_detach(&ctx, ctx.output.data);
        result.data = ctx.output.data; result.len = ctx.output.len;
    }
    es_detach_errors(&ctx, &result);
    while (ctx.blocks) es_release(&ctx, ctx.blocks + 1);
    es_snapshot(&ctx);
    result.write_effect = ctx.wrote; result.stats = ctx.stats;
    return result;
}


eslua_result eslua_compile(eslua_arg source, const eslua_options *options) {
    return es_invoke(source, 0, NULL, 0, NULL, 2, options, NULL, 1);
}

static eslua_result es_library_invoke(eslua_library *library) {
    es_context *ctx = es_library_context(library);
    eslua_result result = {0};
    ctx->started = es_clock(); ctx->stats.instructions = 0; ctx->stats.elapsed_ns = 0;
    ctx->stats.peak_bytes = ctx->stats.current_bytes;
    ctx->sticky = ctx->wrote = ctx->host_error_origin = ctx->error_passthrough = ctx->forwarded_error = 0; ctx->failure = NULL;
    ctx->script_resp = 2;
    ctx->compile_failed = 0;
    ctx->load_plain = 0;
    ctx->debug = NULL;
    es_module_bind(ctx->L);
    lua_settop(ctx->L, 0);
    int status = lua_cpcall(ctx->L, es_protected, ctx);
    lua_sethook(ctx->L, NULL, 0, 0);
    if (status || ctx->sticky) {
        result.status = ctx->sticky ? ctx->sticky : (status == LUA_ERRMEM ? ESLUA_MEMORY : ESLUA_ERROR);
        const char *error = ctx->failure;
        size_t n = 0;
        if (error) n = strlen(error);
        else if (lua_type(ctx->L, -1) == LUA_TSTRING) error = lua_tolstring(ctx->L, -1, &n);
        if (!error) { error = "script execution failed"; n = strlen(error); }
        es_error_output(ctx,&result,error,n,ctx->failure?0:ctx->error_passthrough);
    }
    if (ctx->output.data) {
        es_detach(ctx, ctx->output.data);
        result.data = ctx->output.data; result.len = ctx->output.len;
        ctx->output = (es_buffer){0};
    }
    es_detach_errors(ctx, &result);
    lua_settop(ctx->L, 0);
    while (ctx->temporaries) es_release(ctx, ctx->temporaries+1);
    es_snapshot(ctx); result.stats = ctx->stats; result.write_effect = ctx->wrote;
    ctx->debug = NULL;
    ctx->callbacks = (eslua_callbacks){0}; ctx->keys = ctx->args = NULL; ctx->numkeys = ctx->argc = 0;
    result.forwarded_error = ctx->forwarded_error;
    return result;
}

static void es_engine_close(eslua_library *engine) {
    es_context *ctx=&engine->context;
    if(ctx->L){es_module_bind(ctx->L);lua_close(ctx->L);}
    while(ctx->blocks)es_release(ctx,ctx->blocks+1);
    eslua_library **link=&es_functions_engines;
    while(*link && *link!=engine)link=&(*link)->engine_next;
    if(*link)*link=engine->engine_next;
    free(engine);
}

void eslua_functions_reset(void) {
    eslua_library *engine=es_functions_engine;es_functions_engine=NULL;
    if(!engine)return;
    engine->retired=1;
    if(!engine->references)es_engine_close(engine);
}

eslua_stats eslua_functions_stats(void) {
    eslua_stats total={0};
    for(eslua_library *engine=es_functions_engines;engine;engine=engine->engine_next){
        eslua_stats stats=engine->context.stats;
        size_t extra=sizeof(*engine)*(engine->references+1);
        size_t current=stats.current_bytes>SIZE_MAX-extra?SIZE_MAX:stats.current_bytes+extra;
        size_t peak=stats.peak_bytes>SIZE_MAX-extra?SIZE_MAX:stats.peak_bytes+extra;
        total.current_bytes=current>SIZE_MAX-total.current_bytes?SIZE_MAX:total.current_bytes+current;
        total.peak_bytes=peak>SIZE_MAX-total.peak_bytes?SIZE_MAX:total.peak_bytes+peak;
        if(stats.elapsed_ns>total.elapsed_ns)total.elapsed_ns=stats.elapsed_ns;
        total.instructions=stats.instructions>UINT64_MAX-total.instructions?UINT64_MAX:total.instructions+stats.instructions;
    }
    return total;
}

eslua_stats eslua_functions_active_stats(void) {
    if (!es_functions_engine) return (eslua_stats){0};
    es_context *ctx = &es_functions_engine->context;
    eslua_stats stats = ctx->stats;
    stats.current_bytes = (size_t)lua_gc(ctx->L, LUA_GCCOUNT, 0)*1024 + (size_t)lua_gc(ctx->L, LUA_GCCOUNTB, 0);
    return stats;
}

eslua_library_load_result eslua_library_load(eslua_arg source, const eslua_options *options) {
    eslua_library_load_result out={0};eslua_options selected=es_options(options);
    if((!source.data&&source.len)||source.len>selected.memory_limit){out.result.status=ESLUA_ARGUMENT;return out;}
    if(!es_functions_engine){
        eslua_library *engine=calloc(1,sizeof(*engine));
        if(!engine){out.result.status=ESLUA_MEMORY;return out;}
        engine->context.options=selected;
        engine->context.L=lua_newstate(es_lua_allocate,&engine->context);
        if(!engine->context.L){es_engine_close(engine);out.result.status=ESLUA_MEMORY;return out;}
        engine->engine_next=es_functions_engines;es_functions_engines=engine;es_functions_engine=engine;
    }
    eslua_library *library=calloc(1,sizeof(*library));
    if(!library){out.result.status=ESLUA_MEMORY;return out;}
    library->engine=es_functions_engine;library->engine->references++;
    es_context *ctx=es_library_context(library);
    ctx->options=selected;ctx->library=library;ctx->loading=1;ctx->client_resp=2;ctx->source=source;
    out.result=es_library_invoke(library);
    ctx->source=(eslua_arg){0};ctx->loading=0;ctx->library=NULL;
    if(ctx->globals_reference&&ctx->cleanup_reference){lua_rawgeti(ctx->L,LUA_REGISTRYINDEX,ctx->globals_reference);lua_replace(ctx->L,LUA_GLOBALSINDEX);}
    else eslua_functions_reset();
    if(out.result.status)eslua_library_free(library);else out.library=library;
    return out;
}

size_t eslua_library_count(eslua_library *library) { return library ? library->count : 0; }
eslua_function_info eslua_library_info(eslua_library *library, size_t index) {
    return library && index < library->count ? library->functions[index].info : (eslua_function_info){0};
}
static int es_inputs_fit(size_t limit, eslua_arg source, size_t numkeys, const eslua_arg *keys, size_t argc, const eslua_arg *args) {
    size_t total = source.len;
    if (total > limit) return 0;
    for (size_t i = 0; i < numkeys; i++) { if (keys[i].len > limit-total) return 0; total += keys[i].len; }
    for (size_t i = 0; i < argc; i++) { if (args[i].len > limit-total) return 0; total += args[i].len; }
    return 1;
}

eslua_result eslua_library_call(eslua_library *library, size_t index, size_t numkeys, const eslua_arg *keys, size_t argc, const eslua_arg *args, int32_t client_resp, const eslua_options *options, const eslua_callbacks *callbacks) {
    if (!library || index >= library->count || (numkeys && !keys) || (argc && !args) || numkeys > INT_MAX || argc > INT_MAX || (client_resp != 2 && client_resp != 3)) return (eslua_result){.status = ESLUA_ARGUMENT};
    for (size_t i = 0; i < numkeys; i++) if (!keys[i].data && keys[i].len) return (eslua_result){.status = ESLUA_ARGUMENT};
    for (size_t i = 0; i < argc; i++) if (!args[i].data && args[i].len) return (eslua_result){.status = ESLUA_ARGUMENT};
    es_context *ctx = es_library_context(library);
    ctx->options = es_options(options);
    if (!es_inputs_fit(ctx->options.memory_limit, (eslua_arg){0}, numkeys, keys, argc, args)) return (eslua_result){.status = ESLUA_ARGUMENT};
    ctx->keys = keys; ctx->numkeys = numkeys; ctx->args = args; ctx->argc = argc;
    ctx->function_index = index; ctx->calling = 1; ctx->client_resp = client_resp; ctx->library = library;
    if (callbacks) ctx->callbacks = *callbacks;
    eslua_result out = es_library_invoke(library); ctx->calling = 0; ctx->library = NULL; return out;
}
static int es_unregister_library(lua_State *L) {
    eslua_library *library=lua_touserdata(L,1);
    for(size_t i=0;i<library->count;i++)if(library->functions[i].reference>=0)luaL_unref(L,LUA_REGISTRYINDEX,library->functions[i].reference);
    lua_settop(L,0);
    if (!library->engine->retired) lua_gc(L,LUA_GCSTEP,1);
    return 0;
}

void eslua_library_free(eslua_library *library) {
    if(!library)return;
    if(!library->engine){
        es_context *ctx=&library->context;
        if(ctx->L){es_module_bind(ctx->L);lua_close(ctx->L);}
        while(ctx->blocks)es_release(ctx,ctx->blocks+1);
        free(library);return;
    }
    eslua_library *engine=library->engine;es_context *ctx=&engine->context;
    es_module_bind(ctx->L);lua_settop(ctx->L,0);
    if(ctx->cleanup_reference){
        lua_rawgeti(ctx->L,LUA_REGISTRYINDEX,ctx->cleanup_reference);lua_pushlightuserdata(ctx->L,library);
        lua_pcall(ctx->L,1,0,0);lua_settop(ctx->L,0);
    }
    for(size_t i=0;i<library->count;i++){
        es_release(ctx,(void *)library->functions[i].info.name.data);
        es_release(ctx,(void *)library->functions[i].info.description.data);
    }
    es_release(ctx,library->functions);free(library);
    engine->references--;
    if(engine->retired&&!engine->references)es_engine_close(engine);
}
eslua_stats eslua_library_stats(eslua_library *library) { return library ? es_library_context(library)->stats : (eslua_stats){0}; }

static _Thread_local eslua_library *es_eval_engine;

eslua_stats eslua_eval_stats(void) { return es_eval_engine ? es_eval_engine->context.stats : (eslua_stats){0}; }
eslua_stats eslua_eval_active_stats(void) {
    if (!es_eval_engine || !es_eval_engine->context.L) return (eslua_stats){0};
    es_context *ctx = &es_eval_engine->context;
    eslua_stats stats = ctx->stats;
    stats.current_bytes = (size_t)lua_gc(ctx->L, LUA_GCCOUNT, 0)*1024 + (size_t)lua_gc(ctx->L, LUA_GCCOUNTB, 0);
    return stats;
}
void eslua_reset(void) { eslua_library_free(es_eval_engine); es_eval_engine = NULL; }

static int es_eval_open(const eslua_options *options) {
    if (es_eval_engine) return 1;
    es_eval_engine = calloc(1, sizeof(*es_eval_engine));
    if (!es_eval_engine) return 0;
    es_eval_engine->context.options = es_options(options);
    es_eval_engine->context.L = lua_newstate(es_lua_allocate, &es_eval_engine->context);
    if (!es_eval_engine->context.L) { eslua_reset(); return 0; }
    return 1;
}

static eslua_result es_eval(eslua_arg source, eslua_arg digest, size_t numkeys, const eslua_arg *keys, size_t argc,
                            const eslua_arg *args, int32_t client_resp, const eslua_options *options,
                            const eslua_callbacks *callbacks) {
    if ((!source.data && source.len) || (!digest.data && digest.len) || (numkeys && !keys) || (argc && !args) || numkeys > INT_MAX || argc > INT_MAX || (client_resp != 2 && client_resp != 3)) return (eslua_result){.status = ESLUA_ARGUMENT};
    for (size_t i = 0; i < numkeys; i++) if (!keys[i].data && keys[i].len) return (eslua_result){.status = ESLUA_ARGUMENT};
    for (size_t i = 0; i < argc; i++) if (!args[i].data && args[i].len) return (eslua_result){.status = ESLUA_ARGUMENT};
    if (!es_inputs_fit(es_options(options).memory_limit, source, numkeys, keys, argc, args)) return (eslua_result){.status = ESLUA_ARGUMENT};
    if (es_eval_engine && es_eval_engine->active) return (eslua_result){.status = ESLUA_ARGUMENT};
    if (!es_eval_open(options)) return (eslua_result){.status = ESLUA_MEMORY};
    es_context *ctx = &es_eval_engine->context;
    ctx->options = es_options(options); ctx->source = source; ctx->digest = digest; ctx->keys = keys; ctx->numkeys = numkeys; ctx->args = args; ctx->argc = argc; ctx->client_resp = client_resp;
    if (callbacks) ctx->callbacks = *callbacks;
    es_eval_engine->active = 1;
    eslua_result result = es_library_invoke(es_eval_engine);
    es_eval_engine->active = 0;
    if (ctx->globals_reference) {
        lua_rawgeti(ctx->L, LUA_REGISTRYINDEX, ctx->globals_reference);
        lua_enablereadonlytable(ctx->L, -1, 1); lua_pop(ctx->L, 1); ctx->eval_reuse = 1;
    } else eslua_reset();
    if (es_eval_engine) es_eval_engine->context.source = es_eval_engine->context.digest = (eslua_arg){0};
    return result;
}

eslua_result eslua_eval(eslua_arg source, size_t numkeys, const eslua_arg *keys, size_t argc,
                       const eslua_arg *args, int32_t client_resp, const eslua_options *options,
                       const eslua_callbacks *callbacks) {
    return es_eval(source, (eslua_arg){0}, numkeys, keys, argc, args, client_resp, options, callbacks);
}

eslua_result eslua_eval_cached(eslua_arg source, eslua_arg digest, size_t numkeys, const eslua_arg *keys, size_t argc,
                              const eslua_arg *args, int32_t client_resp, const eslua_options *options,
                              const eslua_callbacks *callbacks) {
    return es_eval(source, digest, numkeys, keys, argc, args, client_resp, options, callbacks);
}

eslua_result eslua_eval_prepare(eslua_arg source, eslua_arg digest, const eslua_options *options) {
    lua_State *bound = es_module_bind(NULL);
    eslua_result result;
    if ((!source.data && source.len) || !digest.data || !digest.len || source.len > es_options(options).memory_limit ||
        (es_eval_engine && es_eval_engine->active) || !es_eval_open(options)) {
        result = eslua_compile(source, options);
    } else {
        es_context *ctx = &es_eval_engine->context;
        ctx->options = es_options(options); ctx->source = source; ctx->digest = digest; ctx->compile_only = 1; ctx->client_resp = 2;
        result = es_library_invoke(es_eval_engine);
        ctx->compile_only = 0; ctx->source = ctx->digest = (eslua_arg){0};
    }
    es_module_bind(bound);
    return result;
}

static int es_forget(lua_State *L) {
    es_context *ctx = es_context_of(L);
    const eslua_arg *digest = lua_touserdata(L, 1);
    lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->scripts_reference);
    lua_pushlstring(L, (const char *)digest->data, digest->len);
    lua_pushvalue(L, -1); lua_rawget(L, -3);
    if (lua_isnil(L, -1)) return 0;
    lua_pop(L, 1); lua_pushnil(L); lua_rawset(L, -3);
    return 0;
}

void eslua_eval_forget(eslua_arg digest) {
    if (!es_eval_engine || es_eval_engine->active || !es_eval_engine->context.L || !es_eval_engine->context.scripts_reference || !digest.data || !digest.len) return;
    es_context *ctx = &es_eval_engine->context;
    int32_t sticky = ctx->sticky;
    const char *failure = ctx->failure;
    lua_State *bound = es_module_bind(ctx->L);
    lua_settop(ctx->L, 0);
    lua_cpcall(ctx->L, es_forget, &digest);
    lua_settop(ctx->L, 0);
    ctx->sticky = sticky; ctx->failure = failure;
    es_module_bind(bound);
}

void eslua_free_result(eslua_result *result) {
    if (!result) return;
    void *allocations[] = {result->data, result->errors};
    for (size_t i = 0; i < sizeof(allocations)/sizeof(*allocations); i++) {
        if (!allocations[i]) continue;
        es_block *block = (es_block *)allocations[i]-1;
        atomic_fetch_sub_explicit(&es_detached_bytes, sizeof(*block)+block->h.size, memory_order_relaxed);
        free(block);
    }
    *result = (eslua_result){0};
}

size_t eslua_detached_memory(void) { return atomic_load_explicit(&es_detached_bytes, memory_order_relaxed); }

const char *eslua_version(void) { return LUA_RELEASE; }
