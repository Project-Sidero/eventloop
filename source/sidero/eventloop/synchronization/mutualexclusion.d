/*


*/
module sidero.eventloop.synchronization.mutualexclusion;
import sidero.eventloop.threads.osthread;
public import sidero.base.synchronization.mutualexclusion;
import sidero.base.attributes;
import sidero.base.errors;
import sidero.base.allocators : RCAllocator, globalAllocator, makeArray, dispose;
import sidero.base.internal.atomic;

///
enum {
    ///
    UnknownThreadException = ErrorMessage("UTE", "Unknown thread exception"),
}

///
struct DekkerLockInline {
    private @PrettyPrintIgnore {
        Thread[2] threads;
        shared(bool)[2] flags;
        shared(ulong) turn;
    }

    @disable this(this);

export @safe nothrow @nogc:

    ///
    this(Thread threadOne, Thread threadTwo) scope {
        assert(!threadOne.isNull);
        assert(!threadTwo.isNull);

        threads[0] = threadOne;
        threads[1] = threadTwo;
    }

    ///
    bool isNull() scope const {
        return threads[0].isNull() || threads[1].isNull();
    }

    ///
    ErrorResult lock() scope {
        Thread self = Thread.self;
        size_t offset, offsetNeg;

        if(threads[0] == self) {
            offsetNeg = 1;
        } else if(threads[1] == self) {
            offset = 1;
        } else {
            return ErrorResult(UnknownThreadException);
        }

        atomicStore(flags[offset], true);

        while(atomicLoad(flags[offsetNeg])) {
            if(atomicLoad(turn) != self.toHash()) {
                atomicStore(flags[offset], false);

                while(atomicLoad(turn) != self.toHash()) {
                    Thread.yield;
                }

                atomicStore(flags[offset], true);
            }
        }

        return ErrorResult.init;
    }

    ///
    Result!bool tryLock() scope {
        Thread self = Thread.self;
        size_t offset, offsetNeg;

        if(threads[0] == self) {
            offsetNeg = 1;
        } else if(threads[1] == self) {
            offset = 1;
        } else {
            return typeof(return)(UnknownThreadException);
        }

        atomicStore(flags[offset], true);

        if(atomicLoad(flags[offsetNeg])) {
            atomicStore(flags[offset], false);
            return typeof(return)(false);
        }

        return typeof(return)(true);
    }

    ///
    ErrorResult unlock() scope {
        Thread self = Thread.self;
        size_t offset, offsetNeg;

        if(threads[0] == self) {
            offsetNeg = 1;
        } else if(threads[1] == self) {
            offset = 1;
        } else {
            return ErrorResult(UnknownThreadException);
        }

        atomicStore(turn, threads[offsetNeg].toHash());
        atomicStore(flags[offset], false);

        return ErrorResult.init;
    }
}

///
struct BakerLockInline {
    private @PrettyPrintIgnore {
        RCAllocator allocator;
        Thread[] threads;

        shared {
            Label[] labels;
            bool[] flags;
        }
    }

    @disable this(this);

export @safe nothrow @nogc:

    ///
    this(RCAllocator allocator, scope Thread[] threads...) scope {
        this.allocator = allocator;

        threads = allocator.makeArray!Thread(threads.length);
        labels = allocator.makeArray!(shared(Label))(threads.length);
        flags = allocator.makeArray!(shared(bool))(threads.length);

        foreach(i, thread; threads)
            threads[i] = thread;
    }

    ///
    ~this() scope @trusted {
        if(!allocator.isNull) {
            allocator.dispose(threads);
            allocator.dispose(cast(Label[])labels);
            allocator.dispose(cast(bool[])flags);
        }
    }

    ///
    bool isNull() scope const {
        return allocator.isNull || threads.length == 0;
    }

    ///
    ErrorResult lock() scope {
        import std.algorithm : countUntil;

        Thread self = Thread.self;
        ptrdiff_t offset;

        if((offset = threads.countUntil(self)) < 0)
            return ErrorResult(UnknownThreadException);

        atomicStore(flags[offset], true);

        shared Label maxLabel;
        foreach(i; 0 .. labels.length) {
            atomicFence();
            shared Label temp = labels[i];
            if(maxLabel < temp)
                maxLabel = temp;
        }
        maxLabel++;

        labels[offset] = maxLabel;
        atomicStore(flags[offset], false);

        foreach(i; 0 .. threads.length) {
            if(i == offset)
                continue;

            while(atomicLoad(flags[i])) {
                Thread.yield;
            }

            while(labels[i] != Label.init && (labels[i] < labels[offset] || (labels[i] == labels[offset] && i < offset))) {
                Thread.yield;
            }
        }

        return ErrorResult.init;
    }

    ///
    Result!bool tryLock() scope {
        import std.algorithm : countUntil;

        Thread self = Thread.self;
        ptrdiff_t offset;

        if((offset = threads.countUntil(self)) < 0)
            return typeof(return)(UnknownThreadException);

        atomicStore(flags[offset], true);

        shared Label maxLabel;
        foreach(i; 0 .. labels.length) {
            atomicFence();
            shared Label temp = labels[i];
            if(maxLabel < temp)
                maxLabel = temp;
        }
        maxLabel++;

        labels[offset] = maxLabel;
        atomicStore(flags[offset], false);

        foreach(i; 0 .. threads.length) {
            if(i == offset)
                continue;

            if(atomicLoad(flags[i])) {
                return typeof(return)(false);
            }

            if(labels[i] != Label.init && (labels[i] < labels[offset] || (labels[i] == labels[offset] && i < offset))) {
                return typeof(return)(false);
            }
        }

        return typeof(return)(true);
    }

    ///
    ErrorResult unlock() scope {
        import std.algorithm : countUntil;

        Thread self = Thread.self;
        ptrdiff_t offset;

        if((offset = threads.countUntil(self)) < 0)
            return ErrorResult(UnknownThreadException);

        atomicStore(flags[offset], false);
        return ErrorResult.init;
    }

private:
    static struct Label {
        import sidero.base.datetime : accurateDateTime;

        long[2] timeOffset;
        int value;

    export @safe nothrow @nogc:

        void opAssign(const Label other) scope shared {
            atomicStore(timeOffset, other.timeOffset);
            atomicStore(value, atomicLoad(other.value));
        }

        void opUnary(string op)() scope shared if (op == "++") {
            if(atomicLoad(value) < 0) {
                atomicStore(value, 1);
                atomicStore(timeOffset, accurateDateTime().pair);
            } else
                atomicIncrementAndLoad(value, 1);
        }

        int opCmp(scope shared Label other) scope shared const {
            long[2] ourST = atomicLoad(timeOffset);
            long[2] otherST = atomicLoad(other.timeOffset);

            if(ourST == otherST) {
                immutable uint a = value, b = other.value;
                return a > b ? 1 : (a == b ? 0 : -1);
            } else if(ourST > otherST)
                return 1;
            else
                return -1;
        }

        bool opEquals(scope shared Label other) scope shared const {
            return opCmp(other) == 0;
        }
    }
}

///
struct PetersonLockInline {
    private @PrettyPrintIgnore {
        Thread[2] threads;
        shared(bool)[2] flags;
        shared(ulong) currentThreadId;
    }

    @disable this(this);

export @safe nothrow @nogc:

    ///
    this(Thread threadOne, Thread threadTwo) scope {
        assert(!threadOne.isNull);
        assert(!threadTwo.isNull);

        threads[0] = threadOne;
        threads[1] = threadTwo;
    }

    ///
    bool isNull() scope const {
        return threads[0].isNull() || threads[1].isNull();
    }

    ///
    ErrorResult lock() scope {
        Thread self = Thread.self;
        size_t offset, offsetNeg;

        if(threads[0] == self) {
            offsetNeg = 1;
        } else if(threads[1] == self) {
            offset = 1;
        } else {
            return ErrorResult(UnknownThreadException);
        }

        atomicStore(flags[offset], true);
        atomicStore(currentThreadId, self.toHash());

        // if we are the current thread and the other thread has already locked, we wait
        while(atomicLoad(flags[offsetNeg]) && atomicLoad(currentThreadId) == self.toHash()) {
            Thread.yield;
        }

        return ErrorResult.init;
    }

    ///
    Result!bool tryLock() scope {
        Thread self = Thread.self;
        size_t offset, offsetNeg;

        if(threads[0] == self) {
            offsetNeg = 1;
        } else if(threads[1] == self) {
            offset = 1;
        } else {
            return typeof(return)(UnknownThreadException);
        }

        atomicStore(flags[offset], true);
        atomicStore(currentThreadId, self.toHash());

        if(atomicLoad(flags[offsetNeg]) && atomicLoad(currentThreadId) == self.toHash()) {
            atomicStore(flags[offset], false);
            return typeof(return)(false);
        }

        return typeof(return)(true);
    }

    ///
    ErrorResult unlock() scope {
        Thread self = Thread.self;
        size_t offset;

        if(threads[0] == self) {
        } else if(threads[1] == self) {
            offset = 1;
        } else {
            return ErrorResult(UnknownThreadException);
        }

        atomicStore(flags[offset], false);
        return ErrorResult.init;
    }
}

///
struct PetersonFilterLockInline {
    private @PrettyPrintIgnore {
        RCAllocator allocator;
        Thread[] threads;
        shared(ulong)[] lastToEnter;
        shared(size_t)[] levels;
    }

    @disable this(this);

export @safe nothrow @nogc:

    ///
    this(return scope RCAllocator allocator, scope Thread[] threads...) scope {
        this.allocator = allocator;

        threads = allocator.makeArray!(Thread)(threads.length);
        lastToEnter = allocator.makeArray!(shared(ulong))(threads.length);
        levels = allocator.makeArray!(shared(size_t))(threads.length);

        foreach(i, thread; threads)
            threads[i] = thread;
    }

    ///
    ~this() scope @trusted {
        allocator.dispose(threads);
        allocator.dispose(lastToEnter);
        allocator.dispose(cast(size_t[])levels);
    }

    ///
    bool isNull() scope const {
        return allocator.isNull;
    }

    ///
    ErrorResult lock() scope {
        import std.algorithm : countUntil;

        Thread self = Thread.self;
        ptrdiff_t offset;

        if((offset = threads.countUntil(self)) < 0)
            return ErrorResult(UnknownThreadException);

        foreach(i; 1 .. threads.length) {
            atomicStore(levels[offset], i);
            atomicStore(lastToEnter[i], self.toHash());

            bool wait, nWait;

            do {
                wait = false;

                foreach(k; 1 .. threads.length) {
                    if(k == offset)
                        continue;

                    if(atomicLoad(levels[k]) >= i && atomicLoad(lastToEnter[i]) == self.toHash()) {
                        wait = true;
                        break;
                    }
                }

                if(wait) {
                    if(nWait)
                        Thread.yield;
                    nWait = true;
                }
            }
            while(wait);
        }

        return ErrorResult.init;
    }

    ///
    Result!bool tryLock() scope {
        import std.algorithm : countUntil;

        Thread self = Thread.self;
        ptrdiff_t offset;

        if((offset = threads.countUntil(self)) < 0)
            return typeof(return)(UnknownThreadException);

        foreach(i; 1 .. threads.length) {
            atomicStore(levels[offset], i);
            atomicStore(lastToEnter[i], self.toHash());

            foreach(k; 0 .. threads.length) {
                if(k == offset)
                    continue;

                if(atomicLoad(levels[k]) >= i && atomicLoad(lastToEnter[i]) == self.toHash()) {
                    atomicStore(levels[offset], 0);
                    return typeof(return)(false);
                }
            }
        }

        return typeof(return)(true);
    }

    ///
    ErrorResult unlock() scope {
        import std.algorithm : countUntil;
        import sidero.base.internal.atomic : atomicStore;

        Thread self = Thread.self;
        ptrdiff_t offset;

        if((offset = threads.countUntil(self)) < 0)
            return ErrorResult(UnknownThreadException);

        atomicStore(levels[offset], 0);
        return ErrorResult.init;
    }
}
