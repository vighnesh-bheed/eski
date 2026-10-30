#include "internal.h"

static uint32_t es_u32(lua_State *L, int index) {
    if (lua_isinteger(L, index)) return (uint32_t)lua_tointeger(L, index);
    double value = luaL_checknumber(L, index);
    if (!isfinite(value)) luaL_error(L, "bit argument must be finite");
    double wrapped = fmod(trunc(value), 4294967296.0);
    if (wrapped < 0) wrapped += 4294967296.0;
    return (uint32_t)wrapped;
}

static int es_bit_result(lua_State *L, uint32_t value) {
    int64_t result = value <= INT32_MAX ? (int64_t)value : (int64_t)value - INT64_C(4294967296);
    lua_pushinteger(L, (lua_Integer)result); return 1;
}

static int es_tobit(lua_State *L) { return es_bit_result(L, es_u32(L, 1)); }
static int es_bnot(lua_State *L) { return es_bit_result(L, ~es_u32(L, 1)); }
static int es_band(lua_State *L) { luaL_checkany(L, 1); uint32_t n = UINT32_MAX; for (int i = 1; i <= lua_gettop(L); i++) n &= es_u32(L, i); return es_bit_result(L, n); }
static int es_bor(lua_State *L) { luaL_checkany(L, 1); uint32_t n = 0; for (int i = 1; i <= lua_gettop(L); i++) n |= es_u32(L, i); return es_bit_result(L, n); }
static int es_bxor(lua_State *L) { luaL_checkany(L, 1); uint32_t n = 0; for (int i = 1; i <= lua_gettop(L); i++) n ^= es_u32(L, i); return es_bit_result(L, n); }
static int es_lshift(lua_State *L) { uint32_t n = es_u32(L, 1), shift = es_u32(L, 2) & 31; return es_bit_result(L, n << shift); }
static int es_rshift(lua_State *L) { uint32_t n = es_u32(L, 1), shift = es_u32(L, 2) & 31; return es_bit_result(L, n >> shift); }
static int es_arshift(lua_State *L) {
    uint32_t n = es_u32(L, 1), shift = es_u32(L, 2) & 31;
    uint32_t result = n >> shift;
    if (shift && (n & UINT32_C(0x80000000))) result |= UINT32_MAX << (32 - shift);
    return es_bit_result(L, result);
}
static int es_rol(lua_State *L) { uint32_t n = es_u32(L, 1), s = es_u32(L, 2) & 31; return es_bit_result(L, s ? (n << s) | (n >> (32 - s)) : n); }
static int es_ror(lua_State *L) { uint32_t n = es_u32(L, 1), s = es_u32(L, 2) & 31; return es_bit_result(L, s ? (n >> s) | (n << (32 - s)) : n); }
static int es_bswap(lua_State *L) {
    uint32_t n = es_u32(L, 1);
    return es_bit_result(L, (n >> 24) | ((n >> 8) & UINT32_C(0x0000ff00)) | ((n << 8) & UINT32_C(0x00ff0000)) | (n << 24));
}
static int es_tohex(lua_State *L) {
    uint32_t n = es_u32(L, 1); lua_Integer width = luaL_optinteger(L, 2, 8);
    int upper = width < 0; uint64_t count = upper ? (uint64_t)(-(width + 1)) + 1 : (uint64_t)width;
    if (count > 8) count = 8;
    const char *digits = upper ? "0123456789ABCDEF" : "0123456789abcdef"; char text[8];
    for (size_t i = 0; i < count; i++) { text[count - i - 1] = digits[n & 15]; n >>= 4; }
    lua_pushlstring(L, text, (size_t)count); return 1;
}

void es_install_bits(lua_State *L) {
    static const luaL_Reg functions[] = {{"tobit",es_tobit},{"bnot",es_bnot},{"band",es_band},{"bor",es_bor},{"bxor",es_bxor},{"lshift",es_lshift},{"rshift",es_rshift},{"arshift",es_arshift},{"rol",es_rol},{"ror",es_ror},{"bswap",es_bswap},{"tohex",es_tohex},{NULL,NULL}};
    luaL_newlib(L, functions); lua_setglobal(L, "bit");
}

static uint32_t es_rotate(uint32_t value, unsigned count) { return (value << count) | (value >> (32 - count)); }

static void es_sha_block(uint32_t state[5], const unsigned char block[64]) {
    uint32_t words[80];
    for (unsigned i = 0; i < 16; i++) words[i] = ((uint32_t)block[i * 4] << 24) | ((uint32_t)block[i * 4 + 1] << 16) | ((uint32_t)block[i * 4 + 2] << 8) | block[i * 4 + 3];
    for (unsigned i = 16; i < 80; i++) words[i] = es_rotate(words[i - 3] ^ words[i - 8] ^ words[i - 14] ^ words[i - 16], 1);
    uint32_t a = state[0], b = state[1], c = state[2], d = state[3], e = state[4];
    for (unsigned i = 0; i < 80; i++) {
        uint32_t choose, constant;
        if (i < 20) { choose = (b & c) | (~b & d); constant = UINT32_C(0x5a827999); }
        else if (i < 40) { choose = b ^ c ^ d; constant = UINT32_C(0x6ed9eba1); }
        else if (i < 60) { choose = (b & c) | (b & d) | (c & d); constant = UINT32_C(0x8f1bbcdc); }
        else { choose = b ^ c ^ d; constant = UINT32_C(0xca62c1d6); }
        uint32_t next = es_rotate(a, 5) + choose + e + constant + words[i];
        e = d; d = c; c = es_rotate(b, 30); b = a; a = next;
    }
    state[0] += a; state[1] += b; state[2] += c; state[3] += d; state[4] += e;
}

int es_sha1hex(lua_State *L) {
    size_t len; const unsigned char *text = (const unsigned char *)luaL_checklstring(L, 1, &len);
    uint32_t state[5] = {UINT32_C(0x67452301),UINT32_C(0xefcdab89),UINT32_C(0x98badcfe),UINT32_C(0x10325476),UINT32_C(0xc3d2e1f0)};
    size_t pos = 0;
    while (len - pos >= 64) { es_sha_block(state, text + pos); pos += 64; }
    unsigned char tail[128] = {0}; size_t remain = len - pos;
    memcpy(tail, text + pos, remain); tail[remain] = 0x80;
    size_t total = remain < 56 ? 64 : 128; uint64_t bits = (uint64_t)len * 8;
    for (unsigned i = 0; i < 8; i++) { tail[total - i - 1] = (unsigned char)bits; bits >>= 8; }
    es_sha_block(state, tail); if (total == 128) es_sha_block(state, tail + 64);
    const char *digits = "0123456789abcdef"; char digest[40];
    for (unsigned i = 0; i < 20; i++) { unsigned byte = (state[i / 4] >> (24 - (i % 4) * 8)) & 255; digest[i * 2] = digits[byte >> 4]; digest[i * 2 + 1] = digits[byte & 15]; }
    lua_pushlstring(L, digest, sizeof(digest)); return 1;
}
