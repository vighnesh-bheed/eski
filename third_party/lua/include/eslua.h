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

typedef struct eslua_error_event {
    size_t offset;
    size_t len;
    int32_t forwarded;
} eslua_error_event;

typedef struct eslua_result {
    unsigned char *data;
    size_t len;
    int32_t write_effect;
    int32_t status;
    eslua_stats stats;
    int32_t forwarded_error;
    eslua_error_event *errors;
    size_t error_count;
    int32_t rejected;
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
    eslua_arg identifier;
    int32_t function_mode;
    int32_t debug_mode;
    int32_t enable_deprecated_api;
    int32_t isolate;
} eslua_options;

typedef eslua_result (*eslua_command_fn)(void *opaque, int32_t resp, size_t argc,
                                        const eslua_arg *args, const eslua_stats *stats);
typedef int32_t (*eslua_busy_fn)(void *opaque, int32_t wrote, const eslua_stats *stats);
typedef void (*eslua_log_fn)(void *opaque, int32_t level, size_t argc, const eslua_arg *args);

typedef eslua_result (*eslua_acl_fn)(void *opaque, size_t argc, const eslua_arg *args);
typedef int32_t (*eslua_propagation_fn)(void *opaque, int32_t mask);

typedef size_t (*eslua_number_fn)(double value, int32_t argument, unsigned char *out, size_t capacity);

typedef eslua_result (*eslua_debug_read_fn)(void *opaque);
typedef int32_t (*eslua_debug_write_fn)(void *opaque, eslua_arg frame);

typedef struct eslua_callbacks {
    eslua_command_fn command;
    eslua_busy_fn busy;
    eslua_log_fn log;
    void *opaque;
    eslua_acl_fn acl_check;
    eslua_propagation_fn propagation;
    eslua_debug_read_fn debug_read;
    eslua_debug_write_fn debug_write;
} eslua_callbacks;

typedef struct eslua_library eslua_library;
typedef struct eslua_library_load_result {
    eslua_library *library;
    eslua_result result;
} eslua_library_load_result;
typedef struct eslua_function_info {
    eslua_arg name;
    eslua_arg description;
    uint32_t flags;
} eslua_function_info;

eslua_library_load_result eslua_library_load(eslua_arg source, const eslua_options *options);
size_t eslua_library_count(eslua_library *library);
eslua_function_info eslua_library_info(eslua_library *library, size_t index);
eslua_result eslua_library_call(eslua_library *library, size_t index, size_t numkeys,
                                const eslua_arg *keys, size_t argc, const eslua_arg *args,
                                int32_t client_resp, const eslua_options *options,
                                const eslua_callbacks *callbacks);
void eslua_library_free(eslua_library *library);
eslua_stats eslua_library_stats(eslua_library *library);

eslua_result eslua_eval(eslua_arg source, size_t numkeys, const eslua_arg *keys,
                       size_t argc, const eslua_arg *args, int32_t client_resp,
                       const eslua_options *options, const eslua_callbacks *callbacks);
eslua_result eslua_compile(eslua_arg source, const eslua_options *options);
eslua_result eslua_eval_cached(eslua_arg source, eslua_arg digest, size_t numkeys, const eslua_arg *keys,
                              size_t argc, const eslua_arg *args, int32_t client_resp,
                              const eslua_options *options, const eslua_callbacks *callbacks);
eslua_result eslua_eval_prepare(eslua_arg source, eslua_arg digest, const eslua_options *options);
void eslua_eval_forget(eslua_arg digest);
void eslua_free_result(eslua_result *result);
const char *eslua_version(void);
void eslua_reset(void);
void eslua_functions_reset(void);
eslua_stats eslua_functions_stats(void);
eslua_stats eslua_functions_active_stats(void);
eslua_stats eslua_eval_stats(void);
eslua_stats eslua_eval_active_stats(void);
size_t eslua_detached_memory(void);
uint64_t eslua_random_exchange(uint64_t next);
void eslua_set_number_format(eslua_number_fn format);
void eslua_set_load_log(eslua_log_fn log);

#endif
