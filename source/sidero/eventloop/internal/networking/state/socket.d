module sidero.eventloop.internal.networking.state.socket;
import sidero.eventloop.internal.networking.state.defs;
import sidero.eventloop.internal.networking.state.writing;
import sidero.eventloop.internal.networking.state.encryption;
import sidero.eventloop.internal.pipes.reading;
import sidero.eventloop.internal.pipes.rawreading;
import sidero.eventloop.internal.pipes.rawwriting;
import sidero.eventloop.internal.networking.platform;
import sidero.eventloop.sockets;
import sidero.eventloop.threads.osthread;
import sidero.base.synchronization.system.lock;
import sidero.base.allocators;
import sidero.base.path.networking;
import sidero.base.internal.atomic;
import sidero.base.errors;
import sidero.base.typecons : Optional;
import sidero.base.datetime.duration;

struct SocketState {
    private {
        SystemLock mutex;
        RCAllocator allocator;

        shared(ptrdiff_t) refCount;

        bool inShutdownProcess;
    }

    shared(bool) isAlive, isShutdown;
    Socket.Protocol protocol;
    NetworkAddress localAddress, remoteAddress;
    bool cameFromServer;
    bool hasJustBeenAccepted;

    WritingState writing;
    EncryptionState encryption;

    enum attemptReadLater = false;
    ReadingState!(SocketState, "socket", true) reading;
    RawReadingState!(SocketState, "socket") rawReading;
    RawWritingState!(SocketState, "socket") rawWriting;

    PlatformSocket platform;
    alias platform this;

@safe nothrow @nogc:

    this(return scope RCAllocator allocator, Socket.Protocol protocol, bool cameFromServer) scope {
        import sidero.base.internal.logassert;

        checkInit;
        this.allocator = allocator;
        this.refCount = 1;
        this.protocol = protocol;
        this.cameFromServer = cameFromServer;

        logAssert(reading.initialize, "Could not initialize reading for socket");
        logAssert(rawReading.initialize, "Could not initialize raw reading for socket");
        logAssert(rawWriting.initialize, "Could not initialize raw writing for socket");
    }

    ~this() scope {
    }

    void rc(bool addRef) scope @trusted {
        if(addRef)
            atomicIncrementAndLoad(refCount, 1);
        else {
            ptrdiff_t refCount = atomicDecrementAndLoad(this.refCount, 1);

            if(inShutdownProcess) {
            } else if(refCount == 0) {
                inShutdownProcess = true;

                encryption.cleanup(&this);
                reading.cleanup;
                shutdown(&this, false);
                forceClose(&this);

                RCAllocator alloc = this.allocator;
                alloc.dispose(&this);
            } else if(refCount == 1 && atomicLoad(isAlive)) {
                // we are pinned, but nobody knows about this socket anymore, ugh oh...
                unpin;
            }
        }
    }

    void pin() scope {
        if(atomicLoad(isAlive))
            assert(0, "Pinned");

        rc(true);
        atomicStore(isAlive, true);
    }

    void unpin() scope @trusted {
        if(!atomicLoad(isAlive)) {
            mutex.unlock;
            return;
        }

        mutex.lock.assumeOkay;
        atomicStore(isAlive, false);
        shutdown(&this);
        mutex.unlock;

        rc(false);
    }

    bool haveBeenShutdown() scope {
        return atomicLoad(this.isShutdown);
    }

    package(sidero.eventloop.internal) void unpinGuarded() scope @trusted {
        if(!atomicLoad(isAlive)) {
            return;
        }

        atomicStore(isAlive, false);
        shutdown(&this);

        rc(false);
    }

    void guard(Args...)(scope void delegate(return scope Args) @safe nothrow @nogc del, return scope Args args) scope @trusted {
        mutex.lock.assumeOkay;
        del(args);
        mutex.unlock;
    }

    void close(bool gracefully) scope @trusted {
        mutex.lock.assumeOkay;
        if(!atomicLoad(isAlive)) {
            mutex.unlock;
            return;
        }

        shutdown(&this);
        const inProgress = !rawWriting.inProgress && !rawReading.inProgress;
        mutex.unlock;

        if(!gracefully || inProgress) {
            forceClose(&this);
            atomicStore(isAlive, false);
            rc(false);
        }
    }

    // NOTE: this needs guarding
    void performReadWrite() scope @trusted {
        bool didSomeWork;

        logger.debug_("Starting read/write for ", this.handle, " on ", Thread.self);

        scope(exit) {
            if (this.keepAReadAlwaysGoing)
                this.initiateAConstantlyRunningReadRequest(&this);

            logger.debug_("Done with read/write for ", this.handle, " on ", Thread.self);
        }

        do {
            logger.debug_("Doing read/write for ", this.handle);

            didSomeWork = this.rawReading.tryRead(&this);

            if(this.encryption.enabled && this.encryption.negotiating) {
                didSomeWork = this.encryption.negotiate(&this) || didSomeWork;
            }

            if(!this.encryption.enabled) {
                while(!writing.queue.empty) {
                    auto got = writing.queue.pop;
                    if(got)
                        rawWriting.push(got);
                }
            } else if(this.encryption.enabled && !this.encryption.negotiating) {
                didSomeWork = this.encryption.encryptDecrypt(&this) || didSomeWork;
            }

            didSomeWork = this.rawWriting.tryWrite(&this) || didSomeWork;

            if(!this.encryption.negotiating) {
                didSomeWork = this.reading.tryFulfillRequest(&this) || didSomeWork;
            }
        }
        while(didSomeWork);
    }

    ErrorResult startUp(NetworkAddress address) scope @trusted {
        Socket socket;
        socket.state = &this;
        this.rc(true);
        return connectToSpecificAddress(socket, address);
    }

    package(sidero.eventloop) {
        size_t amountToRead() scope {
            import std.algorithm : max;
            return max(this.encryption.amountOfBytesToRead(), 4096);
        }

        void delayReadForLater() scope {
            assert(0);
        }

        alias readHandle = getHandle;
        alias writeHandle = getHandle;
        void* getHandle() scope @trusted {
            // for some reason it didn't want to be returned
            auto val = cast(void*)this.handle;
            return val;
        }

        // NOTE: this needs guarding
        bool tryWrite(ubyte[] buffer) scope @trusted {
            return tryWriteMechanism(&this, buffer);
        }

        // NOTE: this needs guarding
        bool tryRead(ubyte[] buffer) scope @trusted {
            return tryReadMechanism(&this, buffer);
        }
    }
}
