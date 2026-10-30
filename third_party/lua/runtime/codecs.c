#include "internal.h"

typedef struct es_codec_input { const unsigned char *data; size_t len, pos; } es_codec_input;

static void es_codec_depth(lua_State *L, unsigned depth) {
    if (depth > es_context_of(L)->options.max_depth || !lua_checkstack(L, 12))
        es_fail(L, ESLUA_LIMIT, "codec nesting limit exceeded");
}

static void es_codec_cycle(lua_State *L, int index, unsigned depth, const void **path) {
    const void *id = lua_topointer(L, index);
    for (unsigned i = 0; i < depth; i++) if (path[i] == id) luaL_error(L, "cannot encode a cyclic table");
    path[depth] = id;
}

static int es_utf8_valid(const unsigned char *s, size_t len) {
    size_t i = 0;
    while (i < len) {
        uint32_t value = s[i++]; unsigned count;
        if (value < 0x80) continue;
        if (value >= 0xc2 && value <= 0xdf) { value &= 31; count = 1; }
        else if (value >= 0xe0 && value <= 0xef) { value &= 15; count = 2; }
        else if (value >= 0xf0 && value <= 0xf4) { value &= 7; count = 3; }
        else return 0;
        if (count > len - i) return 0;
        unsigned need = count;
        while (count--) { unsigned byte = s[i++]; if ((byte & 0xc0) != 0x80) return 0; value = (value << 6) | (byte & 63); }
        if ((need == 1 && value < 0x80) || (need == 2 && value < 0x800) || (need == 3 && value < 0x10000) || value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff)) return 0;
    }
    return 1;
}

static void es_json_string(lua_State *L, es_buffer *out, const unsigned char *s, size_t len) {
    if (!es_utf8_valid(s, len)) luaL_error(L, "invalid UTF-8 in JSON string");
    const char *hex = "0123456789abcdef";
    es_byte(L, out, '"');
    for (size_t i = 0; i < len; i++) {
        unsigned char byte = s[i];
        if (byte == '"' || byte == '\\') { es_byte(L, out, '\\'); es_byte(L, out, byte); }
        else if (byte < 32) { unsigned char escaped[6] = {'\\','u','0','0',(unsigned char)hex[byte >> 4],(unsigned char)hex[byte & 15]}; es_append(L, out, escaped, 6); }
        else es_byte(L, out, byte);
    }
    es_byte(L, out, '"');
}

static size_t es_table_shape(lua_State *L, int index, int *array) {
    size_t count = 0, len = lua_rawlen(L, index); *array = len != 0;
    lua_pushnil(L);
    while (lua_next(L, index)) {
        if (count >= es_context_of(L)->options.output_limit / 2) es_fail(L, ESLUA_LIMIT, "too many codec entries");
        count++;
        if (!lua_isinteger(L, -2) || lua_tointeger(L, -2) < 1 || (uint64_t)lua_tointeger(L, -2) > len) *array = 0;
        lua_pop(L, 1);
    }
    if (count != len) *array = 0;
    return count;
}

static void es_json_value(lua_State *L, int index, es_buffer *out, unsigned depth, const void **path) {
    es_codec_depth(L, depth); index = lua_absindex(L, index);
    switch (lua_type(L, index)) {
    case LUA_TNIL: es_append(L, out, "null", 4); return;
    case LUA_TLIGHTUSERDATA:
        if (lua_touserdata(L, index) != &es_null_token) luaL_error(L, "unsupported JSON userdata");
        es_append(L, out, "null", 4); return;
    case LUA_TBOOLEAN: es_append(L, out, lua_toboolean(L, index) ? "true" : "false", lua_toboolean(L, index) ? 4 : 5); return;
    case LUA_TSTRING: {
        size_t len; const unsigned char *s = (const unsigned char *)lua_tolstring(L, index, &len); es_json_string(L, out, s, len); return;
    }
    case LUA_TNUMBER: {
        char text[64]; int n;
        if (lua_isinteger(L, index)) n = snprintf(text, sizeof(text), "%lld", (long long)lua_tointeger(L, index));
        else { double value = lua_tonumber(L, index); if (!isfinite(value)) luaL_error(L, "JSON cannot encode non-finite numbers"); n = snprintf(text, sizeof(text), "%.17g", value); }
        if (n < 0 || (size_t)n >= sizeof(text)) luaL_error(L, "JSON number too large");
        es_append(L, out, text, (size_t)n); return;
    }
    case LUA_TTABLE: break;
    default: luaL_error(L, "unsupported JSON value");
    }
    es_codec_cycle(L, index, depth, path);
    int array; size_t count = es_table_shape(L, index, &array);
    es_byte(L, out, array ? '[' : '{');
    if (array) {
        for (size_t i = 0; i < count; i++) { if (i) es_byte(L, out, ','); lua_rawgeti(L, index, (lua_Integer)i + 1); es_json_value(L, -1, out, depth + 1, path); lua_pop(L, 1); }
    } else {
        size_t i = 0; lua_pushnil(L);
        while (lua_next(L, index)) {
            if (lua_type(L, -2) != LUA_TSTRING) luaL_error(L, "JSON object keys must be strings");
            if (i++) es_byte(L, out, ',');
            size_t len; const unsigned char *key = (const unsigned char *)lua_tolstring(L, -2, &len);
            es_json_string(L, out, key, len); es_byte(L, out, ':'); es_json_value(L, -1, out, depth + 1, path); lua_pop(L, 1);
        }
    }
    es_byte(L, out, array ? ']' : '}');
}

static int es_json_encode(lua_State *L) {
    luaL_checkany(L, 1); es_buffer out = {0}; const void *path[257] = {0};
    es_json_value(L, 1, &out, 0, path); lua_pushlstring(L, (const char *)out.data, out.len); es_release(es_context_of(L), out.data); return 1;
}

static void es_json_space(es_codec_input *in) { while (in->pos < in->len && (in->data[in->pos] == ' ' || in->data[in->pos] == '\t' || in->data[in->pos] == '\r' || in->data[in->pos] == '\n')) in->pos++; }
static int es_json_hex(unsigned char byte) { return byte >= '0' && byte <= '9' ? byte - '0' : byte >= 'a' && byte <= 'f' ? byte - 'a' + 10 : byte >= 'A' && byte <= 'F' ? byte - 'A' + 10 : -1; }

static uint32_t es_json_u16(lua_State *L, es_codec_input *in) {
    if (in->len - in->pos < 4) luaL_error(L, "incomplete JSON Unicode escape");
    uint32_t value = 0;
    for (unsigned i = 0; i < 4; i++) { int digit = es_json_hex(in->data[in->pos++]); if (digit < 0) luaL_error(L, "invalid JSON Unicode escape"); value = value * 16 + (unsigned)digit; }
    return value;
}

static void es_json_utf8(lua_State *L, es_buffer *out, uint32_t value) {
    unsigned char bytes[4]; size_t count;
    if (value < 0x80) { bytes[0] = (unsigned char)value; count = 1; }
    else if (value < 0x800) { bytes[0] = 0xc0 | (value >> 6); bytes[1] = 0x80 | (value & 63); count = 2; }
    else if (value < 0x10000) { bytes[0] = 0xe0 | (value >> 12); bytes[1] = 0x80 | ((value >> 6) & 63); bytes[2] = 0x80 | (value & 63); count = 3; }
    else { bytes[0] = 0xf0 | (value >> 18); bytes[1] = 0x80 | ((value >> 12) & 63); bytes[2] = 0x80 | ((value >> 6) & 63); bytes[3] = 0x80 | (value & 63); count = 4; }
    es_append(L, out, bytes, count);
}

static void es_json_read_string(lua_State *L, es_codec_input *in) {
    if (in->pos >= in->len || in->data[in->pos++] != '"') luaL_error(L, "expected JSON string");
    es_buffer out = {0}; int closed = 0;
    while (in->pos < in->len) {
        unsigned char byte = in->data[in->pos++];
        if (byte == '"') { closed = 1; break; }
        if (byte < 32) luaL_error(L, "unescaped JSON control character");
        if (byte != '\\') { es_byte(L, &out, byte); continue; }
        if (in->pos >= in->len) luaL_error(L, "incomplete JSON escape");
        byte = in->data[in->pos++];
        switch (byte) {
        case '"': case '\\': case '/': es_byte(L, &out, byte); break;
        case 'b': es_byte(L, &out, '\b'); break;
        case 'f': es_byte(L, &out, '\f'); break;
        case 'n': es_byte(L, &out, '\n'); break;
        case 'r': es_byte(L, &out, '\r'); break;
        case 't': es_byte(L, &out, '\t'); break;
        case 'u': {
            uint32_t value = es_json_u16(L, in);
            if (value >= 0xd800 && value <= 0xdbff) {
                if (in->len - in->pos < 2 || in->data[in->pos] != '\\' || in->data[in->pos + 1] != 'u') luaL_error(L, "missing JSON low surrogate");
                in->pos += 2; uint32_t low = es_json_u16(L, in);
                if (low < 0xdc00 || low > 0xdfff) luaL_error(L, "invalid JSON low surrogate");
                value = 0x10000 + ((value - 0xd800) << 10) + low - 0xdc00;
            } else if (value >= 0xdc00 && value <= 0xdfff) luaL_error(L, "unexpected JSON low surrogate");
            es_json_utf8(L, &out, value); break;
        }
        default: luaL_error(L, "invalid JSON escape");
        }
    }
    if (!closed || !es_utf8_valid(out.data, out.len)) luaL_error(L, "invalid JSON string");
    lua_pushlstring(L, out.data ? (const char *)out.data : "", out.len); es_release(es_context_of(L), out.data);
}

static int es_json_digit(es_codec_input *in) { return in->pos < in->len && in->data[in->pos] >= '0' && in->data[in->pos] <= '9'; }

static void es_json_number(lua_State *L, es_codec_input *in) {
    size_t begin = in->pos;
    if (in->data[in->pos] == '-') in->pos++;
    if (!es_json_digit(in)) luaL_error(L, "invalid JSON number");
    if (in->data[in->pos] == '0') in->pos++;
    else while (es_json_digit(in)) in->pos++;
    if (in->pos < in->len && in->data[in->pos] == '.') { in->pos++; if (!es_json_digit(in)) luaL_error(L, "invalid JSON fraction"); while (es_json_digit(in)) in->pos++; }
    if (in->pos < in->len && (in->data[in->pos] == 'e' || in->data[in->pos] == 'E')) {
        in->pos++; if (in->pos < in->len && (in->data[in->pos] == '+' || in->data[in->pos] == '-')) in->pos++;
        if (!es_json_digit(in)) luaL_error(L, "invalid JSON exponent");
        while (es_json_digit(in)) in->pos++;
    }
    size_t len = in->pos - begin;
    if (len > 1024) luaL_error(L, "JSON number too long");
    char text[1025]; memcpy(text, in->data + begin, len); text[len] = 0;
    if (!lua_stringtonumber(L, text) || !isfinite(lua_tonumber(L, -1))) luaL_error(L, "JSON number out of range");
}

static void es_json_parse(lua_State *L, es_codec_input *in, unsigned depth) {
    es_codec_depth(L, depth); es_json_space(in);
    if (in->pos == in->len) luaL_error(L, "incomplete JSON value");
    unsigned char byte = in->data[in->pos];
    if (byte == '"') { es_json_read_string(L, in); return; }
    if (byte == '-' || (byte >= '0' && byte <= '9')) { es_json_number(L, in); return; }
    const char *literals[] = {"null", "false", "true"};
    for (unsigned i = 0; i < 3; i++) {
        size_t n = strlen(literals[i]);
        if (in->len - in->pos >= n && memcmp(in->data + in->pos, literals[i], n) == 0) {
            in->pos += n; if (i == 0) lua_pushlightuserdata(L, &es_null_token); else lua_pushboolean(L, i == 2); return;
        }
    }
    if (byte != '[' && byte != '{') luaL_error(L, "invalid JSON value");
    int object = byte == '{'; in->pos++; lua_newtable(L); int table = lua_absindex(L, -1); lua_Integer count = 0;
    es_json_space(in);
    if (in->pos < in->len && in->data[in->pos] == (object ? '}' : ']')) { in->pos++; return; }
    for (;;) {
        if (object) {
            es_json_read_string(L, in); es_json_space(in);
            if (in->pos == in->len || in->data[in->pos++] != ':') luaL_error(L, "missing JSON object colon");
            es_json_parse(L, in, depth + 1); lua_rawset(L, table);
        } else { es_json_parse(L, in, depth + 1); lua_rawseti(L, table, ++count); }
        es_json_space(in);
        if (in->pos == in->len) luaL_error(L, "incomplete JSON container");
        byte = in->data[in->pos++];
        if (byte == (object ? '}' : ']')) return;
        if (byte != ',') luaL_error(L, "missing JSON comma");
        es_json_space(in);
    }
}

static int es_json_decode(lua_State *L) {
    es_codec_input in = {0}; in.data = (const unsigned char *)luaL_checklstring(L, 1, &in.len);
    es_json_parse(L, &in, 0); es_json_space(&in); if (in.pos != in.len) return luaL_error(L, "extra JSON input"); return 1;
}

static void es_msg_integer(lua_State *L, es_buffer *out, unsigned char tag, uint64_t value, unsigned bytes) {
    es_byte(L, out, tag); unsigned char data[8];
    for (unsigned i = 0; i < bytes; i++) { data[bytes - i - 1] = (unsigned char)value; value >>= 8; }
    es_append(L, out, data, bytes);
}

static void es_msg_length(lua_State *L, es_buffer *out, size_t len, int kind) {
    if (len > UINT32_MAX) es_fail(L, ESLUA_LIMIT, "MessagePack value too large");
    if (kind == 0 && len < 32) es_byte(L, out, 0xa0 | (unsigned char)len);
    else if (kind == 1 && len < 16) es_byte(L, out, 0x90 | (unsigned char)len);
    else if (kind == 2 && len < 16) es_byte(L, out, 0x80 | (unsigned char)len);
    else if (kind == 0 && len <= UINT8_MAX) es_msg_integer(L, out, 0xd9, len, 1);
    else if (len <= UINT16_MAX) es_msg_integer(L, out, kind == 0 ? 0xda : kind == 1 ? 0xdc : 0xde, len, 2);
    else es_msg_integer(L, out, kind == 0 ? 0xdb : kind == 1 ? 0xdd : 0xdf, len, 4);
}

static void es_msg_encode(lua_State *L, int index, es_buffer *out, unsigned depth, const void **path) {
    es_codec_depth(L, depth); index = lua_absindex(L, index);
    switch (lua_type(L, index)) {
    case LUA_TNIL: es_byte(L, out, 0xc0); return;
    case LUA_TLIGHTUSERDATA:
        if (lua_touserdata(L, index) != &es_null_token) luaL_error(L, "unsupported MessagePack userdata");
        es_byte(L, out, 0xc0); return;
    case LUA_TBOOLEAN: es_byte(L, out, lua_toboolean(L, index) ? 0xc3 : 0xc2); return;
    case LUA_TSTRING: {
        size_t len; const char *s = lua_tolstring(L, index, &len); es_msg_length(L, out, len, 0); es_append(L, out, s, len); return;
    }
    case LUA_TNUMBER:
        if (lua_isinteger(L, index)) {
            int64_t value = (int64_t)lua_tointeger(L, index);
            if (value >= 0) {
                uint64_t n = (uint64_t)value;
                if (n < 128) es_byte(L, out, (unsigned char)n);
                else es_msg_integer(L, out, n <= UINT8_MAX ? 0xcc : n <= UINT16_MAX ? 0xcd : n <= UINT32_MAX ? 0xce : 0xcf, n, n <= UINT8_MAX ? 1 : n <= UINT16_MAX ? 2 : n <= UINT32_MAX ? 4 : 8);
            } else if (value >= -32) es_byte(L, out, (unsigned char)value);
            else es_msg_integer(L, out, value >= INT8_MIN ? 0xd0 : value >= INT16_MIN ? 0xd1 : value >= INT32_MIN ? 0xd2 : 0xd3, (uint64_t)value, value >= INT8_MIN ? 1 : value >= INT16_MIN ? 2 : value >= INT32_MIN ? 4 : 8);
        } else {
            double value = lua_tonumber(L, index);
            if (isfinite(value) && value >= -9223372036854775808.0 && value < 9223372036854775808.0 && trunc(value) == value) {
                lua_pushinteger(L, (lua_Integer)value); es_msg_encode(L, -1, out, depth, path); lua_pop(L, 1);
            } else { uint64_t bits; memcpy(&bits, &value, 8); es_msg_integer(L, out, 0xcb, bits, 8); }
        }
        return;
    case LUA_TTABLE: break;
    default: luaL_error(L, "unsupported MessagePack value");
    }
    es_codec_cycle(L, index, depth, path); int array; size_t count = es_table_shape(L, index, &array);
    if (!count) array = 1;
    es_msg_length(L, out, count, array ? 1 : 2);
    if (array) {
        for (size_t i = 0; i < count; i++) { lua_rawgeti(L, index, (lua_Integer)i + 1); es_msg_encode(L, -1, out, depth + 1, path); lua_pop(L, 1); }
    } else {
        lua_pushnil(L); while (lua_next(L, index)) { es_msg_encode(L, -2, out, depth + 1, path); es_msg_encode(L, -1, out, depth + 1, path); lua_pop(L, 1); }
    }
}

static uint64_t es_msg_read(lua_State *L, es_codec_input *in, unsigned bytes) {
    if (in->len - in->pos < bytes) luaL_error(L, "truncated MessagePack number");
    uint64_t value = 0; for (unsigned i = 0; i < bytes; i++) value = (value << 8) | in->data[in->pos++]; return value;
}

static void es_msg_decode(lua_State *L, es_codec_input *in, unsigned depth) {
    es_codec_depth(L, depth);
    if (in->pos == in->len) luaL_error(L, "truncated MessagePack value");
    unsigned tag = in->data[in->pos++]; uint64_t count = 0; int kind = 0;
    if (tag < 0x80) { lua_pushinteger(L, tag); return; }
    if (tag >= 0xe0) { lua_pushinteger(L, (int)tag - 256); return; }
    if ((tag & 0xe0) == 0xa0) { count = tag & 31; kind = 1; }
    else if ((tag & 0xf0) == 0x90) { count = tag & 15; kind = 2; }
    else if ((tag & 0xf0) == 0x80) { count = tag & 15; kind = 3; }
    else switch (tag) {
    case 0xc0: lua_pushnil(L); return;
    case 0xc2: case 0xc3: lua_pushboolean(L, tag == 0xc3); return;
    case 0xcc: case 0xcd: case 0xce: case 0xcf: {
        uint64_t value = es_msg_read(L, in, 1u << (tag - 0xcc));
        if (value > INT64_MAX) lua_pushnumber(L, (lua_Number)value); else lua_pushinteger(L, (lua_Integer)value); return;
    }
    case 0xd0: case 0xd1: case 0xd2: case 0xd3: {
        unsigned bytes = 1u << (tag - 0xd0); uint64_t value = es_msg_read(L, in, bytes);
        if (bytes < 8 && (value & (UINT64_C(1) << (bytes * 8 - 1)))) value |= UINT64_MAX << (bytes * 8);
        int64_t signed_value; memcpy(&signed_value, &value, sizeof(value)); lua_pushinteger(L, (lua_Integer)signed_value); return;
    }
    case 0xca: { uint32_t bits = (uint32_t)es_msg_read(L, in, 4); float value; memcpy(&value, &bits, 4); lua_pushnumber(L, value); return; }
    case 0xcb: { uint64_t bits = es_msg_read(L, in, 8); double value; memcpy(&value, &bits, 8); lua_pushnumber(L, value); return; }
    case 0xc4: case 0xd9: count = es_msg_read(L, in, 1); kind = 1; break;
    case 0xc5: case 0xda: count = es_msg_read(L, in, 2); kind = 1; break;
    case 0xc6: case 0xdb: count = es_msg_read(L, in, 4); kind = 1; break;
    case 0xdc: case 0xdd: count = es_msg_read(L, in, tag == 0xdc ? 2 : 4); kind = 2; break;
    case 0xde: case 0xdf: count = es_msg_read(L, in, tag == 0xde ? 2 : 4); kind = 3; break;
    default: luaL_error(L, "unsupported MessagePack tag");
    }
    if (kind == 1) {
        if (count > in->len - in->pos) luaL_error(L, "truncated MessagePack string");
        lua_pushlstring(L, (const char *)in->data + in->pos, (size_t)count); in->pos += (size_t)count; return;
    }
    if (count > INT_MAX || count > (in->len - in->pos) / (kind == 3 ? 2 : 1)) luaL_error(L, "invalid MessagePack container length");
    lua_createtable(L, kind == 2 ? (int)count : 0, kind == 3 ? (int)count : 0); int table = lua_absindex(L, -1);
    for (uint64_t i = 0; i < count; i++) {
        es_msg_decode(L, in, depth + 1);
        if (kind == 2) lua_rawseti(L, table, (lua_Integer)i + 1);
        else { if (lua_isnil(L, -1)) luaL_error(L, "nil MessagePack map key"); es_msg_decode(L, in, depth + 1); lua_rawset(L, table); }
    }
}

static int es_msg_pack(lua_State *L) {
    int argc = lua_gettop(L); if (argc < 1) return luaL_error(L, "cmsgpack.pack requires a value");
    es_buffer out = {0}; const void *path[257] = {0};
    for (int i = 1; i <= argc; i++) es_msg_encode(L, i, &out, 0, path);
    lua_pushlstring(L, out.data ? (const char *)out.data : "", out.len); es_release(es_context_of(L), out.data); return 1;
}

static int es_msg_unpack(lua_State *L) {
    es_codec_input in = {0}; in.data = (const unsigned char *)luaL_checklstring(L, 1, &in.len);
    int count = 0;
    while (in.pos < in.len) {
        if (count == INT_MAX) return es_fail(L, ESLUA_LIMIT, "too many MessagePack values");
        es_msg_decode(L, &in, 0); count++;
    }
    return count;
}

void es_install_codecs(lua_State *L) {
    lua_newtable(L); lua_pushcfunction(L, es_json_encode); lua_setfield(L, -2, "encode"); lua_pushcfunction(L, es_json_decode); lua_setfield(L, -2, "decode");
    lua_pushlightuserdata(L, &es_null_token); lua_setfield(L, -2, "null"); lua_setglobal(L, "cjson");
    lua_newtable(L); lua_pushcfunction(L, es_msg_pack); lua_setfield(L, -2, "pack"); lua_pushcfunction(L, es_msg_unpack); lua_setfield(L, -2, "unpack"); lua_setglobal(L, "cmsgpack");
}
