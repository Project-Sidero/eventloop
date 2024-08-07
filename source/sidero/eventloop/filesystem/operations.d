module sidero.eventloop.filesystem.operations;
public import sidero.base.path.file;
import sidero.base.text;
import sidero.base.errors;
import sidero.base.system : operatingSystem, OperatingSystem;

export @safe nothrow @nogc:

/*

move(FilePath from, FilePath to)
copy(FilePath from, FilePath to)
mkdir(FilePath path)
void entries(scope void delegate(FilePath) del);
void entriesByBreadthFirst(scope void delegate(FilePath) del);
void entriesByDepthFirst(scope void delegate(FilePath) del);
*/

///
enum FileType {
    Error,
    File,
    Directory,
    SymbolicLink,

    /// Posix specific
    Block,
    /// Ditto
    Character,
    /// Ditto
    Fifo,
    /// Ditto
    Socket
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

        if((fileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0)
            return FileType.SymbolicLink;
        else if((fileAttributes & SYMBOLIC_LINK_FLAG_DIRECTORY) != 0)
            return FileType.Directory;
        else
            return FileType.File;
    } else version(Posix) {
        String_UTF8 path8 = path.toString();

        stat buf;
        if(stat(path8.ptr, &buf) != 0)
            return false;

        switch(S_GETTYPE(buf.st_mode)) {
        case S_IFREG:
            return FileType.File;

        case S_IFDIR:
            return FileType.Directory;

        case S_IFLNK:
            return FileType.SymbolicLink;

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

/**
Creates a symbolic link.

Note: On Windows this may require administrative permissions.

Note: The source and target need not exist.

Params:
    source = The starting point that will be mapped onto the target.
    target = Where the symbolic link when transverssed goes to.
    targetWillBeDirectory = A hint needed on Windows for when the target does not exist.
*/
ErrorResult createSymbolicLink(FilePath source, FilePath target, bool targetWillBeDirectory = false) @trusted {
    if(!source.couldPointToEntry)
        return ErrorResult(MalformedInputException("Source file path must point to a possible file system location"));
    else if(!target.couldPointToEntry)
        return ErrorResult(MalformedInputException("Source file path must point to a possible file system location"));

    version(Windows) {
        String_UTF16 source16 = source.toStringUTF16(), target16 = target.toStringUTF16();

        DWORD fileAttributes;
        if((fileAttributes = GetFileAttributesW(target16.ptr)) != INVALID_FILE_ATTRIBUTES)
            targetWillBeDirectory = (fileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;

        DWORD flags = targetWillBeDirectory ? SYMBOLIC_LINK_FLAG_DIRECTORY : 0;

        if(operatingSystem().major >= 10)
            flags |= SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE;

        if(CreateSymbolicLinkW(source16.ptr, target16.ptr, flags) != 0)
            return ErrorResult.init;

        //auto error = GetLastError();

        return ErrorResult(UnknownPlatformBehaviorException);
    } else version(Posix) {
        import core.stdc.errno;

        String_UTF8 source8 = source.toString(), target8 = target.toString();

        if(symlink(source8.ptr, target8.ptr) == 0)
            return ErrorResult.init;

        switch(errno) {
        case ENAMETOOLONG, ENOENT, ENOTDIR, EEXIST:
            return ErrorResult(MalformedInputException("Source path or target path do not match the file system"));

        case EIO, ELOOP, EACCES, ENOSPC, EROFS:
            return ErrorResult(UnknownPlatformBehaviorException(
                    "Something is wrong with the file system to link between source and target"));

        default:
            return ErrorResult(UnknownPlatformBehaviorException);
        }
    } else
        static assert(0, "Unimplemented platform");
}

/// Will delete symbolic links, and is recursive for directories.
ErrorResult remove(FilePath source) @trusted {
    if(!source.couldPointToEntry)
        return ErrorResult(MalformedInputException("Source file does not point to a file or directory"));

    version(Windows) {
        bool isSourceDirectory;

        String_UTF16 source16 = source.toStringUTF16();

        DWORD fileAttributes;
        if((fileAttributes = GetFileAttributesW(source16.ptr)) != INVALID_FILE_ATTRIBUTES)
            isSourceDirectory = (fileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0;

        if(isSourceDirectory) {
            if(!source16.endsWith("\0\0\0"))
                source16 = (source16 ~ "\0\0\0"w).asReadOnly;

            SHFILEOPSTRUCTW op;
            op.wFunc = FO_DELETE;
            op.fFlags = FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_SILENT;
            op.pFrom = source16.ptr;

            if(SHFileOperationW(&op) != 0)
                return ErrorResult(UnknownPlatformBehaviorException);
        } else {
            if(DeleteFileW(source16.ptr) == 0)
                return ErrorResult(UnknownPlatformBehaviorException);
        }

        return ErrorResult.init;
    } else version(OSX) {
        String_UTF8 path8 = path.toString();

        stat buf;
        if(stat(path8.ptr, &buf) != 0)
            return ErrorResult(MalformedInputException("Source file does not point to a file or directory"));

        if(!S_ISDIR(buf.st_mode)) {
            if(remove(path8.ptr) != 0)
                return ErrorResult(UnknownPlatformBehaviorException);

            return ErrorResult.init;
        }

        {
            // Does not cross mount points by default, see REMOVEFILE_CROSS_MOUNT

            removefile_state_t s = removefile_state_alloc();
            int err = removefile(path8.ptr, s, REMOVEFILE_RECURSIVE);
            removefile_state_free(s);

            if(err != 0)
                return ErrorResult(UnknownPlatformBehaviorException);

            return ErrorResult.init;
        }
    } else version(Posix) {
        String_UTF8 path8 = path.toString();

        stat buf;
        if(stat(path8.ptr, &buf) != 0)
            return ErrorResult(MalformedInputException("Source file does not point to a file or directory"));

        if(!S_ISDIR(buf.st_mode)) {
            if(remove(path8.ptr) != 0)
                return ErrorResult(UnknownPlatformBehaviorException);

            return ErrorResult.init;
        }

        {
            static extern (C) int sidero_on_nftw_remove(const(char)* fpath, const(stat)*, int, FTW*) {
                remove(fpath);
                return 0;
            }

            switch (nftw(path8.ptr, &sidero_on_nftw_remove, 64, FTW_DEPTH | FTW_PHYS)) {
                case 0:
                    return ErrorResult.init;

                    default:
                    return ErrorResult(UnknownPlatformBehaviorException);
            }
        }
    } else
        static assert(0, "Unimplemented platform");
}

private:
import sidero.base.internal.filesystem;

version(Windows) {
    import sidero.eventloop.internal.windows.bindings;
} else version(Posix) {
    import core.sys.posix.unistd;
    import core.sys.posix.stat;
}
