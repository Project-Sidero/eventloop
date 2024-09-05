module sidero.eventloop.filesystem.introspection;
public import sidero.base.path.file;
import sidero.base.text;
import sidero.base.errors;
import sidero.base.system : operatingSystem, OperatingSystem;
import sidero.base.containers.dynamicarray;
import sidero.base.datetime;

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
bool exists(FilePath path) {
    return getType(path) != FileType.Error;
}

///
bool isFile(FilePath path) {
    return getType(path) == FileType.File;
}

///
bool isDirectory(FilePath path) {
    return getType(path) == FileType.Directory;
}

///
bool isSymbolicLink(FilePath path) {
    return getType(path) == FileType.SymbolicLink;
}

///
bool isFileDirectory(FilePath path) {
    FileType type = getType(path);
    return type == FileType.File || type == FileType.Directory;
}

///
bool isFileDirectorySymbolicLink(FilePath path) {
    FileType type = getType(path);
    return type == FileType.File || type == FileType.Directory || type == FileType.SymbolicLink;
}

/// May only follow a single symbolic link
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

/**
    For each entry in a directory that is either a file, directory or a symbolic link, call callback.

    Does not go into child directories.

    Params:
        path = The directory to look in
        del = The callback delegate
*/
void entriesInDirectory(FilePath path, scope bool delegate(FilePath, FileType) @safe nothrow @nogc del) {
    entriesImpl!0(path, del, false);
}

/**
    For each entry in a directory that is either a file, directory or a symbolic link, call callback.

    Will call callback on directory before recursively going into the contents of the directory (breadth-first).

    Params:
        path = The directory to look in
        del = The callback delegate
        allowedToFollowIntoSymbolicLink = Will symbolic links be followed to determine continuation
*/
void entriesInDirectoryBeforeRecursively(FilePath path, scope bool delegate(FilePath, FileType) @safe nothrow @nogc del,
        bool allowedToFollowIntoSymbolicLink = false) {
    entriesImpl!1(path, del, allowedToFollowIntoSymbolicLink);
}

/**
    For each entry in a directory that is either a file, directory or a symbolic link, call callback.

    Will call callback on directory after recursively going into the contents of the directory (depth-first).

    Params:
        path = The directory to look in
        del = The callback delegate
        allowedToFollowIntoSymbolicLink = Will symbolic links be followed to determine continuation
*/
void entriesInDirectoryAfterRecursively(FilePath path, scope bool delegate(FilePath, FileType) @safe nothrow @nogc del,
        bool allowedToFollowIntoSymbolicLink = false) {
    entriesImpl!2(path, del, allowedToFollowIntoSymbolicLink);
}

///
struct FileMetaData {
    ///
    FileType fileType;

    ///
    GDateTime created;
    ///
    GDateTime lastModified;
    ///
    GDateTime lastAccessed;

    ///
    ulong size;

export @safe nothrow @nogc:

    this(return scope ref FileMetaData other) scope {
        this.tupleof = other.tupleof;
    }

    void opAssign(return scope FileMetaData other) scope {
        this.__ctor(other);
    }
}

///
Result!FileMetaData getMetaData(FilePath path) @trusted {
    if(!path.couldPointToEntry)
        return typeof(return)(MalformedInputException(
                "A path must be able to represent a file/directory in the file system to get metadata on it"));

    FileMetaData ret;
    ret.fileType = path.getType;

    if(ret.fileType == FileType.Error)
        return typeof(return)(PlatformStateNotMatchingArgument("A path provided must exist"));

    bool needTimeZoneAdjustment;

    version(Windows) {
        String_UTF16 path16 = path.toStringUTF16();

        WIN32_FILE_ATTRIBUTE_DATA attributeData;
        if(GetFileAttributesExW(path16.ptr, GET_FILEEX_INFO_LEVELS.GetFileExInfoStandard, &attributeData) == 0)
            return typeof(return)(UnknownPlatformBehaviorException("Could not get file/directory metadata"));

        {
            LARGE_INTEGER size;
            size.HighPart = attributeData.nFileSizeHigh;
            size.LowPart = attributeData.nFileSizeLow;
            ret.size = size.QuadPart;
        }

        {
            SYSTEMTIME create, lastModified, lastAccessed;

            FileTimeToSystemTime(&attributeData.ftCreationTime, &create);
            FileTimeToSystemTime(&attributeData.ftLastWriteTime, &lastModified);
            FileTimeToSystemTime(&attributeData.ftLastAccessTime, &lastAccessed);

            ret.created = GDateTime(GregorianDate(create.wYear, cast(ubyte)create.wMonth, cast(ubyte)create.wDay),
                    TimeOfDay(cast(ubyte)create.wHour, cast(ubyte)create.wMinute, cast(ubyte)create.wSecond, create.wMilliseconds * 1000));
            ret.lastModified = GDateTime(GregorianDate(lastModified.wYear, cast(ubyte)lastModified.wMonth,
                    cast(ubyte)lastModified.wDay), TimeOfDay(cast(ubyte)lastModified.wHour,
                    cast(ubyte)lastModified.wMinute, cast(ubyte)lastModified.wSecond, lastModified.wMilliseconds * 1000));
            ret.lastAccessed = GDateTime(GregorianDate(lastAccessed.wYear, cast(ubyte)lastAccessed.wMonth,
                    cast(ubyte)lastAccessed.wDay), TimeOfDay(cast(ubyte)lastAccessed.wHour,
                    cast(ubyte)lastAccessed.wMinute, cast(ubyte)lastAccessed.wSecond, lastAccessed.wMilliseconds * 1000));

            needTimeZoneAdjustment = true;
        }
    } else version(Posix) {
        String_UTF8 path8 = path.toString();

        stat_t buf;
        if(stat(path8.ptr, &buf) != 0)
            return false;

        if(ret.fileType == FileType.File)
            ret.size = stat.st_size;

        {
            ret.created = GDateTime.fromUnixTime(buf.st_ctim.tv_sec);
            ret.created.advanceNanoSeconds(buf.st_ctim.tv_nsec);

            ret.lastModified = GDateTime.fromUnixTime(buf.st_mtim.tv_sec);
            ret.lastModified.advanceNanoSeconds(buf.st_mtim.tv_nsec);

            ret.lastAccessed = GDateTime.fromUnixTime(buf.st_atim.tv_sec);
            ret.lastAccessed.advanceNanoSeconds(buf.st_atim.tv_nsec);
        }

        needTimeZoneAdjustment = true;
    }

    if(needTimeZoneAdjustment) {
        auto timeZone = TimeZone.local;

        if(timeZone) {
            ret.created = ret.created.asTimeZone(timeZone.get);
            ret.lastModified = ret.lastModified.asTimeZone(timeZone.get);
            ret.lastAccessed = ret.lastAccessed.asTimeZone(timeZone.get);
        }
    }

    return typeof(return)(ret);
}

private:
import sidero.base.internal.filesystem;

version(Windows) {
    import sidero.eventloop.internal.windows.bindings;
} else version(Posix) {
    import core.sys.posix.unistd;
    import core.sys.posix.stat;
}

void entriesImpl(int Mode)(FilePath path, scope bool delegate(FilePath, FileType) @safe nothrow @nogc del,
        bool allowedToFollowIntoSymbolicLink = false) @trusted {
    if(!path.couldPointToEntry || del is null)
        return;

    version(Windows) {
        import core.stdc.wchar_ : wcslen;

        FilePath seenFilePathBuffer = path.dup;
        DynamicArray!wchar directoryBuffer;
        size_t usedOfDirectoryBuffer;

        bool handleDirectory(const(wchar)[] directoryPath) @trusted nothrow @nogc {
            const originalUsed = usedOfDirectoryBuffer;

            if(directoryPath.length > 0) {
                const originalLength = directoryBuffer.length;
                const neededLength = directoryBuffer.length + directoryPath.length + 3; // \*Z
                if(originalLength < neededLength)
                    directoryBuffer.length = neededLength - originalLength;

                wchar[] into = directoryBuffer.unsafeGetLiteral;

                foreach(v; directoryPath) {
                    into[usedOfDirectoryBuffer++] = v;
                }

                if(directoryPath[$ - 1] != '\\')
                    into[usedOfDirectoryBuffer++] = '\\';

                into[usedOfDirectoryBuffer++] = '*';
                into[usedOfDirectoryBuffer++] = '\0';
            }

            scope(exit)
                usedOfDirectoryBuffer = originalUsed;

            WIN32_FIND_DATAW entry;
            HANDLE iterator = FindFirstFileExW(directoryBuffer.ptr, FINDEX_INFO_LEVELS.FindExInfoBasic, &entry,
                    FINDEX_SEARCH_OPS.FindExSearchNameMatch, null, FIND_FIRST_EX_LARGE_FETCH);

            if(iterator !is INVALID_HANDLE_VALUE) {
                scope(exit) {
                    FindClose(iterator);
                }

                do {
                    // minor optimization check point, to prevent needing memory allocation
                    if((entry.dwFileAttributes & FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_NORMAL | FILE_ATTRIBUTE_DIRECTORY |
                            FILE_ATTRIBUTE_REPARSE_POINT) > 0) {
                        const nameLength = wcslen(entry.cFileName.ptr);

                        (seenFilePathBuffer ~= String_UTF8(entry.cFileName.ptr[0 .. nameLength])).assumeOkay;
                        scope(exit)
                            seenFilePathBuffer.removeComponents(1);

                        FilePath seenEntry = seenFilePathBuffer.dup, currentEntry = seenEntry;
                        bool doNext = true;
                        bool directoryFollowAllowed = true;

                        // NOTE: the following code is more or less the same between the version branches
                    HandleSeenEntry:
                        FileType fileType = seenEntry.getType;

                        if(fileType == FileType.File) {
                            doNext = del(currentEntry, fileType);
                        } else if(fileType == FileType.Directory) {
                            static if(Mode == 0) {
                                doNext = del(currentEntry, fileType);
                            } else static if(Mode == 1) {
                                doNext = del(currentEntry, fileType);
                                if(doNext && directoryFollowAllowed)
                                    doNext = handleDirectory(entry.cFileName.ptr[0 .. nameLength]);
                            } else static if(Mode == 2) {
                                if(directoryFollowAllowed)
                                    doNext = handleDirectory(entry.cFileName.ptr[0 .. nameLength]);
                                if(doNext)
                                    doNext = del(currentEntry, fileType);
                            }
                        } else if(fileType == FileType.SymbolicLink) {
                            auto temp = seenEntry.followSymbolicLink;
                            directoryFollowAllowed = allowedToFollowIntoSymbolicLink;

                            if(temp) {
                                seenEntry = temp;
                                goto HandleSeenEntry;
                            }
                        }

                        if(!doNext)
                            return false;
                    }
                }
                while(FindNextFileW(iterator, &entry));
            }

            return true;
        }

        String_UTF16 path16 = path.toStringUTF16();
        handleDirectory(path16.unsafeGetLiteral);
    } else version(Posix) {
        import core.sys.posix.dirent : DIR, opendir, closedir, readdir, dirent;
        import core.stdc.string : strlen;

        bool handleDirectory(const(char)* dirPath) @trusted nothrow @nogc {
            DIR* iterator = opendir(dirPath);
            if(iterator is null)
                return true;

            scope(exit) {
                if(iterator !is null)
                    closedir(iterator);
            }

            dirent* entry;
            while(entry = readdir(iterator)) {
                const nameLength = strlen(entry.d_name.ptr);
                auto seenEntry = FilePath.from(String_UTF8(entry.d_name.ptr[0 .. nameLength])), currentEntry = seenEntry;
                bool directoryFollowAllowed = true;

                if(seenEntry) {
                    bool doNext = true;

                    // NOTE: the following code is more or less the same between the version branches
                HandleSeenEntry:
                    FileType fileType = seenEntry.getType;

                    if(fileType == FileType.File) {
                        doNext = del(currentEntry, fileType);
                    } else if(fileType == FileType.Directory) {
                        static if(Mode == 0) {
                            doNext = del(currentEntry, fileType);
                        } else static if(Mode == 1) {
                            doNext = del(currentEntry, fileType);
                            if(doNext && directoryFollowAllowed)
                                doNext = handleDirectory(seenEntry);
                        } else static if(Mode == 2) {
                            if(directoryFollowAllowed)
                                doNext = handleDirectory(seenEntry);
                            if(doNext)
                                doNext = del(currentEntry, fileType);
                        }
                    } else if(fileType == FileType.SymbolicLink) {
                        seenEntry = seenEntry.followSymbolicLink;
                        directoryFollowAllowed = allowedToFollowIntoSymbolicLink;
                        if(seenEntry)
                            goto HandleSeenEntry;
                    }

                    if(!doNext)
                        return false;
                }

                if(got && got.isFileDirectorySymbolicLink && !del(got.get))
                    return false;
            }

            return true;
        }

        String_UTF8 path8 = path.toString();
        handleDirectory(path8.ptr);
    }
}
