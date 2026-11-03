#include "PartialFileVisibility.h"
#include <cassert>
#include <cstdlib>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>
#include <cstdio>
#include <cstring>

int main() {
    char path[] = "/tmp/GlassPartialVisibility-XXXXXX";
    int fd = mkstemp(path);
    assert(fd >= 0);
    // Same shape as Sirens track 08: just the tail in a sparse 30.7 MB file.
    char const bytes[] = "boundary data";
    assert(pwrite(fd, bytes, sizeof(bytes), 30675189 - sizeof(bytes)) == sizeof(bytes));
    auto hidden = [&] { struct stat st{}; assert(fstat(fd, &st) == 0); return (st.st_flags & UF_HIDDEN) != 0; };
    assert(GlassUpdatePartialFileVisibility(path, false, true));
    assert(hidden());
    assert(GlassUpdatePartialFileVisibility(path, false, true));
    assert(hidden());
    char actual[sizeof(bytes)];
    assert(pread(fd, actual, sizeof(actual), 30675189 - sizeof(bytes)) == sizeof(actual));
    assert(memcmp(actual, bytes, sizeof(bytes)) == 0);
    assert(GlassUpdatePartialFileVisibility(path, true, true));
    assert(!hidden());
    // Re-selection and completion must remove only the flag Glass owns.
    assert(GlassUpdatePartialFileVisibility(path, false, true));
    assert(GlassUpdatePartialFileVisibility(path, true, false));
    assert(!hidden());
    assert(GlassUpdatePartialFileVisibility(path, false, false));
    assert(!hidden());
    // User-hidden files stay hidden when selected.
    assert(fchflags(fd, UF_HIDDEN | UF_NODUMP) == 0);
    assert(GlassUpdatePartialFileVisibility(path, false, true));
    assert(GlassUpdatePartialFileVisibility(path, true, true));
    assert(hidden());
    struct stat st{}; assert(fstat(fd, &st) == 0); assert(st.st_flags & UF_NODUMP);
    char linkPath[256]; snprintf(linkPath, sizeof(linkPath), "%s-link", path);
    assert(symlink(path, linkPath) == 0);
    assert(!GlassUpdatePartialFileVisibility(linkPath, false, true));
    assert(hidden());
    unlink(linkPath); close(fd); unlink(path);
    assert(!GlassUpdatePartialFileVisibility(path, false, true));
    puts("Partial visibility: sparse bytes, selection, completion, user flags, symlinks and missing files passed");
}
