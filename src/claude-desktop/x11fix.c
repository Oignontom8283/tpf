/* x11fix.c — LD_PRELOAD helper for glibc programs on Termux (aarch64).
 * 1. Debian's X11 libraries connect to /tmp/.X11-unix/X<N>; on Android that
 *    folder does not exist (Termux:X11 puts its socket in
 *    $PREFIX/tmp/.X11-unix). connect() is rewritten to fix that path.
 * 2. Android's seccomp filter KILLS (SIGSYS) a process that calls a syscall
 *    it does not know, instead of returning ENOSYS. Recent Chromium calls
 *    openat2 (437), clone3 (435), faccessat2 (439)... which the 4.19 kernel
 *    does not have: syscall() answers ENOSYS for every number >= 424, so the
 *    program takes its normal fallback path.
 * No headers are used so it can be built without a glibc sysroot. */
#ifndef TERMUX_TMP
#error "TERMUX_TMP must be defined"
#endif
#ifndef SYS_CONNECT
#define SYS_CONNECT 203   /* aarch64 */
#endif
#define FIRST_UNSUPPORTED_SYSCALL 424
#define X_ENOSYS 38

/* The library is also preloaded into the Bionic `nohup` that starts the app,
 * so errno is looked up through weak symbols: glibc has __errno_location,
 * Bionic has __errno. */
extern int *__errno_location(void) __attribute__((weak));
extern int *__errno(void) __attribute__((weak));

static void set_errno(int e)
{
    if (__errno_location) *__errno_location() = e;
    else if (__errno) *__errno() = e;
}

static long raw_syscall(long n, long a, long b, long c, long d, long e, long f)
{
    register long x8 __asm__("x8") = n;
    register long x0 __asm__("x0") = a;
    register long x1 __asm__("x1") = b;
    register long x2 __asm__("x2") = c;
    register long x3 __asm__("x3") = d;
    register long x4 __asm__("x4") = e;
    register long x5 __asm__("x5") = f;
    __asm__ volatile("svc 0" : "+r"(x0)
                     : "r"(x8), "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5)
                     : "memory", "cc");
    return x0;
}

/* Variadic in the C library, but AArch64 passes variadic integers in the
 * same registers as normal arguments, so this signature is compatible. */
long syscall(long n, long a, long b, long c, long d, long e, long f)
{
    long r;
    if (n >= FIRST_UNSUPPORTED_SYSCALL) {
        set_errno(X_ENOSYS);
        return -1;
    }
    r = raw_syscall(n, a, b, c, d, e, f);
    if (r < 0 && r > -4096) {
        set_errno((int)-r);
        return -1;
    }
    return r;
}

struct x_sockaddr_un { unsigned short family; char path[108]; };

int connect(int fd, const void *addr, unsigned int len)
{
    static const char from[] = "/tmp/.X11-unix/";
    static const char base[] = TERMUX_TMP "/.X11-unix/";
    const struct x_sockaddr_un *in = (const struct x_sockaddr_un *)addr;

    if (addr && len > 3 && in->family == 1 && in->path[0] == '/') {
        unsigned int i = 0, j = 0, k;
        while (from[i] && in->path[i] == from[i]) i++;
        if (from[i] == 0) {
            struct x_sockaddr_un out;
            out.family = 1;
            for (j = 0; base[j] && j < 100; j++) out.path[j] = base[j];
            for (k = i; in->path[k] && j < 107; k++, j++) out.path[j] = in->path[k];
            out.path[j] = 0;
            return (int)syscall(SYS_CONNECT, (long)fd, (long)&out, (long)(2 + j + 1), 0, 0, 0);
        }
    }
    return (int)syscall(SYS_CONNECT, (long)fd, (long)addr, (long)len, 0, 0, 0);
}
