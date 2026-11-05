#include <assert.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lstate.h"
#include "lstring.h"
#include "lzio.h"
#include "llex.c"

#if defined(__has_feature)
#if __has_feature(address_sanitizer)
extern int __lsan_do_recoverable_leak_check(void);
#define CHECK_LEAKS() assert(!__lsan_do_recoverable_leak_check())
#endif
#endif
#ifndef CHECK_LEAKS
#define CHECK_LEAKS() ((void)0)
#endif

static const char *read_newline(lua_State *state, void *data, size_t *size) {
    (void)state;
    int *reads = data;
    if ((*reads)++ == 0) {
        *size = 1;
        return "\n";
    }
    *size = 0;
    return NULL;
}

static int read_token(lua_State *state) {
    LexState *lexer = lua_touserdata(state, 1);
    luaX_next(lexer);
    return 0;
}

int main(void) {
    lua_State *state = luaL_newstate();
    assert(state);
    for (int token = -3; token <= 3; token++) {
        ZIO input;
        Mbuffer buffer;
        LexState lexer;
        int reads = 0;
        memset(&lexer, 0, sizeof(lexer));
        luaZ_initbuffer(state, &buffer);
        luaZ_init(state, &input, read_newline, &reads);
        lua_pushliteral(state, "@line_boundary");
        lexer.buff = &buffer;
        luaX_setinput(state, &lexer, &input, rawtsvalue(state->top - 1));
        lexer.t.token = token;
        lexer.linenumber = MAX_INT - 1;
        int status = lua_cpcall(state, read_token, &lexer);
        assert(status == LUA_ERRSYNTAX);
        const char *message = lua_tostring(state, -1);
        assert(message && strstr(message, "chunk has too many lines"));
        assert(!strstr(message, " near "));
        luaZ_freebuffer(state, &buffer);
        lua_settop(state, 0);
    }
    lua_close(state);
    CHECK_LEAKS();
    puts("line-count boundary: 7 protected cases passed");
    return 0;
}
