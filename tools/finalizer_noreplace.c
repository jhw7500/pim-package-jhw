/*
 * finalizer_noreplace: atomically publish one finalized recording pathname.
 *
 * Compiled as a target Ubuntu 20.04 ARM64 executable by the PIM package
 * builder (NOT by the Yocto SDK, which requires a newer target GLIBC).
 *
 * Usage: finalizer_noreplace SOURCE DESTINATION
 * Requires renameat2(RENAME_NOREPLACE) support from the mounted filesystem.
 * No fallback to plain rename/mv/cp: no-replace must be atomic.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/fs.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef SYS_renameat2
#error "Target architecture does not expose SYS_renameat2"
#endif

#ifndef RENAME_NOREPLACE
#define RENAME_NOREPLACE (1U << 0)
#endif

enum {
    FINALIZER_USAGE = 64,
    FINALIZER_INVALID_SOURCE = 65,
    FINALIZER_DEST_EXISTS = 73,
    FINALIZER_CROSS_FS = 74,
    FINALIZER_UNSUPPORTED = 75,
    FINALIZER_OTHER_ERROR = 76
};

int main(int argc, char *argv[]) {
    struct stat source;
    struct stat destination;
    int saved_errno;

    if (argc != 3 || !argv[1] || !argv[2] || !*argv[1] || !*argv[2]
        || argv[1][0] != '/' || argv[2][0] != '/'
        || strcmp(argv[1], argv[2]) == 0) {
        fputs("finalizer_noreplace: expected two distinct absolute paths\n", stderr);
        return FINALIZER_USAGE;
    }

    /*
     * Reject existing source symlinks, directories and empty files. The
     * caller must separately prove that no live recorder write FD remains.
     * This lstat is a safety guard, not a complete adversarial path-race
     * defense; installed directory ownership/permissions are prerequisites.
     */
    if (lstat(argv[1], &source) != 0 || !S_ISREG(source.st_mode)
        || source.st_size <= 0) {
        fputs("finalizer_noreplace: invalid/unfinalized source\n", stderr);
        return FINALIZER_INVALID_SOURCE;
    }

    /*
     * The actual collision guarantee is the RENAME_NOREPLACE syscall below,
     * not this preflight; a competitor can create DEST after this check.
     */
    if (lstat(argv[2], &destination) == 0) {
        fputs("finalizer_noreplace: destination already exists\n", stderr);
        return FINALIZER_DEST_EXISTS;
    }
    if (errno != ENOENT) {
        fputs("finalizer_noreplace: cannot inspect destination\n", stderr);
        return FINALIZER_OTHER_ERROR;
    }

    if (syscall(SYS_renameat2, AT_FDCWD, argv[1],
                AT_FDCWD, argv[2], RENAME_NOREPLACE) == 0) {
        return 0;
    }

    saved_errno = errno;
    fprintf(stderr, "finalizer_noreplace: renameat2 refused: %s\n",
            strerror(saved_errno));

    if (saved_errno == EEXIST) return FINALIZER_DEST_EXISTS;
    if (saved_errno == EXDEV) return FINALIZER_CROSS_FS;
    if (saved_errno == ENOSYS || saved_errno == EINVAL
        || saved_errno == EOPNOTSUPP || saved_errno == ENOTSUP)
        return FINALIZER_UNSUPPORTED;
    return FINALIZER_OTHER_ERROR;
}
