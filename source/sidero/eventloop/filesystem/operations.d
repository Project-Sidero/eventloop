module sidero.eventloop.filesystem.operations;
import sidero.eventloop.filesystem.introspection;
public import sidero.base.path.file;
import sidero.base.text;
import sidero.base.errors;
import sidero.base.system : operatingSystem, OperatingSystem;

export @safe nothrow @nogc:

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
            return ErrorResult(PlatformStateNotMatchingArgument("Source path or target path do not match the file system"));

        case EIO, ELOOP, EACCES, ENOSPC, EROFS:
            return ErrorResult(UnknownPlatformBehaviorException(
                    "Something is wrong with the file system to link between source and target"));

        default:
            return ErrorResult(UnknownPlatformBehaviorException);
        }
    } else
        static assert(0, "Unimplemented platform");
}

/**
Creates a hard link.

Note: the target must exist.

Note: May not support directories (Windows).

Params:
    source = The starting point that will be mapped onto the target.
    target = Where the hard link when transverssed goes to.
*/
ErrorResult createHardLink(FilePath source, FilePath target) @trusted {
    if(!source.couldPointToEntry)
        return ErrorResult(MalformedInputException("Source file path must point to a possible file system location"));
    else if(!target.couldPointToEntry)
        return ErrorResult(MalformedInputException("Source file path must point to a possible file system location"));

    version(Windows) {
        String_UTF16 source16 = source.toStringUTF16(), target16 = target.toStringUTF16();

        if(CreateHardLinkW(source16.ptr, target16.ptr, null) != 0)
            return ErrorResult.init;

        //auto error = GetLastError();

        return ErrorResult(UnknownPlatformBehaviorException);
    } else version(Posix) {
        import core.stdc.errno;

        String_UTF8 source8 = source.toString(), target8 = target.toString();

        if(link(target8.ptr, source8.ptr) == 0)
            return ErrorResult.init;

        switch(errno) {
        case ENAMETOOLONG, ENOENT, ENOTDIR, EEXIST:
            return ErrorResult(PlatformStateNotMatchingArgument("Source path or target path do not match the file system"));

        case EIO, ELOOP, EACCES, ENOSPC, EROFS:
            return ErrorResult(UnknownPlatformBehaviorException(
                    "Something is wrong with the file system to link between source and target"));

        default:
            return ErrorResult(UnknownPlatformBehaviorException);
        }
    } else
        static assert(0, "Unimplemented platform");
}

/// Will delete symbolic links (junctions and reparse points too), and is recursive for directories.
ErrorResult remove(FilePath source) @trusted {
    if(!source.couldPointToEntry)
        return ErrorResult(MalformedInputException("Source file does not point to a file or directory"));

    version(Windows) {
        bool isSourceDirectory;

        String_UTF16 source16 = source.toStringUTF16();

        // the prefix \\? are not supported!
        if(source16.startsWith("\\\\?\\"))
            source16 = source16[4 .. $];

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

            switch(nftw(path8.ptr, &sidero_on_nftw_remove, 64, FTW_DEPTH | FTW_PHYS)) {
            case 0:
                return ErrorResult.init;

            default:
                return ErrorResult(UnknownPlatformBehaviorException);
            }
        }
    } else
        static assert(0, "Unimplemented platform");
}

/**
Creates a directory recursively.

Note: the current user should have full permissions, other accounts/groups are not platform dependent.

Params:
    path = The path to create all directories for.
*/
ErrorResult mkdir(FilePath path) @trusted {
    import sidero.base.algorithm : countUntil;

    if(!path.couldPointToEntry)
        return ErrorResult(MalformedInputException("File could not point to a directory"));

    version(Windows) {
        String_UTF16 path16 = path.toStringUTF16();

        if(SHCreateDirectoryExW(null, path16.ptr, null) == ERROR_SUCCESS)
            return ErrorResult.init;

        return ErrorResult(UnknownPlatformBehaviorException("Could not create a directory recursively"));
    } else version(Posix) {
        String_UTF8 path8 = path.toString();
        char[] literal = cast(char[])path8.unsafeGetLiteral;

        size_t lastSplit;
        if(literal[0] == '/')
            lastSplit = 1;

        while(lastSplit < literal.length) {
            // /path/ after
            char[] toFindIn = literal[lastSplit .. $];

            ptrdiff_t nextSplit = toFindIn.countUntil('/');
            if(nextSplit >= 0) {
                lastSplit += nextSplit;
                toFindIn[nextSplit] = 0;
            } else
                lastSplit = size_t.max;

            if(mkdir(toFindIn.ptr, S_IRWXU) != 0) {
                if(errno != EEXIST)
                    return ErrorResult(UnknownPlatformBehaviorException("Could not create a directory recursively"));
            }

            if(nextSplit >= 0)
                toFindIn[nextSplit] = '/';
        }

        return ErrorResult.init;
    } else
        static assert(0, "Unimplemented platform");
}

/**
Copy a directory or file, and may do so recursively.

Note: On Windows source and target must be able to be absolute if they are not already.

Params:
    source = The path to copy from
    target = The directory to put it in
    recursive = If the source is a directory, will the contents be copied recursively?
*/
ErrorResult copy(FilePath source, FilePath target, bool recursive = false) @trusted {
    if(!source.couldPointToEntry)
        return ErrorResult(MalformedInputException("Source path could not point to something that can be copied"));
    else if(!target.couldPointToEntry)
        return ErrorResult(MalformedInputException("Target path could not point to something that can be copied"));

    if(!source.isAbsolute) {
        Result!FilePath tempPath = source.asAbsolute;
        if(tempPath)
            source = tempPath;
        else
            return ErrorResult(MalformedInputException("Source path must be able to be made absolute"));
    }

    if(!target.isAbsolute) {
        Result!FilePath tempPath = target.asAbsolute;
        if(tempPath)
            target = tempPath;
        else
            return ErrorResult(MalformedInputException("Target path must be able to be made absolute"));
    }

    version(Windows) {
        String_UTF16 source16 = source.toStringUTF16(), target16 = target.toStringUTF16();

        // the prefix \\? are not supported!
        if(source16.startsWith("\\\\?\\"))
            source16 = source16[4 .. $];
        if(target16.startsWith("\\\\?\\"))
            target16 = target16[4 .. $];

        if(!source16.endsWith("\0\0\0"))
            source16 = (source16 ~ "\0\0\0"w).asReadOnly;
        if(!target16.endsWith("\0\0\0"))
            target16 = (target16 ~ "\0\0\0"w).asReadOnly;

        SHFILEOPSTRUCTW op;
        op.wFunc = FO_COPY;
        op.fFlags = FOF_SILENT | FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_NOCONFIRMMKDIR;
        op.pFrom = source16.ptr;
        op.pTo = target16.ptr;

        if(!recursive)
            op.fFlags |= FOF_NORECURSION;

        if(SHFileOperationW(&op) != 0)
            return ErrorResult(UnknownPlatformBehaviorException);

        return ErrorResult.init;
    } else {
        // We can do a default implementation using the libc
        // All we need on our end is entriesInDirectoryBeforeRecursively/entriesInDirectory!

        void copyFile(FilePath from, FilePath to) {
            import core.stdc.stdio : fopen, fclose, fwrite, fread, FILE;

            String_UTF8 from8 = from.toString(), to8 = to.toString();

            FILE* fromFD = fopen(from8.ptr, "r");
            if(fromFD is null)
                return;

            FILE* toFD = fopen(to8.ptr, "w");
            if(toFD is null) {
                fclose(fromFD);
                return;
            }

            scope(exit) {
                fclose(fromFD);
                fclose(toFD);
            }

            // 8kb should be small enough to fit on stack, but also cover most files
            void[8 * 1024] buffer;

            for(;;) {
                const read = fread(buffer.ptr, 1, buffer.length, fromFD);

                if(read == 0)
                    break;

                fwrite(buffer.ptr, 1, read, toFD);
            }
        }

        FileType sourceFileType = source.getType;

        if(sourceFileType == FileType.Directory) {
            if(recursive) {
                entriesInDirectoryBeforeRecursively(source, (FilePath originalFilePath, FileType fileType) {
                    Result!FilePath destination = originalFilePath.asRelative(source);

                    if(destination) {
                        if(destination.makeAbsolute(target)) {
                            if(fileType == FileType.Directory)
                                mkdir(destination);
                            else if(fileType == FileType.File)
                                copyFile(originalFilePath, destination);
                        }
                    }

                    return true;
                });
            } else {
                entriesInDirectory(source, (FilePath originalFilePath, FileType fileType) {
                    if(fileType == FileType.File) {
                        Result!FilePath destination = originalFilePath.asRelative(source);

                        if(destination) {
                            if(destination.makeAbsolute(target)) {
                                copyFile(originalFilePath, destination);
                            }
                        }
                    }

                    return true;
                });
            }
        } else if(sourceFileType == FileType.File) {
            if(target.isDirectory) {
                String_UTF8 fileName = source.lastComponent.assumeOkay;
                target = target.dup ~ fileName;
            }

            copyFile(source, target);
        }

        return ErrorResult.init;
    }
}

/**
Move a directory or file.

Note: It the source and target are on different file systems it may fail.

Params:
    source = What to rename
    target = What to rename it to
*/
ErrorResult move(FilePath source, FilePath target) @trusted {
    import core.stdc.stdio : rename;

    if(!source.couldPointToEntry)
        return ErrorResult(MalformedInputException("Source path could not point to something that can be moved"));
    else if(!target.couldPointToEntry)
        return ErrorResult(MalformedInputException("Target path could not point to something that can be moved"));

    if(!source.isAbsolute) {
        Result!FilePath tempPath = source.asAbsolute;
        if(tempPath)
            source = tempPath;
        else
            return ErrorResult(MalformedInputException("Source path must be able to be made absolute"));
    }

    if(!target.isAbsolute) {
        Result!FilePath tempPath = target.asAbsolute;
        if(tempPath)
            target = tempPath;
        else
            return ErrorResult(MalformedInputException("Target path must be able to be made absolute"));
    }

    String_UTF8 source8 = source.toString(), target8 = target.toString();

    if(rename(source8.ptr, target8.ptr) != 0)
        return ErrorResult(UnknownPlatformBehaviorException);
    return ErrorResult.init;
}

private:
import sidero.base.internal.filesystem;

version(Windows) {
    import sidero.eventloop.internal.windows.bindings;
} else version(Posix) {
    import core.sys.posix.unistd;
    import core.sys.posix.stat;
}
