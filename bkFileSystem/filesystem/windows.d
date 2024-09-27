module sidero.eventloop.internal.filesystem.windows;
import sidero.eventloop.internal.filesystem.state;
import sidero.eventloop.filesystem.file;

version(Windows) {
    import sidero.eventloop.internal.windows.bindings;
}

@safe nothrow @nogc:

bool startUpFileSystemMechanism() {
    assert(0);
}

void shutdownFileSystemMechanism() {
    assert(0);
}

struct PlatformFile {
    version(Windows) {
        HANDLE handle;
    }

    enum keepAReadAlwaysGoing = true;
    shared(bool) isClosed;

@safe nothrow @nogc:

    // NOTE: must not be guarded
    void haveBeenRetriggered(scope FileState* fileState) scope {
        isWaitingForRetrigger = false;

        fileState.guard(&fileState.performReadWrite);
    }

    // NOTE: must be guarded
    void notifiedOfReadComplete(scope FileState* fileState) scope @trusted {
        this.havePendingAlwaysWaitingRead = false;
        this.havePendingRead = false;
    }

    void initiateAConstantlyRunningReadRequest(scope FileState* fileState) {
        // keepAReadAlwaysGoing == true
        assert(0);
    }
}

ErrorResult connectToSpecificFile(File file) {
    version(Windows) {
        String_UTF16 path16 = file.state.filePath.toStringUTF16();

        DWORD access = GENERIC_READ | GENERIC_WRITE;
        DWORD shareMode = FILE_SHARE_READ | FILE_SHARE_WRITE;

        if(file.state.fileRights.forceAppend)
            access |= FILE_APPEND_DATA;

        if(file.state.fileRights.create) {
            if(file.state.fileRights.createAsExecutable)
                access |= FILE_EXECUTE;

            file.state.handle = CreateFileW(path16.ptr, access, shareMode, null, CREATE_NEW, FILE_FLAG_OVERLAPPED, null);
        } else {
            file.state.handle = CreateFileW(path16.ptr, access, shareMode, null, OPEN_EXISTING, FILE_FLAG_OVERLAPPED, null);
        }

        if(file.state.handle is null)
            return typeof(return)(UnknownPlatformBehaviorException("Could not open/create a file given the path"));
        else
            return ErrorResult.init;
    } else
        assert(0);
}

void forceClose(scope FileState* fileState) {
    version(Windows) {
        import sidero.base.internal.atomic;

        if(cas(fileState.isClosed, false, true)) {
            logger.debug_("Forcing closed file ", fileState.handle);
            CloseHandle(fileState.handle);
        }
    } else
        assert(0);
}

bool tryWriteMechanism(scope FileState* fileState, ubyte[] buffer) {
    assert(0);
}

bool tryReadMechanism(scope FileState* fileState, ubyte[] buffer) {
    // OVERLAPPED specifies offset, must always be set
    assert(0);
}
