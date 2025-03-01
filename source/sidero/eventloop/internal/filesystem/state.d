module sidero.eventloop.internal.filesystem.state;
import sidero.eventloop.internal.filesystem.defs;
import sidero.eventloop.internal.filesystem.platform;
import sidero.eventloop.internal.pipes.reading;
import sidero.eventloop.internal.pipes.rawreading;
import sidero.eventloop.internal.pipes.rawwriting;
import sidero.eventloop.filesystem.file;
import sidero.eventloop.threads;
import sidero.base.synchronization.system.lock;
import sidero.base.allocators;
import sidero.base.path.file;
import sidero.base.internal.atomic;
import sidero.base.errors;
import sidero.base.logger;

struct FileState {
    private {
        SystemLock mutex;
        RCAllocator allocator;

        shared(ptrdiff_t) refCount;
        shared(ptrdiff_t) refCountExtra;
    }

    shared(bool) isAlive;
    shared(bool) isClosed;

    enum attemptReadLater = false;
    size_t amountToReadSuggestion;

    FilePath filePath;
    FileRights fileRights;

    ReadingState!(FileState, "file", false) reading;
    RawReadingState!(FileState, "file") rawReading;
    RawWritingState!(FileState, "file") rawWriting;

    long currentReadPosition, requestedReadPosition;
    long currentWritePosition;
    bool noUpdateReadPosition; // set to true to have buffers cleared on next read

    PlatformFile platform;
    alias platform this;

@safe nothrow @nogc:

    this(return scope RCAllocator allocator, FilePath filePath, FileRights fileRights, ulong estimatedSize) scope {
        import sidero.base.internal.logassert;

        checkInit;

        this.allocator = allocator;
        this.refCount = 1;
        this.refCountExtra = 0;

        this.filePath = filePath;
        this.fileRights = fileRights;

        logAssert(reading.initialize, "Could not initialize reading for file");
        logAssert(rawReading.initialize, "Could not initialize raw reading for file");

        if(fileRights.write || fileRights.forceAppend)
            logAssert(rawWriting.initialize, "Could not initialize raw writing for file");

        // We do not need to consider if we created the file,
        //  you wouldn't be reading it back using this file interface if you did.
        // The default 16kb is perfactly good for that scenario.

        if(estimatedSize >= 8 * 1024 * 1024)
            this.amountToReadSuggestion = 256 * 1024; // 256kb is how much gets mapped into the kernel
        else if(estimatedSize >= 1024 * 1024) // for small image files
            this.amountToReadSuggestion = 128 * 1024; // 1/2 of what gets mapped into the kernel
        else if(estimatedSize >= 64 * 1024) // for smallish files like configuration
            this.amountToReadSuggestion = 64 * 1024; // 1/4th of what gets mapped into the kernel
        else
            this.amountToReadSuggestion = 4 * 1024; // Don't try to read too much in, we may end up seeking and clear out buffers.
    }

    ~this() scope {
    }

    void rc(bool addRef) scope @trusted {
        if(addRef)
            atomicIncrementAndLoad(refCount, 1);
        else {
            ptrdiff_t refCount = atomicDecrementAndLoad(this.refCount, 1);

            if(refCount == 0) {
                forceClose(&this);
                reading.cleanup(&this);

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
        bool wasAlive = cas(isAlive, true, false);
        mutex.unlock;

        if(wasAlive)
            rc(false);
    }

    void pinExtra() scope {
        if(atomicIncrementAndLoad(this.refCountExtra, 1) == 1) {
            this.rc(true);
        }
    }

    void unpinExtra() scope {
        if(atomicDecrementAndLoad(this.refCountExtra, 1) == 0) {
            this.rc(false);
        }
    }

    package(sidero.eventloop.internal) void unpinGuarded() scope @trusted {
        bool wasAlive = cas(isAlive, true, false);

        if(wasAlive)
            rc(false);
    }

    ReturnType guard(ReturnType, Args...)(scope ReturnType delegate(return scope Args) @safe nothrow @nogc del, return scope Args args) scope @trusted {
        static if(is(ReturnType == void)) {
            mutex.lock.assumeOkay;
            del(args);
            mutex.unlock;
        } else {
            mutex.lock.assumeOkay;
            ReturnType ret = del(args);
            mutex.unlock;
            return ret;
        }
    }

    void close() scope @trusted {
        mutex.lock.assumeOkay;
        if(!atomicLoad(isAlive)) {
            mutex.unlock;
            return;
        }

        const inProgress = !rawWriting.inProgress && !rawReading.inProgress;
        mutex.unlock;

        if(inProgress) {
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
            if(this.keepAReadAlwaysGoing)
                this.initiateAConstantlyRunningReadRequest(&this);

            logger.debug_("Done with read/write for ", this.handle, " on ", Thread.self);
        }

        do {
            logger.debug_("Doing read/write for ", this.handle);

            didSomeWork = this.reading.tryFulfillRequest(&this);
            didSomeWork = this.rawReading.tryRead(&this) || didSomeWork;
            didSomeWork = this.rawWriting.tryWrite(&this) || didSomeWork;
            didSomeWork = this.reading.tryFulfillRequest(&this) || didSomeWork;
        }
        while(didSomeWork);
    }

    package(sidero.eventloop) {
        size_t amountToRead() scope {
            import sidero.base.algorithm : max;

            return max(this.reading.wantedAmount, this.amountToReadSuggestion);
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
        bool tryWrite(ubyte[] buffer, ulong position) scope @trusted {
            return tryWriteMechanism(&this, buffer, position);
        }

        // NOTE: this needs guarding
        bool tryRead(ubyte[] buffer) scope @trusted {
            return tryReadMechanism(&this, buffer, requestedReadPosition);
        }
    }
}
