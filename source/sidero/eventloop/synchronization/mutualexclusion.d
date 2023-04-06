/*

https://en.wikipedia.org/wiki/Eisenberg_%26_McGuire_algorithm
https://en.wikipedia.org/wiki/Szyma%C5%84ski%27s_algorithm
*/
module sidero.eventloop.synchronization.mutualexclusion;
import sidero.eventloop.threads.osthread;
import sidero.base.attributes;
import sidero.base.errors;
import sidero.base.allocators : RCAllocator, globalAllocator, makeArray, dispose;

///
enum {
    ///
    UnknownThreadException = ErrorMessage("UTE", "Unknown thread exception"),
}

/+final class BakerLock : Object.Monitor {
    private {
        RCISharedAllocator allocator;

        shared {
            ThreadID[] threadIds;
            Label[] labels;
            bool[] flags;
        }
    }

    this(RCISharedAllocator allocator, ThreadID[] threads...) {
        this.allocator = allocator;

        threadIds = allocator.makeArray!(shared(ThreadID))(threads);
        labels = allocator.makeArray!(shared(Label))(threads.length);
        flags = allocator.makeArray!(shared(bool))(threads.length);
    }

    this(RCISharedAllocator allocator, Thread[] threads...) {
        this.allocator = allocator;

        threadIds = allocator.makeArray!(shared(ThreadID))(threads.length);
        labels = allocator.makeArray!(shared(Label))(threads.length);
        flags = allocator.makeArray!(shared(bool))(threads.length);

        foreach (i, thread; threads)
            threadIds[i] = thread.id;
    }

    ~this() {
        allocator.dispose(cast(ThreadID[])threadIds);
        allocator.dispose(cast(Label[])labels);
        allocator.dispose(cast(size_t[])flags);
    }

    void lock() {
        import std.algorithm : countUntil;
        import core.atomic : atomicFence, atomicStore, atomicLoad;

        immutable ThreadID tid = Thread.getThis.id;
        ptrdiff_t offset;

        if ((offset = threadIds.countUntil(tid)) < 0)
            throw new UnknownCurrentThreadException("Unknown thread");

        atomicStore(flags[offset], true);

        shared Label maxLabel;
        foreach (i; 0 .. labels.length) {
            atomicFence();
            shared Label temp = labels[i];
            if (maxLabel < temp)
                maxLabel = temp;
        }
        maxLabel++;

        labels[offset] = maxLabel;
        atomicStore(flags[offset], false);

        foreach (i; 0 .. threadIds.length) {
            if (i == offset)
                continue;

            while (atomicLoad(flags[i])) {
                Thread.yield;
            }

            while (labels[i] != Label.init && (labels[i] < labels[offset] || (labels[i] == labels[offset] && i < offset))) {
                Thread.yield;
            }
        }
    }

    bool tryLock() {
        import std.algorithm : countUntil;
        import core.atomic : atomicFence, atomicStore, atomicLoad;

        immutable ThreadID tid = Thread.getThis.id;
        ptrdiff_t offset;

        if ((offset = threadIds.countUntil(tid)) < 0)
            throw new UnknownCurrentThreadException("Unknown thread");

        atomicStore(flags[offset], true);

        shared Label maxLabel;
        foreach (i; 0 .. labels.length) {
            atomicFence();
            shared Label temp = labels[i];
            if (maxLabel < temp)
                maxLabel = temp;
        }
        maxLabel++;

        labels[offset] = maxLabel;
        atomicStore(flags[offset], false);

        foreach (i; 0 .. threadIds.length) {
            if (i == offset)
                continue;

            if (atomicLoad(flags[i])) {
                return false;
            }

            if (labels[i] != Label.init && (labels[i] < labels[offset] || (labels[i] == labels[offset] && i < offset))) {
                return false;
            }
        }

        return true;
    }

    void unlock() {
        import std.algorithm : countUntil;
        import core.atomic : atomicStore;

        immutable ThreadID tid = Thread.getThis.id;
        ptrdiff_t offset;

        if ((offset = threadIds.countUntil(tid)) < 0)
            throw new UnknownCurrentThreadException("Unknown thread");

        atomicStore(flags[offset], false);
    }
}+/

/+final class DekkerLock : Object.Monitor {
    private shared {
        ThreadID[2] threadIds;
        bool[2] flags;
        ThreadID turn;
    }

    this(ThreadID threadOne, ThreadID threadTwo) {
        threadIds[0] = threadOne;
        threadIds[1] = threadTwo;
    }

    this(Thread threadOne, Thread threadTwo) {
        assert(threadOne !is null);
        assert(threadTwo !is null);

        threadIds[0] = threadOne.id;
        threadIds[1] = threadTwo.id;
    }

    void lock() {
        import core.atomic : atomicStore, atomicLoad;

        immutable ThreadID tid = Thread.getThis.id;
        size_t offset, offsetNeg;

        if (threadIds[0] == tid) {
            offsetNeg = 1;
        } else if (threadIds[1] == tid) {
            offset = 1;
        } else {
            throw new UnknownCurrentThreadException("Unknown thread");
        }

        atomicStore(flags[offset], true);

        while (atomicLoad(flags[offsetNeg])) {
            if (atomicLoad(turn) != tid) {
                atomicStore(flags[offset], false);

                while (atomicLoad(turn) != tid) {
                    Thread.yield;
                }

                atomicStore(flags[offset], true);
            }
        }
    }

    bool tryLock() {
        import core.atomic : atomicStore, atomicLoad;

        immutable ThreadID tid = Thread.getThis.id;
        size_t offset, offsetNeg;

        if (threadIds[0] == tid) {
            offsetNeg = 1;
        } else if (threadIds[1] == tid) {
            offset = 1;
        } else {
            throw new UnknownCurrentThreadException("Unknown thread");
        }

        atomicStore(flags[offset], true);

        if (atomicLoad(flags[offsetNeg])) {
            atomicStore(flags[offset], false);
            return false;
        }

        return true;
    }

    void unlock() {
        import core.atomic : atomicStore;

        immutable ThreadID tid = Thread.getThis.id;
        size_t offset, offsetNeg;

        if (threadIds[0] == tid) {
            offsetNeg = 1;
        } else if (threadIds[1] == tid) {
            offset = 1;
        } else {
            throw new UnknownCurrentThreadException("Unknown thread");
        }

        atomicStore(turn, threadIds[offsetNeg]);
        atomicStore(flags[offset], false);
    }
}+/

///
struct BakerLockInline {
    private @PrettyPrintIgnore {
        RCAllocator allocator;

        shared {
            Thread[] threads;
            Label[] labels;
            bool[] flags;
        }
    }

    @disable this(this);

    export @safe nothrow @nogc:

    private:
    static struct Label {
        import sidero.base.datetime : accurateDateTime;

        shared(long[2]) timeOffset;
        int value;

        export @safe nothrow @nogc:

        void opAssign(const Label other) scope shared {
            import core.atomic : atomicLoad, atomicStore;

            atomicStore(timeOffset, other.timeOffset);
            atomicStore(value, atomicLoad(other.value));
        }

        void opUnary(string op)() scope if (op == "++") {
            import core.atomic : atomicOp, atomicLoad, atomicStore;

            if (atomicLoad(value) < 0) {
                atomicStore(value, 1);
                atomicStore(timeOffset, accurateDateTime().pair);
            } else
                atomicOp!"+="(value, 1);
        }

        int opCmp(scope shared Label other) scope shared const {
            import core.atomic : atomicLoad;

            long[2] ourST = atomicLoad(timeOffset);
            long[2] otherST = atomicLoad(other.timeOffset);

            if (ourST == otherST) {
                immutable uint a = value, b = other.value;
                return a > b ? 1 : (a == b ? 0 : -1);
            } else if (ourST > otherST)
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
        ulong currentThreadId;
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
        import core.atomic : atomicStore, atomicLoad;

        Thread self = Thread.self;
        size_t offset, offsetNeg;

        if (threads[0] == self) {
            offsetNeg = 1;
        } else if (threads[1] == self) {
            offset = 1;
        } else {
            return ErrorResult(UnknownThreadException);
        }

        atomicStore(flags[offset], true);
        atomicStore(currentThreadId, self.toHash());

        // if we are the current thread and the other thread has already locked, we wait
        while (atomicLoad(flags[offsetNeg]) && atomicLoad(currentThreadId) == self.toHash()) {
            Thread.yield;
        }

        return ErrorResult.init;
    }

    ///
    Result!bool tryLock() scope {
        import core.atomic : atomicStore, atomicLoad;

        Thread self = Thread.self;
        size_t offset, offsetNeg;

        if (threads[0] == self) {
            offsetNeg = 1;
        } else if (threads[1] == self) {
            offset = 1;
        } else {
            return typeof(return)(UnknownThreadException);
        }

        atomicStore(flags[offset], true);
        atomicStore(currentThreadId, self.toHash());

        if (atomicLoad(flags[offsetNeg]) && atomicLoad(currentThreadId) == self.toHash()) {
            atomicStore(flags[offset], false);
            return typeof(return)(false);
        }

        return typeof(return)(true);
    }

    ///
    ErrorResult unlock() scope {
        import core.atomic : atomicStore;

        Thread self = Thread.self;
        size_t offset;

        if (threads[0] == self) {
        } else if (threads[1] == self) {
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

        foreach (i, thread; threads)
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
        import core.atomic : atomicStore, atomicLoad;

        Thread self = Thread.self;
        ptrdiff_t offset;

        if ((offset = threads.countUntil(self)) < 0)
            return ErrorResult(UnknownThreadException);

        foreach (i; 1 .. threads.length) {
            atomicStore(levels[offset], i);
            atomicStore(lastToEnter[i], self.toHash());

            bool wait, nWait;

            do {
                wait = false;

                foreach (k; 1 .. threads.length) {
                    if (k == offset)
                        continue;

                    if (atomicLoad(levels[k]) >= i && atomicLoad(lastToEnter[i]) == self.toHash()) {
                        wait = true;
                        break;
                    }
                }

                if (wait) {
                    if (nWait)
                        Thread.yield;
                    nWait = true;
                }
            }
            while (wait);
        }

        return ErrorResult.init;
    }

    ///
    Result!bool tryLock() scope {
        import std.algorithm : countUntil;
        import core.atomic : atomicStore, atomicLoad;

        Thread self = Thread.self;
        ptrdiff_t offset;

        if ((offset = threads.countUntil(self)) < 0)
            return typeof(return)(UnknownThreadException);

        foreach (i; 1 .. threads.length) {
            atomicStore(levels[offset], i);
            atomicStore(lastToEnter[i], self.toHash());

            foreach (k; 0 .. threads.length) {
                if (k == offset)
                    continue;

                if (atomicLoad(levels[k]) >= i && atomicLoad(lastToEnter[i]) == self.toHash()) {
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
        import core.atomic : atomicStore;

        Thread self = Thread.self;
        ptrdiff_t offset;

        if ((offset = threads.countUntil(self)) < 0)
            return ErrorResult(UnknownThreadException);

        atomicStore(levels[offset], 0);
        return ErrorResult.init;
    }
}

///
struct TestSetLockInline {
    private @PrettyPrintIgnore shared(bool) state;

    @disable this(this);

export @safe nothrow @nogc:

    /// Non-pure will yield the thread lock
    void lock() scope {
        import core.atomic : cas, atomicLoad;

        while (!cas(&state, false, true)) {
            Thread.yield;
        }
    }

pure:

    /// A much more limited lock method, that is pure.
    void pureLock() scope {
        import core.atomic : cas, atomicFence, atomicLoad;

        if (cas(&state, false, true))
            return;
        else
            atomicFence();

        while (!cas(&state, false, true)) {
            atomicFence();
        }
    }

    ///
    bool tryLock() scope {
        import core.atomic : cas;

        return cas(&state, false, true);
    }

    ///
    void unlock() scope {
        import core.atomic : atomicStore;

        atomicStore(state, false);
    }
}

///
struct TestTestSetLockInline {
    private @PrettyPrintIgnore shared(bool) state;

    @disable this(this);

export @safe nothrow @nogc:

    /// Non-pure will yield the thread lock
    void lock() shared {
        import core.atomic : cas, atomicLoad;

        for (;;) {
            while (atomicLoad(state)) {
                Thread.yield;
            }

            if (cas(&state, false, true))
                return;
        }
    }

pure:

    /// A much more limited lock method, that is pure.
    void pureLock() {
        import core.atomic : cas, atomicFence, atomicLoad;

        for (;;) {
            if (atomicLoad(state))
                atomicFence();

            if (cas(&state, false, true))
                return;
        }
    }

    ///
    bool tryLock() {
        import core.atomic : cas;

        return cas(&state, false, true);
    }

    ///
    void unlock() {
        import core.atomic : atomicStore;

        atomicStore(state, false);
    }
}
