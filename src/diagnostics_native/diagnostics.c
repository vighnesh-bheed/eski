#define _GNU_SOURCE
#define UNW_LOCAL_ONLY
#include <libunwind.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <fcntl.h>
#include <time.h>
#include <elf.h>
#include <link.h>
#include <errno.h>
#include <stdio.h>
int eski_diag_capture_current(uintptr_t *, int);

typedef struct { uintptr_t begin, end; const char *name; size_t length; } EsdiagSymbol;
static EsdiagSymbol *esdiag_symbols;
static size_t esdiag_symbol_count, esdiag_symbol_bytes;
static char *esdiag_names;
static unsigned char *esdiag_scratch;
static _Atomic size_t esdiag_alt_bytes;
static _Thread_local void *esdiag_alt;
static _Thread_local size_t esdiag_alt_size;
static struct sigaction esdiag_previous[NSIG];
static unsigned char esdiag_installed[NSIG];

static int esdiag_base(struct dl_phdr_info *info, size_t size, void *data) {
    (void)size;
    if (!info->dlpi_name || !info->dlpi_name[0]) { *(uintptr_t *)data = info->dlpi_addr; return 1; }
    return 0;
}
static int esdiag_compare(const void *a, const void *b) {
    uintptr_t x = ((const EsdiagSymbol *)a)->begin, y = ((const EsdiagSymbol *)b)->begin;
    return (x > y) - (x < y);
}
static int esdiag_range(size_t size, uint64_t offset, uint64_t count, uint64_t width) {
    return offset <= size && width && count <= (size - offset) / width;
}
int eski_diag_symbols_init(void) {
    if (esdiag_symbols) return 1;
    int fd = open("/proc/self/exe", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return 0;
    struct stat st;
    if (fstat(fd, &st) || st.st_size < (off_t)sizeof(Elf64_Ehdr)) { close(fd); return 0; }
    size_t size = (size_t)st.st_size;
    unsigned char *data = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (data == MAP_FAILED) return 0;
    int result = 0;
    Elf64_Ehdr *eh = (Elf64_Ehdr *)data;
    if (memcmp(eh->e_ident, ELFMAG, SELFMAG) || eh->e_ident[EI_CLASS] != ELFCLASS64 ||
        eh->e_ident[EI_DATA] != ELFDATA2LSB || eh->e_shentsize != sizeof(Elf64_Shdr) ||
        !esdiag_range(size, eh->e_shoff, eh->e_shnum, sizeof(Elf64_Shdr))) goto done;
    Elf64_Shdr *sections = (Elf64_Shdr *)(data + eh->e_shoff), *table = NULL;
    for (size_t i = 0; i < eh->e_shnum; ++i) {
        if (sections[i].sh_type == SHT_SYMTAB) { table = &sections[i]; break; }
        if (sections[i].sh_type == SHT_DYNSYM) table = &sections[i];
    }
    if (!table || table->sh_link >= eh->e_shnum || table->sh_entsize != sizeof(Elf64_Sym) ||
        !esdiag_range(size, table->sh_offset, table->sh_size, 1)) goto done;
    Elf64_Shdr *strings = &sections[table->sh_link];
    if (!esdiag_range(size, strings->sh_offset, strings->sh_size, 1)) goto done;
    Elf64_Sym *symbols = (Elf64_Sym *)(data + table->sh_offset);
    const char *names = (const char *)(data + strings->sh_offset);
    size_t count = table->sh_size / sizeof(*symbols), valid = 0, bytes = 0;
    if (count > 1000000) goto done;
    for (size_t i = 0; i < count; ++i) {
        Elf64_Sym *s = &symbols[i];
        if (ELF64_ST_TYPE(s->st_info) != STT_FUNC || !s->st_size || s->st_shndx == SHN_UNDEF ||
            s->st_shndx >= eh->e_shnum || !(sections[s->st_shndx].sh_flags & SHF_EXECINSTR) || s->st_name >= strings->sh_size) continue;
        size_t length = strnlen(names + s->st_name, strings->sh_size - s->st_name);
        if (!length || length >= strings->sh_size - s->st_name) continue;
        if (length > 192) length = 192;
        ++valid; bytes += length + 1;
    }
    if (!valid || valid > SIZE_MAX / sizeof(EsdiagSymbol)) goto done;
    EsdiagSymbol *cache = calloc(valid, sizeof(*cache));
    char *copy = malloc(bytes);
    if (!cache || !copy) { free(cache); free(copy); goto done; }
    uintptr_t base = 0;
    if (eh->e_type == ET_DYN) dl_iterate_phdr(esdiag_base, &base);
    size_t at = 0, used = 0;
    for (size_t i = 0; i < count; ++i) {
        Elf64_Sym *s = &symbols[i];
        if (ELF64_ST_TYPE(s->st_info) != STT_FUNC || !s->st_size || s->st_shndx == SHN_UNDEF ||
            s->st_shndx >= eh->e_shnum || !(sections[s->st_shndx].sh_flags & SHF_EXECINSTR) || s->st_name >= strings->sh_size) continue;
        size_t length = strnlen(names + s->st_name, strings->sh_size - s->st_name);
        if (!length || length >= strings->sh_size - s->st_name) continue;
        if (length > 192) length = 192;
        uintptr_t begin = base + s->st_value;
        if (begin < base || s->st_size > UINTPTR_MAX - begin) continue;
        memcpy(copy + used, names + s->st_name, length); copy[used + length] = 0;
        cache[at++] = (EsdiagSymbol){begin, begin + s->st_size, copy + used, length};
        used += length + 1;
    }
    qsort(cache, at, sizeof(*cache), esdiag_compare);
    esdiag_symbols = cache; esdiag_names = copy; esdiag_symbol_count = at;
    esdiag_symbol_bytes = valid * sizeof(*cache) + bytes;
    result = 1;
done:
    munmap(data, size);
    return result;
}
int eski_diag_symbol(uintptr_t pc, const char **name, size_t *length, uintptr_t *offset) {
    size_t low = 0, high = esdiag_symbol_count;
    while (low < high) { size_t mid = low + (high - low) / 2; if (esdiag_symbols[mid].begin <= pc) low = mid + 1; else high = mid; }
    if (!low) return 0;
    const EsdiagSymbol *s = &esdiag_symbols[low - 1];
    if (pc >= s->end) return 0;
    *name = s->name; *length = s->length; *offset = pc - s->begin;
    return 1;
}
uintptr_t eski_diag_pc(void *context) {
    ucontext_t *uc = context;
#if defined(__x86_64__)
    return (uintptr_t)uc->uc_mcontext.gregs[REG_RIP];
#elif defined(__aarch64__)
    return (uintptr_t)uc->uc_mcontext.pc;
#else
    return 0;
#endif
}
int eski_diag_capture(void *context, uintptr_t *frames, int capacity) {
    if (capacity <= 0) return 0;
    if (capacity > 64) capacity = 64;
    frames[0] = eski_diag_pc(context);
    unw_cursor_t cursor;
    if (unw_init_local2(&cursor, (unw_context_t *)context, UNW_INIT_SIGNAL_FRAME) < 0) return 1;
    int count = 0;
    do {
        unw_word_t ip = 0;
        if (unw_get_reg(&cursor, UNW_REG_IP, &ip) < 0 || !ip) break;
        frames[count++] = (uintptr_t)ip;
    } while (count < capacity && unw_step(&cursor) > 0);
    return count ? count : 1;
}
int eski_diag_capture_current(uintptr_t *frames, int capacity) {
    unw_context_t context;
    unw_cursor_t cursor;
    if (capacity <= 0 || unw_getcontext(&context) < 0 || unw_init_local(&cursor, &context) < 0) return 0;
    if (capacity > 64) capacity = 64;
    int count = 0;
    do {
        unw_word_t ip = 0;
        if (unw_get_reg(&cursor, UNW_REG_IP, &ip) < 0 || !ip) break;
        frames[count++] = (uintptr_t)ip;
    } while (count < capacity && unw_step(&cursor) > 0);
    return count;
}
int eski_diag_runtime_init(void) {
    static int initialized;
    if (initialized) return 1;
    esdiag_scratch = mmap(NULL, 16384, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (esdiag_scratch == MAP_FAILED) esdiag_scratch = NULL;
    if (esdiag_scratch) {
        for (size_t i = 0; i < 16384; ++i) esdiag_scratch[i] = (unsigned char)((i * 131u + 17u) ^ (i >> 7));
        if (mprotect(esdiag_scratch, 16384, PROT_READ)) { munmap(esdiag_scratch, 16384); esdiag_scratch = NULL; }
    }
    unw_set_caching_policy(unw_local_addr_space, UNW_CACHE_NONE);
    uintptr_t warm[64];
    eski_diag_capture_current(warm, 64);
    unw_context_t context;
    unw_cursor_t cursor;
    if (unw_getcontext(&context) >= 0 && unw_init_local2(&cursor, &context, UNW_INIT_SIGNAL_FRAME) >= 0) {
        unw_word_t ip;
        unw_get_reg(&cursor, UNW_REG_IP, &ip);
    }
    initialized = 1;
    return 1;
}
int eski_diag_log_open(int fd) {
    char path[64];
    int count = snprintf(path, sizeof(path), "/proc/self/fd/%d", fd);
    if (count <= 0 || (size_t)count >= sizeof(path)) return -1;
    return open(path, O_WRONLY | O_APPEND | O_NONBLOCK | O_CLOEXEC);
}
int eski_diag_is_timer(void *info) { return ((siginfo_t *)info)->si_code == SI_TIMER; }
int eski_diag_install(void (*handler)(int, void *, void *), int fatal) {
    int signals[] = {SIGALRM, SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE};
    for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); ++i) {
        if (i && !fatal) continue;
        int sig = signals[i];
        struct sigaction action;
        memset(&action, 0, sizeof(action));
        action.sa_sigaction = (void (*)(int, siginfo_t *, void *))handler;
        action.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_RESTART;
        sigemptyset(&action.sa_mask);
        for (size_t j = 0; j < sizeof(signals) / sizeof(signals[0]); ++j) if (fatal || !j) sigaddset(&action.sa_mask, signals[j]);
        if (sigaction(sig, &action, &esdiag_previous[sig])) return errno;
        esdiag_installed[sig] = 1;
    }
    return 0;
}
void eski_diag_default(int sig) {
    struct sigaction action;
    memset(&action, 0, sizeof(action)); action.sa_handler = SIG_DFL; sigemptyset(&action.sa_mask);
    sigaction(sig, &action, NULL);
    sigset_t mask; sigemptyset(&mask); sigaddset(&mask, sig); sigprocmask(SIG_UNBLOCK, &mask, NULL);
    syscall(SYS_tgkill, getpid(), syscall(SYS_gettid), sig);
    syscall(SYS_exit_group, 128 + sig);
}
int eski_diag_timer_create(int tid, int *timer) {
    struct sigevent event;
    memset(&event, 0, sizeof(event)); event.sigev_notify = SIGEV_THREAD_ID; event.sigev_signo = SIGALRM;
    event._sigev_un._tid = tid;
    return syscall(SYS_timer_create, CLOCK_MONOTONIC, &event, timer) < 0 ? errno : 0;
}
int eski_diag_timer_arm(int timer, uint64_t milliseconds) {
    struct itimerspec value;
    memset(&value, 0, sizeof(value)); value.it_value.tv_sec = milliseconds / 1000; value.it_value.tv_nsec = (milliseconds % 1000) * 1000000;
    return syscall(SYS_timer_settime, timer, 0, &value, NULL) < 0 ? errno : 0;
}
void eski_diag_timer_delete(int timer) { syscall(SYS_timer_delete, timer); }
void eski_diag_mask_alarm(int block) {
    sigset_t mask; sigemptyset(&mask); sigaddset(&mask, SIGALRM);
    sigprocmask(block ? SIG_BLOCK : SIG_UNBLOCK, &mask, NULL);
}
int eski_diag_thread_enter(void) {
    if (esdiag_alt) return 0;
    stack_t prior;
    if (sigaltstack(NULL, &prior)) return errno;
    if (!(prior.ss_flags & SS_DISABLE)) return 0;
    size_t page = (size_t)sysconf(_SC_PAGESIZE), size = 65536 + 2 * page;
    void *mapping = mmap(NULL, size, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (mapping == MAP_FAILED) return errno;
    if (mprotect((char *)mapping + page, 65536, PROT_READ | PROT_WRITE)) { int e = errno; munmap(mapping, size); return e; }
    stack_t stack = {.ss_sp = (char *)mapping + page, .ss_size = 65536};
    if (sigaltstack(&stack, NULL)) { int e = errno; munmap(mapping, size); return e; }
    esdiag_alt = mapping; esdiag_alt_size = size;
    atomic_fetch_add_explicit(&esdiag_alt_bytes, size, memory_order_relaxed);
    return 0;
}
void eski_diag_thread_leave(void) {
    if (!esdiag_alt) return;
    stack_t stack = {.ss_flags = SS_DISABLE};
    if (sigaltstack(&stack, NULL)) return;
    void *mapping = esdiag_alt; size_t size = esdiag_alt_size;
    esdiag_alt = NULL; esdiag_alt_size = 0;
    atomic_fetch_sub_explicit(&esdiag_alt_bytes, size, memory_order_relaxed); munmap(mapping, size);
}

int eski_diag_scratch_check(void) {
    if (!esdiag_scratch) return -1;
    for (size_t i = 0; i < 16384; ++i) if (esdiag_scratch[i] != (unsigned char)((i * 131u + 17u) ^ (i >> 7))) return 0;
    return 1;
}
size_t eski_diag_memory(void) { return (esdiag_scratch ? 16384 : 0) + atomic_load_explicit(&esdiag_alt_bytes, memory_order_relaxed); }
void eski_diag_shutdown(void) {
    for (int sig = 1; sig < NSIG; ++sig) if (esdiag_installed[sig]) { sigaction(sig, &esdiag_previous[sig], NULL); esdiag_installed[sig] = 0; }
    eski_diag_thread_leave();

}
void eski_diag_segfault(void) { *(volatile int *)(uintptr_t)0 = 1; }
void eski_diag_abort(void) { syscall(SYS_tgkill, getpid(), syscall(SYS_gettid), SIGABRT); syscall(SYS_exit_group, 134); }
