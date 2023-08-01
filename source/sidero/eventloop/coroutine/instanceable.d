module sidero.eventloop.coroutine.instanceable;
import sidero.eventloop.coroutine.internal.state;
import sidero.eventloop.coroutine.future;
import sidero.eventloop.coroutine.condition;
import sidero.eventloop.coroutine.generic;
import sidero.base.errors;
import sidero.base.allocators;
import sidero.base.internal.atomic;

///
struct InstantiableCoroutine(ResultType, Args...) {
    package(sidero.eventloop) {
        CoroutinePair!ResultType pair;
        ConstructionAStateWrapper constructionState;
    }

export @safe nothrow @nogc:

    ///
    this(scope ref InstantiableCoroutine other) scope {
        this.tupleof = other.tupleof;
    }

    ///
    ~this() scope {
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
    InstantiableCoroutine!ResultType makeInstance(return scope RCAllocator allocator, return scope Args args) scope @trusted {
        if(!pair.canInstance)
            return typeof(return).init;

        if(allocator.isNull)
            allocator = globalAllocator();

        ArgsStorage!Args argsStorage;
        argsStorage.values = args;

        InstantiableCoroutine!ResultType ret;

        if(this.constructionState.isNull) {
            ret.pair.state = cast(CoroutineState!ResultType*)this.pair.descriptor.base.createInstanceState(allocator,
                    cast(void*)&argsStorage);
        } else {
            ret.pair.state = cast(CoroutineState!ResultType*)constructionState.state.createInstanceState(
                    (void* actualArgsStorage) @trusted {
                return ret.pair.descriptor.base.createInstanceState(allocator, cast(void*)&actualArgsStorage);
            }, cast(void*)&argsStorage);
        }

        ret.pair.descriptor = this.pair.descriptor;
        ret.pair.rc(true);
        return ret;
    }

    /// Partial providing for arguments to coroutine
    InstantiableCoroutine!(ResultType, Args[PartialArgs.length .. $]) partial(PartialArgs...)(return scope RCAllocator allocator,
            return scope PartialArgs partialArgs) {
        if(!pair.canInstance)
            return typeof(return).init;

        if(allocator.isNull)
            allocator = globalAllocator();

        InstantiableCoroutine!(ResultType, Args[PartialArgs.length .. $]) ret;
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

        static foreach(size_t ArgI; 0 .. PartialArgs.length) {
            cstate.argsStorage.values[ArgI] = partialArgs[ArgI];
        }

        ret.constructionState.state = cast(ConstructionAState*)cstate;
        ret.pair.descriptor = this.pair.descriptor;
        ret.pair.rc(true);
        return ret;
    }

    ///
    bool isComplete() scope {
        return this.isNull() || pair.isComplete();
    }

    ///
    CoroutineCondition condition() scope {
        if(pair.isWaiting)
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
        if(isNull)
            return typeof(return)(NullPointerException("Coroutine not instantiated"));
        return this.pair.state.result;
    }

    /// Execute the coroutine step by step. Warning: you must handle condition to continue prior.
    ErrorResult unsafeResume() scope @system {
        return pair.resume;
    }
}

private:

struct ConstructionAStateWrapper {
    ConstructionAState* state;

export @safe nothrow @nogc:

    this(scope return ref ConstructionAStateWrapper other) scope {
        this.state = other.state;

        if(state !is null)
            atomicIncrementAndLoad(state.refCount, 1);
    }

    ~this() scope @trusted {
        if(state !is null && atomicDecrementAndLoad(state.refCount, 1) == 0) {
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
    shared(ptrdiff_t) refCount = 1;
    RCAllocator allocator;

    ConstructionAStateWrapper next;

    void function(scope ConstructionAState*) @safe nothrow @nogc deinit;
    CoroutineAllocatorMemoryState* function(scope PerformAllocDelegate, void* args) @safe nothrow @nogc createInstanceState;
}

struct ConstructionState(HidingNArgs...) {
    shared(ptrdiff_t) refCount = 1;
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

        if(next.isNull) {
            return del(cast(void*)&tempStorage);
        } else {
            return this.next.state.createInstanceState(del, cast(void*)&tempStorage);
        }
    }
}
