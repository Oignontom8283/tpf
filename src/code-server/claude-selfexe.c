/* claude-selfexe.c — LD_PRELOAD helper: makes /proc/self/exe point to $CT_REAL_EXE.
 * Needed when a program is started as "ld.so program" (the only way to run a
 * glibc program on Android): /proc/self/exe is then the loader, and programs
 * that read themselves (Bun standalone executables) cannot find their
 * embedded code. No headers are used, so it builds without a glibc sysroot. */
#ifndef SYS_READLINKAT
#define SYS_READLINKAT 78   /* aarch64 */
#endif
#ifndef SYS_OPENAT
#define SYS_OPENAT 56       /* aarch64 */
#endif
#define AT_FDCWD_ (-100)

extern long syscall(long number, ...);
extern char *getenv(const char *name);

static int is_self(const char *p)
{
    static const char s[] = "/proc/self/exe";
    int i = 0;
    if (!p) return 0;
    while (s[i] && p[i] == s[i]) i++;
    return s[i] == 0 && p[i] == 0;
}
static const char *real(void) { return getenv("CT_REAL_EXE"); }

long readlinkat(int dirfd, const char *path, char *buf, unsigned long size)
{
    const char *r = real();
    if (r && is_self(path)) {
        unsigned long n = 0;
        while (r[n] && n < size) { buf[n] = r[n]; n++; }
        return (long)n;
    }
    return syscall(SYS_READLINKAT, (long)dirfd, (long)path, (long)buf, (long)size);
}
long readlink(const char *path, char *buf, unsigned long size) { return readlinkat(AT_FDCWD_, path, buf, size); }

int openat(int dirfd, const char *path, int flags, ...)
{
    const char *r = real();
    __builtin_va_list ap; unsigned int mode;
    __builtin_va_start(ap, flags); mode = __builtin_va_arg(ap, unsigned int); __builtin_va_end(ap);
    if (r && is_self(path)) path = r;
    return (int)syscall(SYS_OPENAT, (long)dirfd, (long)path, (long)flags, (long)mode);
}
int open(const char *path, int flags, ...)
{
    __builtin_va_list ap; unsigned int mode;
    __builtin_va_start(ap, flags); mode = __builtin_va_arg(ap, unsigned int); __builtin_va_end(ap);
    return openat(AT_FDCWD_, path, flags, mode);
}
int open64(const char *path, int flags, ...)
{
    __builtin_va_list ap; unsigned int mode;
    __builtin_va_start(ap, flags); mode = __builtin_va_arg(ap, unsigned int); __builtin_va_end(ap);
    return openat(AT_FDCWD_, path, flags, mode);
}
int openat64(int dirfd, const char *path, int flags, ...)
{
    __builtin_va_list ap; unsigned int mode;
    __builtin_va_start(ap, flags); mode = __builtin_va_arg(ap, unsigned int); __builtin_va_end(ap);
    return openat(dirfd, path, flags, mode);
}
