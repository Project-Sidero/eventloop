module sidero.eventloop.processes.pipe;
import sidero.base.allocators;

version(Windows) {
    import sidero.eventloop.internal.windows.bindings : HANDLE;
}

///
struct ReadPipe {
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
    ~this() {
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
    bool isOpen() scope const {
        return !isNull && state.readStillOpen;
    }

    version(Windows) {
        ///
        static ReadPipe fromSystemHandle(HANDLE handle) @system {
            import sidero.base.internal.logassert;
            // TODO: allocate state
            //logAssert(!rawReading.initialize, "Could not initialize raw reading for socket");

            // TODO: add to eventloop for closure and notification of read

            version(Windows) {
                // TODO: add to IOCP
            }

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
    ~this() {
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
    bool isOpen() scope const {
        return !isNull && state.writeStillOpen;
    }

    version(Windows) {
        ///
        static WritePipe fromSystemHandle(HANDLE handle) {
            import sidero.base.internal.logassert;
            // TODO: allocate state
            //logAssert(!rawReading.initialize, "Could not initialize raw reading for socket");

            // TODO: add to eventloop for closure

            version(Windows) {
                // TODO: add to IOCP
            }

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
    bool readStillOpen, writeStillOpen;

    enum amountToRead = 4096;
    RawReadingState!(State, "pipe") rawReadingState;
    RawWritingState!(State, "pipe") rawWritingState;

@safe nothrow @nogc:

    void cleanup() scope {

    }

    bool tryRead(ubyte[] data) scope {
        assert(0);
    }

    bool tryWrite(ubyte[] data) scope {
        assert(0);
    }
}
