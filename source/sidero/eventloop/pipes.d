module sidero.eventloop.pipes;
import sidero.eventloop.handles;
import sidero.eventloop.coroutine.future;
import sidero.base.allocators;
import sidero.base.errors;
import sidero.base.path.file;
import sidero.base.containers.readonlyslice;
import sidero.base.containers.dynamicarray;
import sidero.base.synchronization.system.lock;

version(Windows) {
    import sidero.eventloop.internal.windows.bindings : HANDLE;
}

///
static immutable ReadOnlyPipeHandleType = SystemHandleType.from("ropipe");
///
static immutable WriteOnlyPipeHandleType = SystemHandleType.from("wopipe");

///
ErrorResult createAnonymousPipe(out ReadPipe readPipe, out WritePipe writePipe, RCAllocator allocator = RCAllocator.init) {
    version(Windows) {
        import sidero.eventloop.internal.windows.bindings : CreatePipe;
        import sidero.base.internal.atomic;
        import sidero.base.internal.logassert;

        HANDLE readPipeHandle, writePipeHandle;

        if(!CreatePipe(&readPipeHandle, &writePipeHandle, null, 0))
            return ErrorResult(UnknownPlatformBehaviorException("Could not create anonymous pipes"));

        if(allocator.isNull)
            allocator = globalAllocator();

        readPipe.state = allocator.make!State;
        writePipe.state = readPipe.state;
        atomicStore(readPipe.state.refCount, 2);

        readPipe.state.allocator = allocator;
        readPipe.state.readHandle = readPipeHandle;
        readPipe.state.writeHandle = writePipeHandle;

        logAssert(readPipe.state.reading.initialize, "Could not initialize reading for read pipe");
        logAssert(readPipe.state.rawReading.initialize, "Could not initialize raw reading for read pipe");
        logAssert(readPipe.state.rawWriting.initialize, "Could not initialize raw writing for write pipe");
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
    Future!(Slice!ubyte) read(size_t amount) scope @trusted {
        if(isNull)
            return typeof(return).init;

        Future!(Slice!ubyte) ret;

        state.guard(() {
            const cond = state.reading.requestFromUser(amount, ret);

            if(cond) {
                state.rawReading.tryRead(state);
                state.reading.tryFulfillRequest(state);
            }
        });

        return ret;
    }

    ///
    Future!(Slice!ubyte) readUntil(scope return DynamicArray!ubyte endCondition) scope {
        return this.readUntil(endCondition.asReadOnly());
    }

    ///
    Future!(Slice!ubyte) readUntil(scope return Slice!ubyte endCondition) scope @trusted {
        assert(!isNull);
        if(isNull)
            return typeof(return).init;

        Future!(Slice!ubyte) ret;

        state.guard(() @safe {
            const cond = state.reading.requestFromUser(endCondition, ret);

            if(cond) {
                state.rawReading.tryRead(state);
                state.reading.tryFulfillRequest(state);
            }
        });

        return ret;
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
        static ReadPipe fromSystemHandle(HANDLE handle, RCAllocator allocator = RCAllocator.init) @system {
            import sidero.base.internal.atomic;
            import sidero.base.internal.logassert;

            if(allocator.isNull)
                allocator = globalAllocator();

            ReadPipe ret;
            ret.state = allocator.make!State;
            atomicStore(ret.state.refCount, 1);

            ret.state.allocator = allocator;
            ret.state.readHandle = handle;

            logAssert(ret.state.reading.initialize, "Could not initialize reading for read pipe");
            logAssert(ret.state.rawReading.initialize, "Could not initialize raw reading for read pipe");
            return ret;
        }
    } else version(Posix) {
        ///
        static ReadPipe fromSystemHandle(int handle, RCAllocator allocator = RCAllocator.init) @system {
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
        static WritePipe fromSystemHandle(HANDLE handle, RCAllocator allocator = RCAllocator.init) {
            import sidero.base.internal.atomic;
            import sidero.base.internal.logassert;

            if(allocator.isNull)
                allocator = globalAllocator();

            WritePipe ret;
            ret.state = allocator.make!State;
            atomicStore(ret.state.refCount, 1);

            ret.state.allocator = allocator;
            ret.state.writeHandle = handle;

            logAssert(ret.state.rawWriting.initialize, "Could not initialize raw writing for write pipe");
            return ret;
        }
    } else version(Posix) {
        ///
        static WritePipe fromSystemHandle(int handle, RCAllocator allocator = RCAllocator.init) @system {
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
import sidero.eventloop.internal.pipes.reading;
import sidero.eventloop.internal.pipes.rawreading;
import sidero.eventloop.internal.pipes.rawwriting;

struct State {
    shared(ptrdiff_t) refCount;
    RCAllocator allocator;

    SystemLock mutex;
    void* readHandle, writeHandle;

    version(Windows) {
        enum attemptReadLater = true;
    } else {
        enum attemptReadLater = false;
    }

    enum amountToRead = 4096;
    ReadingState!(State, "pipe", false) reading;
    RawReadingState!(State, "pipe") rawReading;
    RawWritingState!(State, "pipe") rawWriting;

@safe nothrow @nogc:

    void cleanup() scope @trusted {
        reading.cleanup;

        version(Windows) {
            import sidero.eventloop.internal.windows.bindings : CloseHandle;

            CloseHandle(this.readHandle);
            CloseHandle(this.writeHandle);
        } else
            static assert(0);

        this.readHandle = null;
        this.writeHandle = null;
    }

    void guard(Args...)(scope void delegate(return scope Args) @safe nothrow @nogc del, return scope Args args) scope @trusted {
        mutex.lock.assumeOkay;
        del(args);
        mutex.unlock;
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
            import sidero.eventloop.internal.windows.bindings : DWORD, PeekNamedPipe, ReadFile, GetLastError;

            DWORD canBeRead;

            auto errorCode = PeekNamedPipe(this.readHandle, null, cast(DWORD)data.length, null, &canBeRead, null);
            if(errorCode == 0 || canBeRead == 0) {
                return false;
            }

            if(canBeRead > data.length)
                canBeRead = cast(DWORD)data.length;

            errorCode = ReadFile(this.readHandle, data.ptr, canBeRead, &canBeRead, null);
            if(errorCode == 0) {
                return false;
            }

            rawReading.complete(&this, canBeRead);
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

            rawWriting.complete(&this, canBeWritten);
            return true;
        } else
            static assert(0);
    }
}
