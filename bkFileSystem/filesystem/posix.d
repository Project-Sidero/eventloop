module sidero.eventloop.internal.filesystem.posix;
import sidero.eventloop.internal.filesystem.state;
import sidero.eventloop.filesystem.file;

version(Posix) {
    import core.sys.posix.unistd;
}

@safe nothrow @nogc:

bool startUpFileSystemMechanism() {
    assert(0);
}

void shutdownFileSystemMechanism() {
    assert(0);
}

struct PlatformFile {
    version(Posix) {
        union {
            void* handle; // is a file descriptor and can be passed to addEventWaiterHandle directly
            int fd;
        }
    }

    enum keepAReadAlwaysGoing = false;
    shared(bool) isClosed;
    bool isWaitingForRetrigger;

@safe nothrow @nogc:

     ~this() scope {
    }

    // NOTE: needs to be guarded
    private bool needToBeRetriggered(scope FileState* fileState) scope @trusted {
        import sidero.eventloop.internal.cleanup_timer;
        import sidero.base.internal.atomic : atomicLoad;

        if(isWaitingForRetrigger || atomicLoad(isClosed))
            return false;

        File file;
        file.state = fileState;
        file.state.rc(true);

        isWaitingForRetrigger = true;
        addFileToRetrigger(file);
        return true;
    }

    // NOTE: must not be guarded
    package(sidero.eventloop) {
        void haveBeenRetriggered(scope FileState* fileState) scope {
            isWaitingForRetrigger = false;

            fileState.guard(&fileState.performReadWrite);
        }
    }

    void initiateAConstantlyRunningReadRequest(scope FileState* fileState) {
        // not used on POSIX
        assert(0);
    }

    // NOTE: must be guarded
    void notifiedOfReadComplete(scope FileState* fileState) {
    }
}

ErrorResult connectToSpecificFile(File file) {
    version(Posix) {
        String_UTF8 path8 = file.state.filePath.toString();

        uint flags = O_CLOEXEC | O_RDONLY | O_WRONLY | O_RDWR | O_LARGEFILE | O_NONBLOCK;
        uint mode = S_IRUSR | S_IWUSR;

        if(file.state.fileRights.forceAppend)
            flags |= O_APPEND;

        if(file.state.fileRights.create) {
            flags |= O_CREAT;

            if(file.state.fileRights.createAsExecutable)
                mode |= S_IXUSR;

            handle.handle = cast(void*)open(path8.ptr, flags, mode);
        } else {
            handle.handle = cast(void*)open(path8.ptr, flags);
        }

        if(file.state.handle is null)
            return typeof(return)(UnknownPlatformBehaviorException("Could not open/create a file given the path"));
        else
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

bool tryWriteMechanism(scope FileState* fileState, ubyte[] buffer, ulong position) {
    assert(0);
}

bool tryReadMechanism(scope FileState* fileState, ubyte[] buffer) {
    // fileState.requestedReadPosition

    // pread
    assert(0);
}
