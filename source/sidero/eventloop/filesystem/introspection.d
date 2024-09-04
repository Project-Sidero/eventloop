module sidero.eventloop.filesystem.introspection;
public import sidero.base.path.file;
import sidero.base.text;
import sidero.base.errors;
import sidero.base.system : operatingSystem, OperatingSystem;
import sidero.base.containers.dynamicarray;

/*
void entries(scope void delegate(FilePath) del);
void entriesByBreadthFirst(scope void delegate(FilePath) del);
void entriesByDepthFirst(scope void delegate(FilePath) del);

TODO: meta-data rights, last modified, created ext.
*/

export @safe nothrow @nogc:

///
enum FileType {
    ///
    Error,
    ///
    File,
    ///
    Directory,
    ///
    SymbolicLink,

    /// Posix specific
    Block,
    /// Ditto
    Character,
    /// Ditto
    Socket,
    /// Posix specific Fifo or pipe
    Fifo,

    /// Windows specific
    ReparsePoint,
    /// Ditto
    Junction,
}

///
FileType getType(FilePath path) @trusted {
    if(!path.couldPointToEntry)
        return FileType.Error;

    version(Windows) {
        String_UTF16 path16 = path.toStringUTF16();

        DWORD fileAttributes;
        if((fileAttributes = GetFileAttributesW(path16.ptr)) == INVALID_FILE_ATTRIBUTES)
            return FileType.Error;

        if((fileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
            HANDLE reparsePointHandle = CreateFileW(path16.ptr, 0, FILE_SHARE_READ, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
            if(reparsePointHandle is INVALID_HANDLE_VALUE)
                return FileType.Error;

            scope(exit)
                CloseHandle(reparsePointHandle);

            REPARSE_DATA_BUFFER reparseDataBuffer;
            DWORD dwBytesReturned;
            if(DeviceIoControl(reparsePointHandle, FSCTL_GET_REPARSE_POINT, null, 0, &reparseDataBuffer,
                    REPARSE_DATA_BUFFER.sizeof, &dwBytesReturned, null) == 0)
                return FileType.Error;

            switch(reparseDataBuffer.ReparseTag) {
            case IO_REPARSE_TAG_SYMLINK:
                return FileType.SymbolicLink;

            case IO_REPARSE_TAG_MOUNT_POINT:
                return FileType.Junction;

            default:
                return FileType.ReparsePoint;

            }
        } else if((fileAttributes & SYMBOLIC_LINK_FLAG_DIRECTORY) != 0)
            return FileType.Directory;
        else
            return FileType.File;
    } else version(Posix) {
        String_UTF8 path8 = path.toString();

        stat_t buf;
        if(stat(path8.ptr, &buf) != 0)
            return false;

        switch(S_GETTYPE(buf.st_mode)) {
        case S_IFREG:
            return FileType.File;

        case S_IFDIR:
            return FileType.Directory;

        case S_IFLNK:
            return FileType.SymbolicLink;

        case S_IFIFO:
            return FileType.Fifo;

        case S_IFCHR:
            return FileType.Character;

        case S_IFBLK:
            return FileType.Block;

        default:
            return FileType.Error;
        }
    } else
        static assert(0, "Unimplemented platform");
}

///
bool exists(FilePath path) @trusted {
    return getType(path) != FileType.Error;
}

///
bool isFile(FilePath path) @trusted {
    return getType(path) == FileType.File;
}

///
bool isDirectory(FilePath path) @trusted {
    return getType(path) == FileType.Directory;
}

///
bool isSymbolicLink(FilePath path) @trusted {
    return getType(path) == FileType.SymbolicLink;
}

///
Result!FilePath followSymbolicLink(FilePath path) @trusted {
    if(!isSymbolicLink(path))
        return typeof(return)(PlatformStateNotMatchingArgument("Provided path does not represent a symbolic link"));

    version(Windows) {
        String_UTF16 path16 = path.toStringUTF16();

        HANDLE handle = CreateFileW(path16.ptr, 0, FILE_SHARE_READ, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
        if(handle is INVALID_HANDLE_VALUE)
            return typeof(return)(UnknownPlatformBehaviorException("Failed to follow symbolic link as it doesn't exist"));

        scope(exit)
            CloseHandle(handle);

        DynamicArray!wchar buffer;
        buffer.length = GetFinalPathNameByHandleW(handle, null, 0, VOLUME_NAME_DOS);

        DWORD used = GetFinalPathNameByHandleW(handle, buffer.ptr, cast(DWORD)buffer.length, VOLUME_NAME_DOS);
        if(used == 0)
            return typeof(return)(UnknownPlatformBehaviorException("Failed to follow symbolic link with unknown error"));
        else
            return typeof(return)(FilePath.from(String_UTF16(buffer.ptr[0 .. used])));
    } else version(Posix) {
        import core.sys.posix.fcntl : readlink;

        String_UTF8 path8 = path.toString();

        DynamicArray!char buffer;
        buffer.length = 1024;

        for(;;) {
            auto length = readlink(path8.ptr, buffer.ptr, buffer.length);

            if(length == buffer.length) {
                buffer.length = buffer.length + 1024;
                continue;
            } else if(length >= 0)
                return typeof(return)(FilePath.from(String_UTF8(buffer.ptr[0 .. length])));

            switch(errno) {
            case ENAMETOOLONG:
                return typeof(return)(MalformedInputException("Failed to follow symbolic link as the file name was too long"));

            case EACCES, EINVAL, EIO, ELOOP, ENOENT, ENOTDIR:
                return typeof(return)(UnknownPlatformBehaviorException(
                        "Failed to follow symbolic link as there is something wrong with file system for the given path"));

            default:
                return typeof(return)(UnknownPlatformBehaviorException("Failed to follow symbolic link with unknown error"));
            }
        }
    }
}

///
Result!ulong size(FilePath path) @trusted {
    if(!path.isFile)
        return typeof(return)(PlatformStateNotMatchingArgument("Provided path does not represent a regular file with a size"));

    version(Windows) {
        String_UTF16 path16 = path.toStringUTF16();

        HANDLE handle = CreateFileW(path16.ptr, 0, FILE_SHARE_READ, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
        if(handle is INVALID_HANDLE_VALUE)
            return typeof(return)(UnknownPlatformBehaviorException("Provided path does not represent a file as it doesn't exist"));

        scope(exit)
            CloseHandle(handle);

        LARGE_INTEGER fileSize;
        if(GetFileSizeEx(handle, &fileSize) == 0)
            return typeof(return)(PlatformStateNotMatchingArgument("Provided path does not represent a regular file with a size"));

        return typeof(return)(fileSize.QuadPart);
    } else version(Posix) {
        String_UTF8 path8 = path.toString();

        stat_t buf;
        if(stat(path8.ptr, &buf) != 0 || S_GETTYPE(buf.st_mode) != S_IFREG)
            return typeof(return)(PlatformStateNotMatchingArgument("Provided path does not represent a regular file with a size"));

        return typeof(return)(buf.st_size);
    }
}

private:
import sidero.base.internal.filesystem;

version(Windows) {
    import sidero.eventloop.internal.windows.bindings;
} else version(Posix) {
    import core.sys.posix.unistd;
    import core.sys.posix.stat;
}
