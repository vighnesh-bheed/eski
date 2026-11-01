#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <unistd.h>

static char recorded_ident[1024];
static int recorded_facility;
static int atfork_record = -1;

static void record_prepare(void) { if (atfork_record >= 0) (void)write(atfork_record, "PREPARE\n", 8); }
static void record_parent(void) { if (atfork_record >= 0) (void)write(atfork_record, "PARENT\n", 7); }
static void record_child(void) { if (atfork_record >= 0) (void)write(atfork_record, "CHILD\n", 6); }

__attribute__((constructor)) static void register_atfork_record(void) {
    const char *path = getenv("ESKI_TEST_ATFORK_RECORD");
    if (!path) return;
    atfork_record = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0600);
    if (atfork_record < 0) return;
    if (pthread_atfork(record_prepare, record_parent, record_child))
        (void)write(atfork_record, "REGISTERFAILED\n", 15);
}

void openlog(const char *ident, int options, int facility) {
    snprintf(recorded_ident, sizeof(recorded_ident), "%s", ident ? ident : "");
    recorded_facility = facility;
    const char *path = getenv("ESKI_TEST_SYSLOG_RECORD");
    if (!path) return;
    int fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0600);
    if (fd < 0) return;
    dprintf(fd, "OPEN|%d|%d|%s\n", options, facility, recorded_ident);
    close(fd);
}

void syslog(int priority, const char *format, ...) {
    const char *path = getenv("ESKI_TEST_SYSLOG_RECORD");
    if (!path) return;
    int fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0600);
    if (fd < 0) return;
    dprintf(fd, "LOG|%d|%d|%s|", priority, recorded_facility, recorded_ident);
    va_list arguments;
    va_start(arguments, format);
    vdprintf(fd, format, arguments);
    va_end(arguments);
    dprintf(fd, "\n");
    if (getenv("ESKI_TEST_SOCKET_MARKS")) {
        for (int candidate = 3; candidate < 128; candidate++) {
            struct sockaddr_storage address;
            socklen_t length = sizeof(address);
            if (getsockname(candidate, (struct sockaddr *)&address, &length)) continue;
            if (address.ss_family != AF_INET && address.ss_family != AF_INET6) continue;
            unsigned int mark = 0;
            socklen_t mark_length = sizeof(mark);
            if (!getsockopt(candidate, SOL_SOCKET, SO_MARK, &mark, &mark_length))
                dprintf(fd, "MARK|%d|%d|%u\n", candidate, address.ss_family, mark);
        }
    }
    close(fd);
}

void closelog(void) {
    const char *path = getenv("ESKI_TEST_SYSLOG_RECORD");
    if (!path) return;
    int fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0600);
    if (fd < 0) return;
    dprintf(fd, "CLOSE\n");
    close(fd);
}
