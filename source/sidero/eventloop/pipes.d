module sidero.eventloop.pipes;
import sidero.eventloop.handles;
import sidero.eventloop.coroutine.future;
import sidero.eventloop.threads;
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

ReadPipe acquireStdinPipe() @trusted {
    return processStdinPipe;
}

WritePipe acquireStdoutPipe() @trusted {
    return processStdoutPipe;
}

WritePipe acquireStderrPipe() @trusted {
    return processStderrPipe;
}

///
ErrorResult createAnonymousPipe(out ReadPipe readPipe, out WritePipe writePipe, RCAllocator allocator = RCAllocator.init) {
    import sidero.base.internal.logassert;
    import sidero.base.internal.atomic;

    if(allocator.isNull)
        allocator = globalAllocator();

    version(Windows) {
        import sidero.eventloop.internal.windows.bindings : CreatePipe, PIPE_READMODE_BYTE, PIPE_NOWAIT, SetNamedPipeHandleState, DWORD;

        HANDLE readPipeHandle, writePipeHandle;

        if(!CreatePipe(&readPipeHandle, &writePipeHandle, null, 0))
            return ErrorResult(UnknownPlatformBehaviorException("Could not create anonymous pipes"));

        DWORD mode = PIPE_READMODE_BYTE | PIPE_NOWAIT;

        // If this fails, it'll block (not a bad thing)
        // It just means that WriteFile won't return ASAP even if it can't write
        SetNamedPipeHandleState(writePipeHandle, &mode, null, null);
    } else version(Posix) {
        import core.sys.posix.unistd : pipe, close;
        import core.sys.posix.fcntl : fcntl, F_SETFL, O_NONBLOCK;

        int[2] handles;

        if(pipe(handles) != 0)
            return ErrorResult(UnknownPlatformBehaviorException("Could not create anonymous pipes"));

        if(fcntl(handles[0], F_SETFL, O_NONBLOCK) != 0) {
            close(handles[0]);
            close(handles[1]);
            return ErrorResult(UnknownPlatformBehaviorException("Could not set non block on anonymous read pipes"));
        }

        if(fcntl(handles[1], F_SETFL, O_NONBLOCK) != 0) {
            close(handles[0]);
            close(handles[1]);
            return ErrorResult(UnknownPlatformBehaviorException("Could not set non block on anonymous write pipes"));
        }

        int readPipeHandle = handles[0], writePipeHandle = handles[1];
    } else
        static assert(0, "Unimplemented platform");

    readPipe.state = allocator.make!State;
    writePipe.state = readPipe.state;
    atomicStore(readPipe.state.refCount, 2);

    readPipe.state.allocator = allocator;
    readPipe.state.readHandle = cast(void*)readPipeHandle;
    readPipe.state.writeHandle = cast(void*)writePipeHandle;

    logAssert(readPipe.state.reading.initialize, "Could not initialize reading for read pipe");
    logAssert(readPipe.state.rawReading.initialize, "Could not initialize raw reading for read pipe");
    logAssert(readPipe.state.rawWriting.initialize, "Could not initialize raw writing for write pipe");

    readPipe.state.addToEventWait;
    return ErrorResult.init;
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
    bool isOpen() scope const {
        import sidero.base.internal.atomic;

        return state !is null && atomicLoad(state.readStillOpen);
    }

    ///
    SystemHandle unsafeGetHandle() scope const @trusted {
        if(isNull)
            return SystemHandle.init;
        return SystemHandle(cast(void*)state.readHandle, ReadOnlyPipeHandleType);
    }

    ///
    Future!(Slice!ubyte) read(size_t amount) scope @trusted {
        if(isNull || !isOpen)
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
        if(isNull || !isOpen)
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

            ret.state.addToEventWait;
            return ret;
        }
    } else version(Posix) {
        ///
        static ReadPipe fromSystemHandle(int handle, RCAllocator allocator = RCAllocator.init) @system {
            import sidero.base.internal.atomic;
            import sidero.base.internal.logassert;
            import core.sys.posix.fcntl;

            fcntl(handle, F_SETFL, fcntl(handle, F_GETFL) | O_NONBLOCK);

            if(allocator.isNull)
                allocator = globalAllocator();

            ReadPipe ret;
            ret.state = allocator.make!State;
            atomicStore(ret.state.refCount, 1);

            ret.state.allocator = allocator;
            ret.state.readHandle = cast(void*)handle;

            logAssert(ret.state.reading.initialize, "Could not initialize reading for read pipe");
            logAssert(ret.state.rawReading.initialize, "Could not initialize raw reading for read pipe");

            ret.state.addToEventWait;
            return ret;
        }
    }
}

///
struct WritePipe {
    package(sidero.eventloop) {
        State* state;
    }

export @safe nothrow @nogc:

    ///
    this(scope ref WritePipe other) scope @trusted {
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
    bool isOpen() scope const {
        import sidero.base.internal.atomic;

        return state !is null && atomicLoad(state.writeStillOpen);
    }

    ///
    SystemHandle unsafeGetHandle() scope const @trusted {
        if(isNull)
            return SystemHandle.init;
        return SystemHandle(cast(void*)state.writeHandle, WriteOnlyPipeHandleType);
    }

    ///
    void write(scope return DynamicArray!ubyte data) scope {
        this.write(data.asReadOnly());
    }

    ///
    void write(scope return Slice!ubyte data) scope {
        if(isNull || !isOpen)
            return;

        state.guard(() @trusted {
            state.rawWriting.push(data);

            if(!state.rawWriting.tryWrite(state))
                state.delayWriteForLater;
        });
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
        static WritePipe fromSystemHandle(HANDLE handle, RCAllocator allocator = RCAllocator.init) @trusted {
            import sidero.base.internal.atomic;
            import sidero.base.internal.logassert;
            import sidero.eventloop.internal.windows.bindings : PIPE_READMODE_BYTE, PIPE_NOWAIT, SetNamedPipeHandleState, DWORD;

            if(allocator.isNull)
                allocator = globalAllocator();

            WritePipe ret;
            ret.state = allocator.make!State;
            atomicStore(ret.state.refCount, 1);

            ret.state.allocator = allocator;
            ret.state.writeHandle = handle;

            DWORD mode = PIPE_READMODE_BYTE | PIPE_NOWAIT;

            // If this fails, it'll block (not a bad thing)
            // It just means that WriteFile won't return ASAP even if it can't write
            SetNamedPipeHandleState(handle, &mode, null, null);

            logAssert(ret.state.rawWriting.initialize, "Could not initialize raw writing for write pipe");
            ret.state.addToEventWait;
            return ret;
        }
    } else version(Posix) {
        ///
        static WritePipe fromSystemHandle(int handle, RCAllocator allocator = RCAllocator.init) @system {
            import sidero.base.internal.atomic;
            import sidero.base.internal.logassert;
            import core.sys.posix.fcntl;

            fcntl(handle, F_SETFL, fcntl(handle, F_GETFL) | O_NONBLOCK);

            if(allocator.isNull)
                allocator = globalAllocator();

            WritePipe ret;
            ret.state = allocator.make!State;
            atomicStore(ret.state.refCount, 1);

            ret.state.allocator = allocator;
            ret.state.writeHandle = cast(void*)handle;

            logAssert(ret.state.rawWriting.initialize, "Could not initialize raw writing for write pipe");
            ret.state.addToEventWait;
            return ret;
        }
    }
}

private:
import sidero.eventloop.internal.pipes.reading;
import sidero.eventloop.internal.pipes.rawreading;
import sidero.eventloop.internal.pipes.rawwriting;
import sidero.base.logger;
import sidero.base.text;

__gshared {
    LoggerReference logger;
    ReadPipe processStdinPipe;
    WritePipe processStdoutPipe;
    WritePipe processStderrPipe;
}

pragma(crt_constructor) extern (C) void sidero_setup_process_pipes() @trusted {
    version(Windows) {
        import sidero.eventloop.internal.windows.bindings : HANDLE, INVALID_HANDLE_VALUE, GetStdHandle,
            STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE;

        HANDLE handle = GetStdHandle(STD_INPUT_HANDLE);
        if(handle !is INVALID_HANDLE_VALUE && handle !is null)
            processStdinPipe = ReadPipe.fromSystemHandle(handle);

        handle = GetStdHandle(STD_OUTPUT_HANDLE);
        if(handle !is INVALID_HANDLE_VALUE && handle !is null)
            processStdoutPipe = WritePipe.fromSystemHandle(handle);

        handle = GetStdHandle(STD_ERROR_HANDLE);
        if(handle !is INVALID_HANDLE_VALUE && handle !is null)
            processStderrPipe = WritePipe.fromSystemHandle(handle);
    } else version(Posix) {
        import core.sys.posix.unistd : STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO;

        processStdinPipe = ReadPipe.fromSystemHandle(STDIN_FILENO);
        processStdoutPipe = WritePipe.fromSystemHandle(STDOUT_FILENO);
        processStderrPipe = WritePipe.fromSystemHandle(STDERR_FILENO);
    } else
        static assert(0, "unimplemented platform");
}

pragma(crt_destructor) extern (C) void sidero_shutdown_process_pipes() @trusted {
    processStdinPipe = ReadPipe.init;
    processStdoutPipe = WritePipe.init;
    processStderrPipe = WritePipe.init;
}

struct State {
    shared(ptrdiff_t) refCount;
    RCAllocator allocator;

    SystemLock mutex;
    void* readHandle, writeHandle;
    shared(bool) readStillOpen = true, writeStillOpen = true;

    enum attemptReadLater = true;
    enum amountToRead = 4096;
    enum keepAReadAlwaysGoing = false;

    ReadingState!(State, "pipe", false) reading;
    RawReadingState!(State, "pipe") rawReading;
    RawWritingState!(State, "pipe") rawWriting;

@safe nothrow @nogc:

    void cleanup() scope {
        cleanupRead;
        cleanupWrite;
    }

    void cleanupRead() scope @trusted {
        import sidero.eventloop.internal.event_waiting;

        if(this.readHandle is null)
            return;

        reading.cleanup;

        version(Windows) {
            import sidero.eventloop.internal.windows.bindings : CloseHandle;

            CloseHandle(this.readHandle);
        } else version(Posix) {
            removeEventWaiterHandle(this.readHandle);
        } else
            static assert(0);

        this.readHandle = null;
    }

    void cleanupWrite() scope @trusted {
        import sidero.eventloop.internal.event_waiting;

        if(this.writeHandle is null)
            return;

        version(Windows) {
            import sidero.eventloop.internal.windows.bindings : CloseHandle;

            CloseHandle(this.writeHandle);
        } else version(Posix) {
            removeEventWaiterHandle(this.writeHandle);
        } else
            static assert(0);

        this.writeHandle = null;
    }

    void addToEventWait() scope @trusted {
        import sidero.eventloop.internal.event_waiting;

        if(!logger || logger.isNull)
            logger = Logger.forName(String_UTF8(__MODULE__));
        assert(logger);

        version(Posix) {
            import core.sys.posix.poll;

            static void handleReadEvent(void* handle, void* user, scope void* eventResponsePtr) @trusted {
                State* state = cast(State*)user;
                const revent = *cast(int*)eventResponsePtr;
                logger.trace("Read pipe got event ", state.readHandle, " ", revent);

                if(revent != 0) {
                    if((revent & POLLIN) == POLLIN) {
                        state.guard(&state.performARead);
                    } else if((revent & POLLNVAL) == POLLNVAL || (revent & POLLHUP) == POLLHUP) {
                        logger.debug_("Read pipe closed ", state.readHandle, " on ", Thread.self);
                        state.readStillOpen = false;
                        state.guard(&state.cleanupRead);
                    } else {
                        logger.debug_("Read pipe got event and shouldn't have (may indicate a bug) ", revent, " with ",
                                state.readHandle, " on ", Thread.self);
                    }
                }
            }

            static void handleWriteEvent(void* handle, void* user, scope void* eventResponsePtr) @trusted {
                State* state = cast(State*)user;
                const revent = *cast(int*)eventResponsePtr;
                logger.trace("Write pipe got event ", state.writeHandle, " ", revent);

                if(revent != 0) {
                    if((revent & POLLOUT) == POLLOUT) {
                        state.guard(&state.performAWrite);
                    } else if((revent & POLLNVAL) == POLLNVAL || (revent & POLLHUP) == POLLHUP) {
                        logger.debug_("Write pipe closed ", state.writeHandle, " on ", Thread.self);
                        state.writeStillOpen = false;
                        state.guard(&state.cleanupWrite);
                    } else {
                        logger.debug_("Write pipe got event and shouldn't have (may indicate a bug) ", revent,
                                " with ", state.writeHandle, " on ", Thread.self);
                    }
                }
            }

            if(this.readHandle !is null)
                addEventWaiterHandle(this.readHandle, &handleReadEvent, &this);

            if(this.writeHandle !is null)
                addEventWaiterHandle(this.writeHandle, &handleWriteEvent, &this);
        }
    }

    void guard(Return, Args...)(scope Return delegate(return scope Args) @safe nothrow @nogc del, return scope Args args) scope @trusted {
        mutex.lock.assumeOkay;
        del(args);
        mutex.unlock;
    }

    void delayReadForLater() scope @trusted {
        import sidero.eventloop.internal.cleanup_timer;

        ReadPipe rp;
        rp.state = &this;
        rp.__ctor(rp);

        addReadPipeToList(rp);
    }

    void delayWriteForLater() scope @trusted {
        import sidero.eventloop.internal.cleanup_timer;

        WritePipe wp;
        wp.state = &this;
        wp.__ctor(wp);

        addWritePipeToList(wp);
    }

    bool performARead() scope @trusted {
        bool didRead = this.rawReading.tryRead(&this);
        didRead = this.rawReading.attemptRead(&this);
        return this.reading.tryFulfillRequest(&this);
    }

    bool performAWrite() scope @trusted {
        bool doneOne;

        while(this.rawWriting.tryWrite(&this)) {
            doneOne = true;
        }

        return doneOne;
    }

    bool tryRead(ubyte[] data) scope @trusted {
        import sidero.base.internal.atomic;

        if(!atomicLoad(readStillOpen))
            return false;

        logger.trace("reading ", data.length);

        version(Windows) {
            import sidero.eventloop.internal.windows.bindings : DWORD, PeekNamedPipe, ReadFile, GetLastError, ERROR_BROKEN_PIPE;

            DWORD canBeRead;

            auto errorCode = PeekNamedPipe(this.readHandle, null, cast(DWORD)data.length, null, &canBeRead, null);

            if(errorCode == 0) {
                auto error = GetLastError();

                if(error == ERROR_BROKEN_PIPE) {
                    atomicStore(readStillOpen, false);
                    this.cleanupRead;
                }

                return false;
            }

            if(errorCode == 0 || canBeRead == 0) {
                return false;
            }

            if(canBeRead > data.length)
                canBeRead = cast(DWORD)data.length;

            errorCode = ReadFile(this.readHandle, data.ptr, cast(DWORD)data.length, &canBeRead, null);

            if(errorCode == 0) {
                auto error = GetLastError();

                if(error == ERROR_BROKEN_PIPE) {
                    atomicStore(readStillOpen, false);
                    this.cleanupRead;
                }

                return false;
            }

            rawReading.complete(&this, canBeRead);
            return true;
        } else version(Posix) {
            import core.sys.posix.unistd;
            import core.stdc.errno;

            auto canBeRead = read(cast(int)this.readHandle, data.ptr, data.length);
            logger.trace("read ", canBeRead, " errno ", errno);

            if(canBeRead > 0) {
                rawReading.complete(&this, canBeRead);
                return true;
            } else if(canBeRead == 0) {
                // empty not an error, but didn't complete
            } else {
                switch(errno) {
                case EAGAIN:
                    // ok not a failure
                    break;

                case EBADF:
                    // not a handle
                    atomicStore(readStillOpen, false);
                    this.cleanupRead;
                    break;

                default:
                    // unknown error
                    break;
                }
            }

            return false;
        } else
            static assert(0);
    }

    bool tryWrite(ubyte[] data) scope @trusted {
        import sidero.base.internal.atomic;

        if(!atomicLoad(writeStillOpen))
            return false;

        logger.trace("trying to write ", data.length);

        version(Windows) {
            import sidero.eventloop.internal.windows.bindings : DWORD, WriteFile, GetLastError, ERROR_BROKEN_PIPE;

            DWORD canBeWritten;

            auto errorCode = WriteFile(this.writeHandle, data.ptr, cast(DWORD)data.length, &canBeWritten, null);

            if(errorCode == 0) {
                auto error = GetLastError();

                if(error == ERROR_BROKEN_PIPE) {
                    atomicStore(writeStillOpen, false);
                    this.cleanupWrite;
                }

                return false;
            }

            // not a failure, but also needs to to a delay write
            if(canBeWritten == 0)
                return false;

            rawWriting.complete(&this, canBeWritten);
            return true;
        } else version(Posix) {
            import core.sys.posix.unistd;
            import core.stdc.errno;

            auto canBeWritten = write(cast(int)this.writeHandle, data.ptr, data.length);
            logger.trace("written ", canBeWritten, " errno ", errno);

            if(canBeWritten > 0) {
                rawWriting.complete(&this, canBeWritten);
                return true;
            } else if(canBeWritten == 0) {
                // empty not an error, but didn't complete
            } else {
                switch(errno) {
                case EAGAIN:
                    // ok not a failure
                    break;

                case EBADF:
                    // not a handle
                    atomicStore(writeStillOpen, false);
                    this.cleanupWrite;
                    break;

                default:
                    // unknown error
                    break;
                }
            }

            return false;
        } else
            static assert(0);
    }

    void initiateAConstantlyRunningReadRequest(scope State* socketState) scope {
        // Not supported anywhere
        assert(0);
    }

    void notifiedOfReadComplete(scope State* socketState) scope {
        // Not needed
    }
}
