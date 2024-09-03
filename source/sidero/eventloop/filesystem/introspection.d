module sidero.eventloop.filesystem.introspection;
public import sidero.base.path.file;
import sidero.base.text;
import sidero.base.errors;
import sidero.base.system : operatingSystem, OperatingSystem;

/*
void entries(scope void delegate(FilePath) del);
void entriesByBreadthFirst(scope void delegate(FilePath) del);
void entriesByDepthFirst(scope void delegate(FilePath) del);
ulong fileSize(FilePath)
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
            HANDLE reparsePointHandle = CreateFileW(path16.ptr, 0, FILE_SHARE_READ | FILE_SHARE_WRITE, null,
                    OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
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

private:
import sidero.base.internal.filesystem;

version(Windows) {
    import sidero.eventloop.internal.windows.bindings;
} else version(Posix) {
    import core.sys.posix.unistd;
    import core.sys.posix.stat;
}
