#include "internal.h"

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
    if (lua_gettop(L) != 1) { lua_pushliteral(L, "wrong number of arguments"); return lua_error(L); }
    size_t len = 0; const unsigned char *text = (const unsigned char *)lua_tolstring(L, 1, &len);
    if (!text) { text = (const unsigned char *)""; len = 0; }
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
