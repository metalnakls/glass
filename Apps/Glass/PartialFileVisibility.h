#pragma once

#include <fcntl.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>

// Finder visibility only: Transmission retains its paths, sparse bytes and piece
// bookkeeping. The marker lets us restore only flags Glass changed, including
// after a restart or a .part -> completed-file rename.
inline bool GlassUpdatePartialFileVisibility(char const* path, bool wanted, bool partial)
{
    int const fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) { return false; }
    struct Close { int fd; ~Close() { close(fd); } } closeFile{fd};
    struct stat info{};
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode)) { return false; }
    constexpr char marker[] = "tsmc.glass.hidden-partial";
    char value = 0;
    bool const owned = fgetxattr(fd, marker, &value, 1, 0, 0) == 1 && value == '1';
    bool const hidden = (info.st_flags & UF_HIDDEN) != 0;
    if (!wanted && partial)
    {
        if (hidden) { return true; }
        value = '1';
        if (fsetxattr(fd, marker, &value, 1, 0, 0) != 0) { return false; }
        if (fchflags(fd, info.st_flags | UF_HIDDEN) == 0) { return true; }
        fremovexattr(fd, marker, 0);
        return false;
    }
    if (!owned) { return true; }
    if (hidden && fchflags(fd, info.st_flags & ~UF_HIDDEN) != 0) { return false; }
    return fremovexattr(fd, marker, 0) == 0;
}
