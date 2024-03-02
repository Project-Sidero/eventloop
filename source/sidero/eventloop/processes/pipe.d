module sidero.eventloop.processes.pipe;
import sidero.eventloop.handles;
import sidero.base.allocators;
import sidero.base.errors;
import sidero.base.path.file;

version(Windows) {
    import sidero.eventloop.internal.windows.bindings : HANDLE;
}

///
static immutable ReadOnlyPipeHandleType = SystemHandleType.from("ropipe");
///
static immutable WriteOnlyPipeHandleType = SystemHandleType.from("wopipe");

///
ErrorResult createAnonymousPipe(out ReadPipe readPipe, out WritePipe writePipe) {
    version(Windows) {
        import sidero.eventloop.internal.windows.bindings : CreatePipe;

        HANDLE readPipeHandle, writePipeHandle;

        if(!CreatePipe(&readPipeHandle, &writePipeHandle, null, 0))
            return ErrorResult(UnknownPlatformBehaviorException("Could not create anonymous pipes"));

        readPipe = ReadPipe.fromSystemHandle(readPipeHandle);
        writePipe = WritePipe.fromSystemHandle(writePipeHandle);
        return ErrorResult.init;
    } else
        static assert(0, "Unimplemented platform");
}

///
ErrorResult openNamedPipe(FilePath filePath, out ReadPipe readPipe, bool deleteOnClose = false) {
    // posix mkfifo will return EEXIST if it already exists

    assert(0);
}

///
ErrorResult openNamedPipe(FilePath filePath, out WritePipe writePipe, bool deleteOnClose = true) {
    // posix mkfifo will return EEXIST if it already exists

    assert(0);
}

///
struct ReadPipe {
    package(sidero.eventloop) {
        State* state;
    }

export @safe nothrow @nogc:

    ///
    this(scope ref ReadPipe other) scope @trusted {
        import sidero.base.internal.atomic;

        this.state = other.state;

        if(this.state !is null) {
            atomicIncrementAndLoad(this.state.refCount, 1);
        }
    }

    ///
    ~this() scope {
        import sidero.base.internal.atomic;

        if(this.state !is null && atomicDecrementAndLoad(this.state.refCount, 1) == 0) {
            this.state.cleanup;

            RCAllocator allocator = state.allocator;
            allocator.dispose(this.state);
        }
    }

    ///
    bool isNull() scope const {
        return state is null;
    }

    ///
    SystemHandle unsafeGetHandle() scope const @trusted {
        if(isNull)
            return SystemHandle.init;
        return SystemHandle(cast(void*)state.readHandle, ReadOnlyPipeHandleType);
    }

    ///
    int opCmp(scope ReadPipe other) scope const {
        if(other.state is this.state)
            return 0;
        else if(other.state > this.state)
            return -1;
        else
            return 1;
    }

    version(Windows) {
        ///
        static ReadPipe fromSystemHandle(HANDLE handle) @system {
            import sidero.eventloop.internal.cleanup_timer;
            import sidero.base.internal.logassert;

            // TODO: allocate state
            //logAssert(!rawReading.initialize, "Could not initialize raw reading for socket");
            //logAssert(!rawWriting.initialize, "Could not initialize raw writing for socket");

            // addReadPipeToList(ret);

            assert(0);
        }
    } else version(Posix) {
        ///
        static ReadPipe fromSystemHandle(int handle) @system {
            import sidero.base.internal.logassert;

            // TODO: allocate state
            //logAssert(!rawReading.initialize, "Could not initialize raw reading for socket");
            //logAssert(!rawWriting.initialize, "Could not initialize raw writing for socket");

            // TODO: add to eventloop for closure and notification of read

            //fcntl(handle, F_SETFL, fcntl(handle, F_GETFL) | O_NONBLOCK);

            assert(0);
        }
    }
}

///
struct WritePipe {
    private {
        State* state;
    }

export @safe nothrow @nogc:

    ///
    this(scope ref ReadPipe other) scope @trusted {
        import sidero.base.internal.atomic;

        this.state = other.state;

        if(this.state !is null) {
            atomicIncrementAndLoad(this.state.refCount, 1);
        }
    }

    ///
    ~this() scope {
        import sidero.base.internal.atomic;

        if(this.state !is null && atomicDecrementAndLoad(this.state.refCount, 1) == 0) {
            this.state.cleanup;

            RCAllocator allocator = state.allocator;
            allocator.dispose(this.state);
        }
    }

    ///
    bool isNull() scope const {
        return state is null;
    }

    ///
    SystemHandle unsafeGetHandle() scope const @trusted {
        if(isNull)
            return SystemHandle.init;
        return SystemHandle(cast(void*)state.writeHandle, WriteOnlyPipeHandleType);
    }

    ///
    int opCmp(scope WritePipe other) scope const {
        if(other.state is this.state)
            return 0;
        else if(other.state > this.state)
            return -1;
        else
            return 1;
    }

    version(Windows) {
        ///
        static WritePipe fromSystemHandle(HANDLE handle) {
            import sidero.base.internal.logassert;

            // TODO: allocate state
            //logAssert(!rawReading.initialize, "Could not initialize raw reading for socket");
            //logAssert(!rawWriting.initialize, "Could not initialize raw writing for socket");

            assert(0);
        }
    } else version(Posix) {
        ///
        static WritePipe fromSystemHandle(int handle) @system {
            import sidero.base.internal.logassert;

            // TODO: allocate state
            //logAssert(!rawReading.initialize, "Could not initialize raw reading for socket");
            //logAssert(!rawWriting.initialize, "Could not initialize raw writing for socket");

            // TODO: add to eventloop for closure and notification of read

            //fcntl(handle, F_SETFL, fcntl(handle, F_GETFL) | O_NONBLOCK);

            assert(0);
        }
    }
}

private:
import sidero.eventloop.internal.pipes.rawreading;
import sidero.eventloop.internal.pipes.rawwriting;

struct State {
    shared(ptrdiff_t) refCount;
    RCAllocator allocator;

    void* readHandle, writeHandle;

    version(Windows) {
        enum attemptReadLater = true;
    } else {
        enum attemptReadLater = false;
    }

    enum amountToRead = 4096;
    RawReadingState!(State, "pipe") rawReadingState;
    RawWritingState!(State, "pipe") rawWritingState;

@safe nothrow @nogc:

    void cleanup() scope @trusted {
        version(Windows) {
            import sidero.eventloop.internal.windows.bindings : CloseHandle;

            CloseHandle(this.readHandle);
            CloseHandle(this.writeHandle);

            this.readHandle = null;
            this.writeHandle = null;
        } else
            static assert(0);
    }

    void delayReadForLater() scope @trusted {
        import sidero.eventloop.internal.cleanup_timer;

        version(Windows) {
            ReadPipe rp;
            rp.state = &this;
            rp.__ctor(rp);

            addReadPipeToList(rp);
        } else
            assert(0);
    }

    bool tryRead(ubyte[] data) scope @trusted {
        version(Windows) {
            import sidero.eventloop.internal.windows.bindings : DWORD, PeekNamedPipe, ReadFile;

            DWORD canBeRead;

            if(!PeekNamedPipe(this.readHandle, null, cast(DWORD)data.length, &canBeRead, null, null))
                return false;

            if(!ReadFile(this.readHandle, data.ptr, cast(DWORD)data.length, &canBeRead, null))
                return false;

            rawReadingState.complete(&this, canBeRead);
            return true;
        } else
            static assert(0);
    }

    bool tryWrite(ubyte[] data) scope @trusted {
        version(Windows) {
            import sidero.eventloop.internal.windows.bindings : DWORD, WriteFile;

            DWORD canBeWritten;

            if(!WriteFile(this.writeHandle, data.ptr, cast(DWORD)data.length, &canBeWritten, null))
                return false;

            rawWritingState.complete(&this, canBeWritten);
            return true;
        } else
            static assert(0);
    }
}
