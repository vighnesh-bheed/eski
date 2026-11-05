#include "internal.h"

int luaopen_cjson(lua_State *L);
int luaopen_cmsgpack(lua_State *L);
int luaopen_struct(lua_State *L);
int luaopen_bit(lua_State *L);

static _Thread_local lua_State *es_module_state;

lua_State *es_module_bind(lua_State *L) { lua_State *previous = es_module_state; es_module_state = L; return previous; }

void *es_module_realloc(void *ptr, size_t size) {
    es_context *ctx = es_context_of(es_module_state);
    void *out = es_allocate(ctx, ptr, size);
    if (!out && size) es_fail(es_module_state, ESLUA_MEMORY, "script memory limit exceeded");
    es_transient(ctx, out);
    return out;
}

void *es_module_malloc(size_t size) { return es_module_realloc(NULL, size); }
void es_module_free(void *ptr) { es_release(es_context_of(es_module_state), ptr); }
_Noreturn void es_module_abort(void) {
    es_fail(es_module_state, ESLUA_LIMIT, "codec size limit exceeded");
    abort();
}

static int es_module_error(lua_State *L) {
    if(!lua_isstring(L,1)){lua_pushvalue(L,1);return 1;}
    size_t len;const char *text=lua_tolstring(L,1,&len);size_t marker=SIZE_MAX;
    if(len>=13&&!memcmp(text,"bad argument ",13))for(size_t i=0;i+6<=len;i++)if(!memcmp(text+i,"to '?'",6)){marker=i;break;}
    lua_pushvalue(L,lua_upvalueindex(1));
    if(marker!=SIZE_MAX){
        lua_pushlstring(L,text,marker+4);lua_pushvalue(L,lua_upvalueindex(2));
        lua_pushlstring(L,text+marker+5,len-marker-5);lua_concat(L,4);
    }else{lua_pushlstring(L,text,len);lua_concat(L,2);}
    return 1;
}

static int es_module_call(lua_State *L) {
    es_context *ctx = es_context_of(L);
    lua_State *previous = es_module_state;
    es_module_state = L;
    uint64_t serial = ctx->module_serial;
    int n = lua_gettop(L);
    lua_Debug caller;const char *name="?";
    if(lua_getstack(L,0,&caller)){lua_getinfo(L,"n",&caller);if(caller.name)name=caller.name;}
    luaL_where(L,1);lua_pushstring(L,name);lua_pushcclosure(L,es_module_error,2);lua_insert(L,1);
    lua_pushvalue(L, lua_upvalueindex(1)); lua_insert(L, 2);
    int status = lua_pcall(L, n, LUA_MULTRET, 1);lua_remove(L,1);
    es_block *block = ctx->temporaries;
    while (block) {
        es_block *next = block->h.temporary_next;
        if (block->h.transient > serial) es_release(ctx, block + 1);
        block = next;
    }
    es_module_state = previous;
    if (ctx->sticky) return es_fail(L, ctx->sticky, ctx->failure);
    if (status) return lua_error(L);
    if (lua_type(L, 1) == LUA_TTABLE) es_wrap_module(L, 1);
    return lua_gettop(L);
}

void es_wrap_module(lua_State *L, int index) {
    index = lua_absindex(L, index);
    lua_pushnil(L);
    while (lua_next(L, index)) {
        if (lua_type(L, -1) == LUA_TFUNCTION) {
            lua_pushvalue(L, -2); lua_pushvalue(L, -2);
            lua_pushcclosure(L, es_module_call, 1); lua_rawset(L, index);
        }
        lua_pop(L, 1);
    }
}

void es_install_libraries(lua_State *L) {
    const struct { const char *name; lua_CFunction open; } modules[] = {
        {"cjson", luaopen_cjson}, {"cmsgpack", luaopen_cmsgpack},
        {"struct", luaopen_struct}, {"bit", luaopen_bit}
    };
    for (size_t i = 0; i < sizeof(modules)/sizeof(*modules); i++) {
        lua_pushcfunction(L, modules[i].open); lua_call(L, 0, 1);
        es_wrap_module(L, -1); lua_setglobal(L, modules[i].name);
    }
}
