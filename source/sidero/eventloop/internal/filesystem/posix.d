module sidero.eventloop.internal.filesystem.posix;
import sidero.eventloop.internal.filesystem.defs;
import sidero.eventloop.internal.filesystem.state;
import sidero.eventloop.filesystem.file;
import sidero.base.errors;
import sidero.base.logger;

version(Posix) {
    import core.sys.posix.unistd;
    import core.sys.posix.stat;
}

@safe nothrow @nogc:

struct PlatformFile {
    version(Posix) {
        union {
            void* handle; // is a file descriptor and can be passed to addEventWaiterHandle directly
            int fd;
        }
    }

    enum keepAReadAlwaysGoing = false;

@safe nothrow @nogc:

     ~this() scope {
    }

    void initiateAConstantlyRunningReadRequest(scope FileState* fileState) {
        // not used on POSIX
        assert(0);
    }

    // NOTE: must be guarded
    void notifiedOfReadComplete(scope FileState* fileState) {
    }
}

ErrorResult openFile(File file) {
    version(Posix) {
        String_UTF8 path8 = file.state.filePath.toString();

        // DO NOT ADD O_NONBLOCK, posix systems only support blocking using this API
        uint flags = O_CLOEXEC | O_LARGEFILE;
        uint mode = S_IRUSR | S_IWUSR;

        if (file.state.fileRights.read && file.state.fileRights.write)
            flags |= O_RDWR;
        else if (file.state.fileRights.read)
            flags |= O_RDONLY;
        else if (file.state.fileRights.write)
            flags |= O_WRONLY;

        if(file.state.fileRights.forceAppend)
            flags |= O_APPEND;

        if(file.state.fileRights.create) {
            flags |= O_CREAT;

            if(file.state.fileRights.createAsExecutable)
                mode |= S_IXUSR;

            file.state.fd = open(path8.ptr, flags, mode);
        } else {
            file.state.fd = open(path8.ptr, flags);
        }

        if(file.state.handle is null)
            return typeof(return)(UnknownPlatformBehaviorException("Could not open/create a file given the path"));

        addEventWaiterHandle(file.state.handle, &handleFileEvent, file.state);
        file.state.pin();
        return ErrorResult.init;
    } else
        assert(0);
}

void forceClose(scope FileState* fileState) {
    version(Posix) {
        import sidero.base.internal.atomic;

        if(cas(fileState.isClosed, false, true)) {
            logger.debug_("Forcing closed file ", fileState.handle);
            close(fileState.fd);
            removeEventWaiterHandle(fileState.handle);
        }
    } else
        assert(0);
}

bool tryWriteMechanism(scope FileState* fileState, ubyte[] buffer, long position) {
    version(Posix) {
        import sidero.base.internal.atomic;

        if(atomicLoad(fileState.isClosed))
            return false;

        const err = pwrite(fileState.fd, buffer.ptr, buffer.length, position);

        if(err >= 0) {
            logger.debug_("Immediate completion of write ", fileState.handle, " on ", Thread.self);
            fileState.rawWriting.complete(fileState, err);
            return true;
        } else {
            logger.info("Failed to write initiate closing ", errno, " for ", fileState.handle, " on ", Thread.self);
            fileState.unpinGuarded;
            return false;
        }
    } else
        assert(0);
}

bool tryReadMechanism(scope FileState* fileState, ubyte[] buffer, long position) {
    version(Posix) {
        import sidero.base.internal.atomic;

        if(atomicLoad(fileState.isClosed))
            return false;

        const err = pread(fileState.fd, buffer.ptr, buffer.length, position);

        if(err == 0) {
            logger.info("Failed to read initiate closing for ", fileState.handle, " on ", Thread.self);
            fileState.rawReading.complete(fileState, 0);
            fileState.reading.rawReadFailed(fileState);
            fileState.unpinGuarded;
            return false;
        } else if(err > 0) {
            logger.debug_("Immediate completion of read ", fileState.handle, " on ", Thread.self);
            fileState.rawReading.complete(fileState, err);
            fileState.reading.rawReadFailed(fileState);
            return true;
        } else {
            fileState.rawReading.complete(fileState, 0);

            logger.info("Failed to read initiate closing ", errno, " for ", fileState.handle, " on ", Thread.self);
            fileState.reading.rawReadFailed(fileState);
            fileState.unpinGuarded;
            return false;
        }
    } else
        assert(0);
}

void handleFileEvent(void* handle, void* user, scope void* eventResponsePtr) @trusted {
    version(Posix) {
        import core.sys.posix.poll;

        FileState* fileState = cast(FileState*)user;
        const revent = *cast(int*)eventResponsePtr;

        logger.debug_("Got revent ", revent, " for ", fileState.handle);

        if(revent != 0) {
            if((revent & POLLNVAL) == POLLNVAL || (revent & POLLHUP) == POLLHUP) {
                logger.debug_("File closed ", fileState.handle, " on ", Thread.self);
                socketState.forceClose();
                socketState.unpin();
            } else if((revent & POLLIN) == POLLIN || (revent & POLLOUT) == POLLOUT) {
                // all ok nothing to do here
                socketState.guard(&fileState.performReadWrite);
            } else {
                logger.debug_("File got event and shouldn't have (may indicate a bug) ", revent, " with ",
                        fileState.handle, " on ", Thread.self);
            }
        }
    } else
        assert(0);
}

ulong getFileSize(scope FileState* fileState) @trusted {
    version(Posix) {
        stat buf;
        if(fstat(fileState.fd, &buf) != 0)
            return 0;

        return buf.st_size;
    } else
        assert(0);
}
