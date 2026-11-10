#ifndef ESLUA_INTERNAL_H
#define ESLUA_INTERNAL_H

#include "../include/eslua.h"
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define LUA_OK 0
#define lua_rawlen lua_objlen
#define lua_isinteger(L,i) 0
static inline int lua_absindex(lua_State *L, int i) { return i > 0 || i <= LUA_REGISTRYINDEX ? i : lua_gettop(L) + i + 1; }
#define lua_pushglobaltable(L) lua_pushvalue(L, LUA_GLOBALSINDEX)

typedef union es_block es_block;
union es_block {
    struct { es_block *prev, *next, *temporary_prev, *temporary_next; size_t size; uint64_t transient; } h;
    max_align_t alignment;
};

typedef struct es_buffer {
    unsigned char *data;
    size_t len, cap;
} es_buffer;

typedef struct es_context {
    eslua_options options;
    eslua_callbacks callbacks;
    eslua_stats stats;
    es_block *blocks;
    es_block *temporaries;
    lua_State *L;
    eslua_arg source, digest;
    const eslua_arg *keys, *args;
    size_t numkeys, argc;
    uint64_t started;
    int32_t sticky, wrote, script_resp, client_resp, compile_only;
    int host_error_origin, error_passthrough, forwarded_error;
    const char *failure;
    es_buffer output;
    eslua_error_event *errors;
    size_t error_count, error_capacity;
    uint64_t module_serial;
    struct eslua_library *library;
    size_t function_index;
    int loading, calling, eval_reuse, compile_failed, load_plain;
    int globals_reference, cleanup_reference, load_globals_reference, scripts_reference;
    struct es_debug_state *debug;
    uint64_t random_state;
    int cjson_reference, gc_pause, gc_stepmul;
} es_context;

es_context *es_context_of(lua_State *L);
void *es_allocate(es_context *ctx, void *old, size_t size);
void es_release(es_context *ctx, void *ptr);
void es_transient(es_context *ctx, void *ptr);
int es_fail(lua_State *L, int status, const char *message);
void es_append(lua_State *L, es_buffer *out, const void *data, size_t len);
void es_byte(lua_State *L, es_buffer *out, unsigned char value);
void es_install_codecs(lua_State *L);
void es_install_bits(lua_State *L);
int es_sha1hex(lua_State *L);
size_t es_number_text(double value, int argument, char *out, size_t capacity);
void es_serialize(lua_State *L, int index, int resp, es_buffer *out);
void es_parse_response(lua_State *L, const unsigned char *data, size_t len);
void es_debug_begin(lua_State *L);
void es_debug_check(lua_State *L);
int es_debug_active(lua_State *L);
void es_debug_hook(lua_State *L, lua_Debug *debug);
void es_debug_finish(lua_State *L);
void es_debug_command(lua_State *L, int argc, const eslua_arg *args);
void es_debug_reply(lua_State *L, const eslua_result *result);
int es_debug_log(lua_State *L);
int es_debug_breakpoint(lua_State *L);
int es_debug_call(lua_State *L);
extern unsigned char es_null_token;
void es_wrap_module(lua_State *L, int index);
void es_install_libraries(lua_State *L);

#endif
