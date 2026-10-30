#ifndef ESLUA_H
#define ESLUA_H

#include <stddef.h>
#include <stdint.h>

typedef struct eslua_arg {
    const unsigned char *data;
    size_t len;
} eslua_arg;

typedef struct eslua_stats {
    size_t current_bytes;
    size_t peak_bytes;
    uint64_t instructions;
    uint64_t elapsed_ns;
} eslua_stats;

typedef struct eslua_result {
    unsigned char *data;
    size_t len;
    int32_t write_effect;
    int32_t status;
    eslua_stats stats;
} eslua_result;

enum eslua_status {
    ESLUA_OK = 0,
    ESLUA_ERROR = 1,
    ESLUA_MEMORY = 2,
    ESLUA_LIMIT = 3,
    ESLUA_KILLED = 4,
    ESLUA_ARGUMENT = 5,
    ESLUA_BRIDGE = 6
};

enum eslua_action {
    ESLUA_CONTINUE = 0,
    ESLUA_KILL_READONLY = 1,
    ESLUA_ABORT = 2
};

typedef struct eslua_options {
    size_t memory_limit;
    size_t output_limit;
    uint64_t instruction_limit;
    uint64_t busy_threshold_ms;
    uint32_t max_depth;
    uint32_t hook_count;
} eslua_options;

typedef eslua_result (*eslua_command_fn)(void *opaque, int32_t resp, size_t argc,
                                        const eslua_arg *args, const eslua_stats *stats);
typedef int32_t (*eslua_busy_fn)(void *opaque, int32_t wrote, const eslua_stats *stats);
typedef void (*eslua_log_fn)(void *opaque, int32_t level, size_t argc, const eslua_arg *args);

typedef struct eslua_callbacks {
    eslua_command_fn command;
    eslua_busy_fn busy;
    eslua_log_fn log;
    void *opaque;
} eslua_callbacks;

eslua_result eslua_eval(eslua_arg source, size_t numkeys, const eslua_arg *keys,
                       size_t argc, const eslua_arg *args, int32_t client_resp,
                       const eslua_options *options, const eslua_callbacks *callbacks);
eslua_result eslua_compile(eslua_arg source, const eslua_options *options);
void eslua_free_result(eslua_result *result);
const char *eslua_version(void);

#endif
