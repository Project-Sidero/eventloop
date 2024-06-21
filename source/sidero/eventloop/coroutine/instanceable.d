module sidero.eventloop.coroutine.instanceable;
import sidero.eventloop.coroutine.internal.state;
import sidero.eventloop.coroutine.future;
import sidero.eventloop.coroutine.condition;
import sidero.eventloop.coroutine.generic;
import sidero.base.errors;
import sidero.base.allocators;
import sidero.base.datetime.duration;
import sidero.base.internal.atomic;

///
struct InstanceableCoroutine(ResultType, Args...) {
    package(sidero.eventloop) {
        CoroutinePair!ResultType pair;
        ConstructionAStateWrapper constructionState;
    }

export @safe nothrow @nogc:

    ///
    this(return scope ref InstanceableCoroutine other) scope {
        this.tupleof = other.tupleof;
        pair.rc(true);
        constructionState.rc(true);
    }

    ///
    ~this() scope {
        pair.rc(false);
        constructionState.rc(false);
    }

    void opAssign(return scope InstanceableCoroutine other) scope {
        this.destroy;
        this.__ctor(other);
    }

    ///
    bool isNull() scope const {
        return pair.isNull;
    }

    ///
    bool canInstance() scope const {
        return pair.canInstance();
    }

    ///
    InstanceableCoroutine!ResultType makeInstance(return scope RCAllocator allocator, return scope Args args) scope @trusted {
        if (!pair.canInstance)
            return typeof(return).init;

        if (allocator.isNull)
            allocator = globalAllocator();

        ArgsStorage!Args argsStorage;
        argsStorage.values = args;

        InstanceableCoroutine!ResultType ret;
        ret.pair.descriptor = this.pair.descriptor;

        if (this.constructionState.isNull) {
            ret.pair.state = cast(CoroutineState!ResultType*)this.pair.descriptor.base.createInstanceState(allocator,
                    cast(void*)&argsStorage);
        } else {
            ret.pair.state = cast(CoroutineState!ResultType*)constructionState.state.createInstanceState(
                    (void* actualArgsStorage) @trusted {
                return ret.pair.descriptor.base.createInstanceState(allocator, cast(void*)&actualArgsStorage);
            }, cast(void*)&argsStorage);
        }

        ret.pair.rc(true);
        return ret;
    }

    /// Partial providing for arguments to coroutine
    InstanceableCoroutine!(ResultType, Args[PartialArgs.length .. $]) partial(PartialArgs...)(return scope RCAllocator allocator,
            return scope PartialArgs partialArgs) {
        if (!pair.canInstance)
            return typeof(return).init;

        if (allocator.isNull)
            allocator = globalAllocator();

        InstanceableCoroutine!(ResultType, Args[PartialArgs.length .. $]) ret;
        alias ActualPartialArgs = Args[0 .. PartialArgs.length];

        ConstructionState!ActualPartialArgs* cstate;
        cstate = allocator.make!(ConstructionState!ActualPartialArgs);
        cstate.allocator = allocator;

        cstate.deinit = (ConstructionState!ActualPartialArgs* state) {
            RCAllocator allocator = state.allocator;
            allocator.dispose(state);
        };
        cstate.createInstanceState = &cstate.createInstanceStateImpl!(Args[PartialArgs.length .. $]);
        cstate.next = this.constructionState;

        static foreach (size_t ArgI; 0 .. PartialArgs.length) {
            cstate.argsStorage.values[ArgI] = partialArgs[ArgI];
        }

        ret.constructionState.state = cast(ConstructionAState*)cstate;
        ret.pair.descriptor = this.pair.descriptor;

        ret.pair.rc(true);
        cstate.rc(true);
        return ret;
    }

    ///
    bool isComplete() scope {
        return this.isNull() || pair.isComplete();
    }

    ///
    CoroutineCondition condition() scope {
        if (pair.isWaiting)
            return pair.state.base.conditionToContinue;
        else
            return typeof(return).init;
    }

    ///
    Future!ResultType asFuture() return scope @trusted {
        Future!ResultType ret;
        ret.pair = this.pair;
        ret.pair.rc(true);
        return ret;
    }

    ///
    GenericCoroutine asGeneric() return scope {
        GenericCoroutine ret;
        ret.pair = this.pair.asGeneric();
        ret.pair.rc(true);
        return ret;
    }

    ///
    Result!ResultType result() {
        if (isNull)
            return typeof(return)(NullPointerException("Coroutine not instantiated"));
        return this.pair.state.result;
    }

    /// Execute the coroutine step by step. Warning: you must handle condition to continue prior.
    ErrorResult unsafeResume() scope @system {
        return pair.resume;
    }

    /**
        Blocks until coroutine is complete or timeout elapses.

        Warning: you must not be a worker/event waiting thread.

        May return early, check for if it actually is complete.
    */
    void blockUntilComplete(Duration timeout = Duration.max) scope @system {
        if (isNull)
            return;
        pair.blockUntilComplete(timeout);
    }

    @disable auto opCast(T)();

    ///
    ulong toHash() scope const @trusted {
        import sidero.base.hash.utils : hashOf;

        const b = cast(size_t)pair.state, a = cast(size_t)pair.descriptor;
        return hashOf(b, hashOf(a));
    }

    ///
    alias equals = opEquals;

    ///
    bool opEquals(scope InstanceableCoroutine other) scope const {
        return this.toHash() == other.toHash();
    }

    ///
    alias compare = opCmp;

    ///
    int opCmp(scope InstanceableCoroutine other) scope const @trusted {
        const a = this.toHash(), b = other.toHash();

        if (a < b)
            return -1;
        else if (a > b)
            return 1;
        else
            return 0;
    }
}

private:

struct ConstructionAStateWrapper {
    ConstructionAState* state;

export @safe nothrow @nogc:

    this(scope return ref ConstructionAStateWrapper other) scope {
        this.tupleof = other.tupleof;
    }

    ~this() scope {
    }

    void opAssign(return scope ConstructionAStateWrapper other) scope {
        this.destroy;
        this.__ctor(other);
    }

    void rc(bool addRef) scope {
        if (state is null)
            return;
        else if (addRef)
            atomicIncrementAndLoad(state.refCount, 1);
        else if (atomicDecrementAndLoad(state.refCount, 1) == 0) {
            state.deinit(state);
            auto allocator = state.allocator;
            allocator.dispose(state);
        }
    }

    bool isNull() scope {
        return state is null;
    }
}

alias PerformAllocDelegate = CoroutineAllocatorMemoryState* delegate(void* args) @safe nothrow @nogc;

struct ConstructionAState {
    shared(ptrdiff_t) refCount;
    RCAllocator allocator;

    ConstructionAStateWrapper next;

    void function(scope ConstructionAState*) @safe nothrow @nogc deinit;
    CoroutineAllocatorMemoryState* function(scope PerformAllocDelegate, void* args) @safe nothrow @nogc createInstanceState;
}

struct ConstructionState(HidingNArgs...) {
    shared(ptrdiff_t) refCount;
    RCAllocator allocator;

    ConstructionAStateWrapper next;

    void function(ConstructionState*) @safe nothrow @nogc deinit;
    CoroutineAllocatorMemoryState* function(scope PerformAllocDelegate, void* args) @safe nothrow @nogc createInstanceState;

    ArgsStorage!HidingNArgs argsStorage;

export @safe nothrow @nogc:

    static CoroutineAllocatorMemoryState* createInstanceStateImpl(ExposedNArgs...)(scope PerformAllocDelegate del, void* args) scope @trusted {
        ArgsStorage!ExposedNArgs inputStorage = cast(ArgsStorage!ExposedNArgs*)args;
        ArgsStorage!(HidingNArgs, ExposedNArgs) tempStorage;

        tempStorage.values[0 .. HidingNArgs.length] = argsStorage.values;
        tempStorage.values[HidingNArgs.length .. $] = inputStorage.values;

        if (next.isNull) {
            return del(cast(void*)&tempStorage);
        } else {
            return this.next.state.createInstanceState(del, cast(void*)&tempStorage);
        }
    }
}
