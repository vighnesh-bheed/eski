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

typedef union es_block es_block;
union es_block {
    struct { es_block *prev, *next; size_t size; } h;
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
    lua_State *L;
    eslua_arg source;
    const eslua_arg *keys, *args;
    size_t numkeys, argc;
    uint64_t started;
    int32_t sticky, wrote, script_resp, client_resp, compile_only;
    const char *failure;
    es_buffer output;
} es_context;

es_context *es_context_of(lua_State *L);
void *es_allocate(es_context *ctx, void *old, size_t size);
void es_release(es_context *ctx, void *ptr);
int es_fail(lua_State *L, int status, const char *message);
void es_append(lua_State *L, es_buffer *out, const void *data, size_t len);
void es_byte(lua_State *L, es_buffer *out, unsigned char value);
void es_install_codecs(lua_State *L);
void es_install_bits(lua_State *L);
int es_sha1hex(lua_State *L);
void es_serialize(lua_State *L, int index, int resp, es_buffer *out);
void es_parse_response(lua_State *L, const unsigned char *data, size_t len);
extern unsigned char es_null_token;

#endif
