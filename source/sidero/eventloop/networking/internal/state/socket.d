module sidero.eventloop.networking.internal.state.socket;
import sidero.eventloop.networking.internal.state.defs;
import sidero.eventloop.networking.internal.state.reading;
import sidero.eventloop.networking.internal.state.writing;
import sidero.eventloop.networking.internal.state.encryption;
import sidero.eventloop.networking.internal.state.rawreading;
import sidero.eventloop.networking.internal.state.rawwriting;
import sidero.eventloop.networking.internal.platform;
import sidero.eventloop.networking.sockets;
import sidero.eventloop.synchronization.system.lock;
import sidero.base.allocators;
import sidero.base.path.networking;
import sidero.base.internal.atomic;
import sidero.base.errors;

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

    ReadingState reading;
    WritingState writing;
    EncryptionState encryption;
    RawReadingState rawReading;
    RawWritingState rawWriting;

    PlatformSocket platform;
    alias platform this;

@safe nothrow @nogc:

    this(return scope RCAllocator allocator, Socket.Protocol protocol, bool cameFromServer) scope {
        checkInit;
        this.allocator = allocator;
        this.refCount = 1;
        this.protocol = protocol;
        this.cameFromServer = cameFromServer;
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
        mutex.lock.assumeOkay;
        if(!atomicLoad(isAlive)) {
            mutex.unlock;
            return;
        }

        atomicStore(isAlive, false);
        shutdown(&this);
        mutex.unlock;

        rc(false);
    }

    bool haveBeenShutdown() scope {
        return atomicLoad(this.isShutdown);
    }

    package(sidero.eventloop.networking.internal) void unpinGuarded() scope @trusted {
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

        do {
            didSomeWork = this.rawReading.tryRead(&this);

            if(this.encryption.enabled && this.encryption.negotiating) {
                didSomeWork = this.encryption.negotiate(&this) || didSomeWork;
            }

            if(!this.encryption.enabled) {
                while(!writing.queue.empty) {
                    auto got = writing.queue.pop;
                    if(got)
                        rawWriting.queue.push(got);
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

    ErrorResult startUp(NetworkAddress address, bool keepAlive = true) scope @trusted {
        Socket socket;
        socket.state = &this;
        this.rc(true);
        return connectToSpecificAddress(socket, address, keepAlive);
    }

    package(sidero.eventloop.networking.internal) {
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
