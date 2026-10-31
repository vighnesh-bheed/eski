#include "internal.h"

typedef struct es_reader {
    const unsigned char *data;
    size_t len, pos;
} es_reader;

static void es_depth(lua_State *L, unsigned depth) {
    if (depth > es_context_of(L)->options.max_depth || !lua_checkstack(L, 12))
        es_fail(L, ESLUA_LIMIT, "script response nesting limit exceeded");
}

static void es_integer(lua_State *L, es_buffer *out, unsigned char prefix, int64_t value) {
    char text[64];
    int n = snprintf(text, sizeof(text), "%c%lld\r\n", prefix, (long long)value);
    if (n < 0 || (size_t)n >= sizeof(text)) es_fail(L, ESLUA_LIMIT, "response integer overflow");
    es_append(L, out, text, (size_t)n);
}

static void es_bulk(lua_State *L, es_buffer *out, const char *data, size_t len) {
    if (len > INT64_MAX) es_fail(L, ESLUA_LIMIT, "response string too large");
    es_integer(L, out, '$', (int64_t)len); es_append(L, out, data, len); es_append(L, out, "\r\n", 2);
}

static void es_record_error(lua_State *L, es_buffer *out, const char *data, size_t len, int forwarded) {
    es_context *ctx = es_context_of(L);
    const char *zero = memchr(data, 0, len);
    if (zero) len = (size_t)(zero-data);
    if (ctx->error_count == ctx->error_capacity) {
        size_t capacity = ctx->error_capacity ? ctx->error_capacity*2 : 8;
        if (capacity < ctx->error_capacity || capacity > SIZE_MAX/sizeof(*ctx->errors))
            es_fail(L, ESLUA_LIMIT, "too many error replies");
        eslua_error_event *errors = es_allocate(ctx, ctx->errors, capacity*sizeof(*errors));
        if (!errors) es_fail(L, ESLUA_MEMORY, "script error metadata allocation failed");
        ctx->errors = errors;
        ctx->error_capacity = capacity;
        es_transient(ctx, errors);
    }
    ctx->errors[ctx->error_count++] = (eslua_error_event){out->len+1, len, forwarded};
}

static void es_line(lua_State *L, es_buffer *out, unsigned char prefix, const char *data, size_t len) {
    if(prefix=='+'||prefix=='-'){const char *zero=memchr(data,0,len);if(zero)len=(size_t)(zero-data);}
    es_byte(L, out, prefix);
    for (size_t i = 0; i < len; i++) es_byte(L, out, data[i] == '\r' || data[i] == '\n' ? ' ' : (unsigned char)data[i]);
    es_append(L, out, "\r\n", 2);
}

static int es_rawfield(lua_State *L, int index, const char *key) {
    lua_pushstring(L, key); lua_rawget(L, index); return lua_type(L, -1);
}

typedef struct es_reply_frame {
    int index, restore_top, kind, table, phase;
    size_t count, position;
} es_reply_frame;

static int es_encode_value(lua_State *L, es_reply_frame *frame, int resp, es_buffer *out, unsigned depth) {
    int index = frame->index;
    if (depth > es_context_of(L)->options.max_depth) es_fail(L, ESLUA_LIMIT, "script response nesting limit exceeded");
    if (!lua_checkstack(L, 12)) {
        const char *message = "ERR reached lua stack limit";
        es_record_error(L, out, message, strlen(message), 0);
        es_line(L, out, '-', message, strlen(message));
        return 0;
    }
    index = lua_absindex(L, index);
    int type = lua_type(L, index);
    switch (type) {
    case LUA_TNIL:
        es_append(L, out, resp == 3 ? "_\r\n" : "$-1\r\n", resp == 3 ? 3 : 5); return 0;
    case LUA_TLIGHTUSERDATA:
        es_append(L, out, resp == 3 ? "_\r\n" : "$-1\r\n", resp == 3 ? 3 : 5); return 0;
    case LUA_TBOOLEAN:
        if (es_context_of(L)->script_resp == 2) {
            if (lua_toboolean(L, index)) es_integer(L, out, ':', 1);
            else es_append(L, out, resp == 3 ? "_\r\n" : "$-1\r\n", resp == 3 ? 3 : 5);
        } else if (resp == 3) es_append(L, out, lua_toboolean(L, index) ? "#t\r\n" : "#f\r\n", 4);
        else es_integer(L, out, ':', lua_toboolean(L, index) ? 1 : 0);
        return 0;
    case LUA_TSTRING: {
        size_t len; const char *s = lua_tolstring(L, index, &len); es_bulk(L, out, s, len); return 0;
    }
    case LUA_TNUMBER: {
        int64_t value;
        if (lua_isinteger(L, index)) value = (int64_t)lua_tointeger(L, index);
        else {
            double number = lua_tonumber(L, index);
            if (!isfinite(number) || number < -9223372036854775808.0 || number >= 9223372036854775808.0)
                value = INT64_MIN;
            else value = (int64_t)number;
        }
        es_integer(L, out, ':', value); return 0;
    }
    case LUA_TTABLE: break;
    default: es_append(L, out, resp == 3 ? "_\r\n" : "$-1\r\n", resp == 3 ? 3 : 5); return 0;
    }

    if (es_rawfield(L, index, "err") == LUA_TSTRING) {
        es_rawfield(L, index, "ignore_error_stats_update");
        int forwarded = lua_type(L, -1) == LUA_TBOOLEAN && lua_toboolean(L, -1);
        lua_pop(L, 1);
        if (depth == 0) es_context_of(L)->forwarded_error = forwarded;
        size_t len; const char *s = lua_tolstring(L, -1, &len);
        es_record_error(L, out, s, len, forwarded);
        es_line(L, out, '-', s, len); lua_pop(L, 1); return 0;
    }
    lua_pop(L, 1);
    if (es_rawfield(L, index, "ok") == LUA_TSTRING) {
        size_t len; const char *s = lua_tolstring(L, -1, &len); es_line(L, out, '+', s, len); lua_pop(L, 1); return 0;
    }
    lua_pop(L, 1);
    if (es_rawfield(L, index, "double") == LUA_TNUMBER) {
        double value = lua_tonumber(L, -1); char text[64];
        int n = isnan(value) ? snprintf(text, sizeof(text), "nan") : isinf(value) ? snprintf(text, sizeof(text), "%sinf", value < 0 ? "-" : "") : snprintf(text, sizeof(text), "%.17g", value);
        if (n < 0 || (size_t)n >= sizeof(text)) luaL_error(L, "invalid double reply");
        if (resp == 3) es_line(L, out, ',', text, (size_t)n); else es_bulk(L, out, text, (size_t)n);
        lua_pop(L, 1); return 0;
    }
    lua_pop(L, 1);
    if (es_rawfield(L, index, "big_number") == LUA_TSTRING) {
        size_t len; const char *s = lua_tolstring(L, -1, &len);
        if (resp == 3) es_line(L, out, '(', s, len);
        else {
            if (len > INT64_MAX) es_fail(L, ESLUA_LIMIT, "response string too large");
            es_integer(L, out, '$', (int64_t)len);
            for (size_t i = 0; i < len; i++) es_byte(L, out, s[i] == '\r' || s[i] == '\n' ? ' ' : (unsigned char)s[i]);
            es_append(L, out, "\r\n", 2);
        }
        lua_pop(L, 1); return 0;
    }
    lua_pop(L, 1);
    if (es_rawfield(L, index, "verbatim_string") == LUA_TTABLE) {
        int table = lua_absindex(L, -1);
        es_rawfield(L, table, "format"); es_rawfield(L, table, "string");
        if (lua_type(L, -2) != LUA_TSTRING || lua_type(L, -1) != LUA_TSTRING) luaL_error(L, "invalid verbatim reply");
        size_t flen, len; const char *format = lua_tolstring(L, -2, &flen); const char *s = lua_tolstring(L, -1, &len);
        if (flen != 3) luaL_error(L, "verbatim format must have three bytes");
        if (resp == 3) {
            if (len > INT64_MAX - 4) es_fail(L, ESLUA_LIMIT, "verbatim reply too large");
            es_integer(L, out, '=', (int64_t)len + 4); es_append(L, out, format, 3); es_byte(L, out, ':'); es_append(L, out, s, len); es_append(L, out, "\r\n", 2);
        } else es_bulk(L, out, s, len);
        lua_pop(L, 3); return 0;
    }
    lua_pop(L, 1);
    const char *tags[] = {"map", "set"};
    for (int kind = 0; kind < 2; kind++) {
        if (es_rawfield(L, index, tags[kind]) == LUA_TTABLE) {
            int table = lua_absindex(L, -1); size_t count = 0;
            lua_pushnil(L);
            while (lua_next(L, table)) {
                if (count >= es_context_of(L)->options.output_limit / 3) es_fail(L, ESLUA_LIMIT, "too many reply entries");
                count++; lua_pop(L, 1);
            }
            if (count > INT64_MAX / 2) es_fail(L, ESLUA_LIMIT, "too many reply entries");
            es_integer(L, out, resp == 3 ? (kind == 0 ? '%' : '~') : '*', (int64_t)count * (resp == 2 && kind == 0 ? 2 : 1));
            frame->kind = kind + 1; frame->table = table; frame->phase = 0;
            lua_pushnil(L); return 1;
        }
        lua_pop(L, 1);
    }
    size_t count = 0;
    for (;;) {
        if (count >= es_context_of(L)->options.output_limit / 3) es_fail(L, ESLUA_LIMIT, "too many reply entries");
        lua_rawgeti(L, index, (int)count + 1);
        int nil = lua_isnil(L, -1); lua_pop(L, 1);
        if (nil) break;
        count++;
    }
    es_integer(L, out, '*', (int64_t)count);
    frame->kind = 0; frame->table = index; frame->count = count; frame->position = 0;
    return 1;
}

void es_serialize(lua_State *L, int index, int resp, es_buffer *out) {
    es_context *ctx = es_context_of(L);
    size_t capacity = 64, depth = 1;
    es_reply_frame *frames = es_allocate(ctx, NULL, capacity*sizeof(*frames));
    if (!frames) es_fail(L, ESLUA_MEMORY, "script memory limit exceeded");
    es_transient(ctx, frames);
    int restore_top = lua_gettop(L);
    index = lua_absindex(L, index);
    frames[0] = (es_reply_frame){.index=index, .restore_top=restore_top, .kind=-1};
    while (depth) {
        es_reply_frame *frame = &frames[depth-1];
        if (frame->kind == -1) {
            if (!es_encode_value(L, frame, resp, out, (unsigned)(depth-1))) {
                lua_settop(L, frame->restore_top); depth--; continue;
            }
        }
        int child_top = lua_gettop(L);
        if (frame->kind == 0) {
            if (frame->position >= frame->count) { lua_settop(L, frame->restore_top); depth--; continue; }
            lua_rawgeti(L, frame->table, (int)++frame->position);
        } else {
            if (frame->phase == 1) {
                if (frame->kind == 1) { frame->phase = 2; lua_pushvalue(L, -1); }
                else { lua_pop(L, 1); frame->phase = 0; continue; }
            } else if (frame->phase == 2) { lua_pop(L, 1); frame->phase = 0; continue; }
            else {
                if (!lua_next(L, frame->table)) { lua_settop(L, frame->restore_top); depth--; continue; }
                child_top = lua_gettop(L);
                frame->phase = 1; lua_pushvalue(L, -2);
            }
        }
        if (depth == capacity) {
            if (capacity > SIZE_MAX/(2*sizeof(*frames))) es_fail(L, ESLUA_MEMORY, "script reply stack limit exceeded");
            capacity *= 2;
            es_reply_frame *grown = es_allocate(ctx, frames, capacity*sizeof(*frames));
            if (!grown) es_fail(L, ESLUA_MEMORY, "script memory limit exceeded");
            frames = grown;
        }
        frames[depth++] = (es_reply_frame){.index=lua_gettop(L), .restore_top=child_top, .kind=-1};
    }
    es_release(ctx, frames);
}

static const unsigned char *es_read_line(lua_State *L, es_reader *in, size_t *len) {
    size_t begin = in->pos;
    while (in->pos < in->len) {
        if (in->data[in->pos] == '\r') {
            if (in->pos + 1 >= in->len || in->data[in->pos + 1] != '\n') break;
            *len = in->pos - begin; in->pos += 2; return in->data + begin;
        }
        if (in->data[in->pos] == '\n') break;
        in->pos++;
    }
    es_fail(L, ESLUA_BRIDGE, "malformed command response line"); return NULL;
}

static int64_t es_read_integer(lua_State *L, es_reader *in) {
    size_t len; const unsigned char *text = es_read_line(L, in, &len);
    int negative = len && text[0] == '-'; size_t first = negative ? 1 : 0;
    if (first == len) es_fail(L, ESLUA_BRIDGE, "malformed response integer");
    uint64_t value = 0, limit = negative ? UINT64_C(9223372036854775808) : INT64_MAX;
    for (size_t i = first; i < len; i++) {
        if (text[i] < '0' || text[i] > '9' || value > (limit - (text[i] - '0')) / 10) es_fail(L, ESLUA_BRIDGE, "response integer overflow");
        value = value * 10 + (text[i] - '0');
    }
    return negative ? (value == UINT64_C(9223372036854775808) ? INT64_MIN : -(int64_t)value) : (int64_t)value;
}

static const unsigned char *es_read_payload(lua_State *L, es_reader *in, size_t len) {
    if (len > in->len - in->pos || in->len - in->pos - len < 2 || in->data[in->pos + len] != '\r' || in->data[in->pos + len + 1] != '\n')
        es_fail(L, ESLUA_BRIDGE, "truncated command response");
    const unsigned char *data = in->data + in->pos; in->pos += len + 2; return data;
}

static void es_push_null(lua_State *L) {
    if (es_context_of(L)->script_resp == 3) lua_pushnil(L); else lua_pushboolean(L, 0);
}

static void es_decode(lua_State *L, es_reader *in, unsigned depth) {
    es_depth(L, depth);
    if (in->pos >= in->len) es_fail(L, ESLUA_BRIDGE, "empty command response");
    unsigned char tag = in->data[in->pos++];
    while (tag == '|') {
        int64_t count = es_read_integer(L, in);
        if (count < 0 || (uint64_t)count > (in->len - in->pos) / 6 || count > INT_MAX)
            es_fail(L, ESLUA_BRIDGE, "invalid attribute response length");
        for (int64_t i = 0; i < count; i++) {
            es_decode(L, in, depth + 1); lua_pop(L, 1);
            es_decode(L, in, depth + 1); lua_pop(L, 1);
        }
        if (in->pos >= in->len) es_fail(L, ESLUA_BRIDGE, "missing attributed command response");
        tag = in->data[in->pos++];
    }
    if (tag == ':') { lua_pushinteger(L, (lua_Integer)es_read_integer(L, in)); return; }
    if (tag == '+' || tag == '-' || tag == '(' || tag == ',') {
        size_t len; const unsigned char *text = es_read_line(L, in, &len);
        lua_createtable(L, 0, 1);
        if (tag == ',') {
            if (len >= 128) es_fail(L, ESLUA_BRIDGE, "invalid double command response");
            char number[128]; memcpy(number, text, len); number[len] = 0;
            char *end; double value = strtod(number, &end);
            if (end != number + len || len == 0) es_fail(L, ESLUA_BRIDGE, "invalid double command response");
            lua_pushnumber(L, value);
        } else lua_pushlstring(L, (const char *)text, len);
        lua_setfield(L, -2, tag == '+' ? "ok" : tag == '-' ? "err" : tag == '(' ? "big_number" : "double");
        if (tag == '-') { lua_pushboolean(L, 1); lua_setfield(L, -2, "ignore_error_stats_update"); }
        return;
    }
    if (tag == '_') { size_t len; es_read_line(L, in, &len); if (len) es_fail(L, ESLUA_BRIDGE, "invalid null response"); es_push_null(L); return; }
    if (tag == '#') {
        size_t len; const unsigned char *text = es_read_line(L, in, &len);
        if (len != 1 || (text[0] != 't' && text[0] != 'f')) es_fail(L, ESLUA_BRIDGE, "invalid boolean response");
        lua_pushboolean(L, text[0] == 't'); return;
    }
    if (tag == '$' || tag == '!' || tag == '=') {
        int64_t count = es_read_integer(L, in);
        if (count == -1 && tag == '$') { es_push_null(L); return; }
        if (count < 0 || (uint64_t)count > SIZE_MAX) es_fail(L, ESLUA_BRIDGE, "invalid bulk response length");
        size_t len = (size_t)count; const unsigned char *text = es_read_payload(L, in, len);
        if (tag == '$') lua_pushlstring(L, (const char *)text, len);
        else if (tag == '!') { lua_newtable(L); lua_pushlstring(L, (const char *)text, len); lua_setfield(L, -2, "err"); lua_pushboolean(L, 1); lua_setfield(L, -2, "ignore_error_stats_update"); }
        else {
            if (len < 4 || text[3] != ':') es_fail(L, ESLUA_BRIDGE, "invalid verbatim response");
            lua_newtable(L); lua_newtable(L); lua_pushlstring(L, (const char *)text, 3); lua_setfield(L, -2, "format");
            lua_pushlstring(L, (const char *)text + 4, len - 4); lua_setfield(L, -2, "string"); lua_setfield(L, -2, "verbatim_string");
        }
        return;
    }
    if (tag == '*' || tag == '%' || tag == '~') {
        int64_t count = es_read_integer(L, in);
        if (count == -1 && tag == '*') { es_push_null(L); return; }
        if (count < 0 || (uint64_t)count > (in->len - in->pos) / (tag == '%' ? 6 : 3) || count > INT_MAX)
            es_fail(L, ESLUA_BRIDGE, "invalid aggregate response length");
        if (tag != '*') lua_newtable(L);
        lua_createtable(L, tag == '*' ? (int)count : 0, tag == '*' ? 0 : (int)count);
        for (int64_t i = 0; i < count; i++) {
            es_decode(L, in, depth + 1);
            if (tag == '*') lua_rawseti(L, -2, (lua_Integer)i + 1);
            else {
                if (lua_isnil(L, -1)) es_fail(L, ESLUA_BRIDGE, "null map or set key");
                if (tag == '%') es_decode(L, in, depth + 1); else lua_pushboolean(L, 1);
                lua_rawset(L, -3);
            }
        }
        if (tag != '*') lua_setfield(L, -2, tag == '%' ? "map" : "set");
        return;
    }
    es_fail(L, ESLUA_BRIDGE, "unsupported command response type");
}

void es_parse_response(lua_State *L, const unsigned char *data, size_t len) {
    es_reader in = {data, len, 0}; es_decode(L, &in, 0);
    if (in.pos != in.len) es_fail(L, ESLUA_BRIDGE, "extra command response bytes");
}
