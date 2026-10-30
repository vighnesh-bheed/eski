#define _POSIX_C_SOURCE 200809L
#include "internal.h"
#include <stdatomic.h>

unsigned char es_null_token;
static _Atomic uint64_t es_invocations;

static uint64_t es_clock(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0;
    return (uint64_t)now.tv_sec * UINT64_C(1000000000) + (uint64_t)now.tv_nsec;
}

es_context *es_context_of(lua_State *L) {
    return *(es_context **)lua_getextraspace(L);
}

void *es_allocate(es_context *ctx, void *old, size_t size) {
    es_block *block = old ? (es_block *)old - 1 : NULL;
    size_t before = block ? block->h.size + sizeof(*block) : 0;
    if (size == 0) { es_release(ctx, old); return NULL; }
    if (size > SIZE_MAX - sizeof(*block) || ctx->stats.current_bytes < before ||
        size + sizeof(*block) > ctx->options.memory_limit - (ctx->stats.current_bytes - before)) {
        ctx->sticky = ESLUA_MEMORY;
        ctx->failure = "script memory limit exceeded";
        return NULL;
    }
    es_block *prev = block ? block->h.prev : NULL;
    es_block *next = block ? block->h.next : ctx->blocks;
    es_block *grown = realloc(block, sizeof(*grown) + size);
    if (!grown) {
        ctx->sticky = ESLUA_MEMORY;
        ctx->failure = "script allocation failed";
        return NULL;
    }
    grown->h.prev = prev;
    grown->h.next = next;
    grown->h.size = size;
    if (prev) prev->h.next = grown; else ctx->blocks = grown;
    if (next) next->h.prev = grown;
    ctx->stats.current_bytes = ctx->stats.current_bytes - before + sizeof(*grown) + size;
    if (ctx->stats.current_bytes > ctx->stats.peak_bytes) ctx->stats.peak_bytes = ctx->stats.current_bytes;
    return grown + 1;
}

void es_release(es_context *ctx, void *ptr) {
    if (!ptr) return;
    es_block *block = (es_block *)ptr - 1;
    if (block->h.prev) block->h.prev->h.next = block->h.next; else ctx->blocks = block->h.next;
    if (block->h.next) block->h.next->h.prev = block->h.prev;
    ctx->stats.current_bytes -= sizeof(*block) + block->h.size;
    free(block);
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

static void es_hook(lua_State *L, lua_Debug *debug) {
    (void)debug;
    es_context *ctx = es_context_of(L);
    if (UINT64_MAX - ctx->stats.instructions < ctx->options.hook_count) ctx->stats.instructions = UINT64_MAX;
    else ctx->stats.instructions += ctx->options.hook_count;
    es_check_abort(L);
    if (ctx->options.instruction_limit && ctx->stats.instructions >= ctx->options.instruction_limit)
        es_fail(L, ESLUA_LIMIT, "script instruction limit exceeded");
    es_snapshot(ctx);
    if (ctx->callbacks.busy && ctx->options.busy_threshold_ms &&
        ctx->stats.elapsed_ns / UINT64_C(1000000) >= ctx->options.busy_threshold_ms) {
        int32_t action = ctx->callbacks.busy(ctx->callbacks.opaque, ctx->wrote, &ctx->stats);
        if (action == ESLUA_ABORT) es_fail(L, ESLUA_KILLED, "script aborted by host policy");
        if (action == ESLUA_KILL_READONLY && !ctx->wrote) es_fail(L, ESLUA_KILLED, "Script killed by user with SCRIPT KILL");
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
    int n = lua_gettop(L);
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

static int es_global_write(lua_State *L) { return luaL_error(L, "Script attempted to create a global variable"); }
static int es_global_read(lua_State *L) { return luaL_error(L, "Script attempted to access an undefined global variable"); }
static int es_getn(lua_State *L) { luaL_checktype(L, 1, LUA_TTABLE); lua_pushinteger(L, (lua_Integer)lua_rawlen(L, 1)); return 1; }

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
    for (int i = 0; i < n; i++) {
        int numeric = lua_type(L, first + i) == LUA_TNUMBER;
        args[i].data = (const unsigned char *)lua_tolstring(L, first + i, &args[i].len);
        if (numeric && args[i].len >= 2 && args[i].data[args[i].len - 2] == '.' && args[i].data[args[i].len - 1] == '0')
            args[i].len -= 2;
        if (numeric && args[i].len == 2 && args[i].data[0] == '-' && args[i].data[1] == '0') {
            args[i].data++; args[i].len = 1;
        }
    }
    *count = n;
    return args;
}

static int es_command(lua_State *L, int catch_error) {
    es_context *ctx = es_context_of(L);
    es_check_abort(L);
    if (!ctx->callbacks.command) return luaL_error(L, "command bridge unavailable");
    if (lua_gettop(L) < 1) return luaL_error(L, "redis.call requires a command");
    int n;
    eslua_arg *args = es_arguments(L, 1, &n);
    es_snapshot(ctx);
    eslua_result result = ctx->callbacks.command(ctx->callbacks.opaque, ctx->script_resp, (size_t)n, args, &ctx->stats);
    if (result.write_effect) ctx->wrote = 1;
    es_release(ctx, args);
    if (result.status != ESLUA_OK) return es_fail(L, ESLUA_BRIDGE, "command bridge failed");
    if (!result.data || result.len == 0 || result.len > ctx->options.output_limit)
        return es_fail(L, ESLUA_BRIDGE, "invalid command bridge response");
    unsigned char response_tag = result.data[0];
    es_parse_response(L, result.data, result.len);
    if (!catch_error && (response_tag == '-' || response_tag == '!')) {
        lua_getfield(L, -1, "err");
        ctx->host_error_origin = 1;
        return lua_error(L);
    }
    es_check_abort(L);
    return 1;
}

static int es_call(lua_State *L) { return es_command(L, 0); }
static int es_command_pcall(lua_State *L) { return es_command(L, 1); }
static int es_setresp(lua_State *L) {
    lua_Integer resp = luaL_checkinteger(L, 1);
    if (lua_gettop(L) != 1 || (resp != 2 && resp != 3)) return luaL_error(L, "RESP version must be 2 or 3");
    es_context_of(L)->script_resp = (int32_t)resp;
    return 0;
}

static int es_tagged_reply(lua_State *L, const char *key) {
    size_t len;
    const char *text = luaL_checklstring(L, 1, &len);
    if (len == 0 && strcmp(key, "err") == 0) { text = "ERR "; len = 4; }
    lua_newtable(L);
    lua_pushlstring(L, text, len);
    lua_setfield(L, -2, key);
    return 1;
}
static int es_status_reply(lua_State *L) { return es_tagged_reply(L, "ok"); }
static int es_error_reply(lua_State *L) { return es_tagged_reply(L, "err"); }
static int es_replicate_commands(lua_State *L) { lua_pushboolean(L, 1); return 1; }
static int es_set_repl(lua_State *L) { return luaL_error(L, "redis.set_repl is unsupported; effects propagation remains enabled"); }
static int es_log(lua_State *L) {
    es_context *ctx = es_context_of(L);
    es_check_abort(L);
    int level = (int)luaL_checkinteger(L, 1);
    if (level < 0 || level > 3) return luaL_error(L, "invalid log level");
    int n;
    eslua_arg *args = es_arguments(L, 2, &n);
    if (ctx->callbacks.log) ctx->callbacks.log(ctx->callbacks.opaque, level, (size_t)n, args);
    es_release(ctx, args);
    return 0;
}

static void es_function(lua_State *L, const char *name, lua_CFunction fn) { lua_pushcfunction(L, fn); lua_setfield(L, -2, name); }

static void es_setup(lua_State *L) {
    es_context *ctx = es_context_of(L);
    luaL_requiref(L, "_G", luaopen_base, 1); lua_pop(L, 1);
    luaL_requiref(L, LUA_TABLIBNAME, luaopen_table, 1); lua_pop(L, 1);
    luaL_requiref(L, LUA_STRLIBNAME, luaopen_string, 1); lua_pop(L, 1);
    luaL_requiref(L, LUA_MATHLIBNAME, luaopen_math, 1); lua_pop(L, 1);
    lua_getglobal(L, "math"); lua_getfield(L, -1, "randomseed");
    lua_pushinteger(L, (lua_Integer)(es_clock() & (uint64_t)LUA_MAXINTEGER));
    uint64_t sequence = atomic_fetch_add_explicit(&es_invocations, 1, memory_order_relaxed) + 1;
    lua_pushinteger(L, (lua_Integer)(sequence & (uint64_t)LUA_MAXINTEGER));
    lua_call(L, 2, 0); lua_pop(L, 1);
    lua_getglobal(L, "string"); lua_pushnil(L); lua_setfield(L, -2, "dump"); lua_pop(L, 1);
    lua_getglobal(L, "table"); lua_getfield(L, -1, "unpack"); lua_setglobal(L, "unpack"); es_function(L, "getn", es_getn); lua_pop(L, 1);
    lua_pushcfunction(L, es_pcall); lua_setglobal(L, "pcall");
    lua_pushcfunction(L, es_xpcall); lua_setglobal(L, "xpcall");
    lua_newtable(L);
    es_function(L, "call", es_call); es_function(L, "pcall", es_command_pcall);
    es_function(L, "setresp", es_setresp); es_function(L, "status_reply", es_status_reply);
    es_function(L, "error_reply", es_error_reply); es_function(L, "sha1hex", es_sha1hex); es_function(L, "log", es_log);
    es_function(L, "replicate_commands", es_replicate_commands); es_function(L, "set_repl", es_set_repl);
    const char *levels[] = {"LOG_DEBUG", "LOG_VERBOSE", "LOG_NOTICE", "LOG_WARNING"};
    for (int i = 0; i < 4; i++) { lua_pushinteger(L, i); lua_setfield(L, -2, levels[i]); }
    lua_setglobal(L, "redis");
    es_install_codecs(L);
    es_install_bits(L);
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
    const char *allowed[] = {"_VERSION", "assert", "error", "ipairs", "next", "pairs", "pcall", "rawequal", "rawlen", "select", "tonumber", "tostring", "type", "xpcall", "unpack", "table", "string", "math", "redis", "bit", "cjson", "cmsgpack", "KEYS", "ARGV", NULL};
    for (size_t i = 0; allowed[i]; i++) {
        lua_pushstring(L, allowed[i]); lua_rawget(L, original); lua_setfield(L, globals, allowed[i]);
    }
    lua_pushvalue(L, globals); lua_setfield(L, globals, "_G");
    lua_pushvalue(L, globals); lua_rawseti(L, LUA_REGISTRYINDEX, LUA_RIDX_GLOBALS);
    lua_pushnil(L); lua_setfield(L, LUA_REGISTRYINDEX, LUA_LOADED_TABLE);
    lua_newtable(L);
    es_function(L, "__newindex", es_global_write); es_function(L, "__index", es_global_read);
    lua_pushliteral(L, "locked"); lua_setfield(L, -2, "__metatable");
    lua_setmetatable(L, globals); lua_pop(L, 2);
}

static int es_run(lua_State *L) {
    es_context *ctx = es_context_of(L);
    if (!ctx->compile_only) es_setup(L);
    es_check_abort(L);
    const char *source = ctx->source.data ? (const char *)ctx->source.data : "";
    int status = luaL_loadbufferx(L, source, ctx->source.len, "@user_script", "t");
    if (status != LUA_OK) return lua_error(L);
    es_check_abort(L);
    if (ctx->compile_only) { es_append(L, &ctx->output, "+OK\r\n", 5); return 0; }
    lua_sethook(L, es_hook, LUA_MASKCOUNT, (int)ctx->options.hook_count);
    lua_call(L, 0, 1);
    es_check_abort(L);
    es_serialize(L, -1, ctx->client_resp, &ctx->output);
    es_check_abort(L);
    return 0;
}

static int es_outer_error(lua_State *L) {
    es_context *ctx = es_context_of(L);
    ctx->error_passthrough = ctx->host_error_origin;
    if (lua_type(L, 1) == LUA_TTABLE) {
        lua_pushliteral(L, "err"); lua_rawget(L, 1);
        if (lua_type(L, -1) == LUA_TSTRING) {
            ctx->error_passthrough = 1;
            return 1;
        }
        lua_pop(L, 1);
    }
    lua_pushvalue(L, 1);
    return 1;
}

static eslua_options es_options(const eslua_options *input) {
    eslua_options out = input ? *input : (eslua_options){0};
    if (!out.memory_limit) out.memory_limit = 64 * 1024 * 1024;
    if (!out.output_limit) out.output_limit = 16 * 1024 * 1024;
    if (!out.max_depth) out.max_depth = 64;
    if (out.max_depth > 256) out.max_depth = 256;
    if (!out.hook_count) out.hook_count = 1000;
    if (out.hook_count > INT_MAX) out.hook_count = INT_MAX;
    return out;
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
    unsigned char error_copy[4096];
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
        ctx.L = lua_newstate(es_lua_allocate, &ctx, luaL_makeseed(NULL));
        if (!ctx.L) { result.status = ESLUA_MEMORY; error = "script VM allocation failed"; }
        else {
            *(es_context **)lua_getextraspace(ctx.L) = &ctx;
            lua_pushcfunction(ctx.L, es_outer_error);
            lua_pushcfunction(ctx.L, es_run);
            int status = lua_pcall(ctx.L, 0, 0, 1);
            if (status != LUA_OK || ctx.sticky) {
                result.status = ctx.sticky ? ctx.sticky : (status == LUA_ERRMEM ? ESLUA_MEMORY : ESLUA_ERROR);
                error = ctx.failure;
                if (!error && lua_type(ctx.L, -1) == LUA_TSTRING) {
                    const char *message = lua_tolstring(ctx.L, -1, &error_len);
                    if (error_len > sizeof(error_copy)) error_len = sizeof(error_copy);
                    memcpy(error_copy, message, error_len);
                    error = (const char *)error_copy;
                    error_passthrough = ctx.error_passthrough;
                }
                if (!error) error = "script execution failed";
            }
            lua_close(ctx.L); ctx.L = NULL;
        }
    }
    if (result.status != ESLUA_OK) {
        es_release(&ctx, ctx.output.data); ctx.output = (es_buffer){0};
        if (!error) error = "script execution failed";
        size_t n = error == (const char *)error_copy ? error_len : strlen(error);
        if (n > 4096) n = 4096;
        size_t prefix = error_passthrough && n ? 1 : 5;
        if (ctx.options.output_limit >= n + prefix + 2) {
            ctx.output.data = es_allocate(&ctx, NULL, n + prefix + 2);
            if (ctx.output.data) {
                memcpy(ctx.output.data, "-ERR ", prefix);
                for (size_t i = 0; i < n; i++) ctx.output.data[prefix + i] = (error[i] == '\r' || error[i] == '\n') ? ' ' : (unsigned char)error[i];
                memcpy(ctx.output.data + prefix + n, "\r\n", 2); ctx.output.len = n + prefix + 2;
            }
        }
    }
    if (ctx.output.data) {
        es_block *block = (es_block *)ctx.output.data - 1;
        if (block->h.prev) block->h.prev->h.next = block->h.next; else ctx.blocks = block->h.next;
        if (block->h.next) block->h.next->h.prev = block->h.prev;
        ctx.stats.current_bytes -= sizeof(*block) + block->h.size;
        result.data = ctx.output.data; result.len = ctx.output.len;
    }
    while (ctx.blocks) es_release(&ctx, ctx.blocks + 1);
    es_snapshot(&ctx);
    result.write_effect = ctx.wrote; result.stats = ctx.stats;
    return result;
}

eslua_result eslua_eval(eslua_arg source, size_t numkeys, const eslua_arg *keys, size_t argc,
                       const eslua_arg *args, int32_t client_resp, const eslua_options *options,
                       const eslua_callbacks *callbacks) {
    return es_invoke(source, numkeys, keys, argc, args, client_resp, options, callbacks, 0);
}

eslua_result eslua_compile(eslua_arg source, const eslua_options *options) {
    return es_invoke(source, 0, NULL, 0, NULL, 2, options, NULL, 1);
}

void eslua_free_result(eslua_result *result) {
    if (!result) return;
    if (result->data) free((es_block *)result->data - 1);
    *result = (eslua_result){0};
}

const char *eslua_version(void) { return LUA_RELEASE; }
