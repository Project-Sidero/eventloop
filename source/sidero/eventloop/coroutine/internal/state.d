module sidero.eventloop.coroutine.internal.state;
import sidero.eventloop.coroutine.condition;
import sidero.base.errors;
import sidero.base.allocators;
import sidero.base.synchronization.system.point;
import sidero.base.datetime.duration;
import sidero.base.internal.atomic;
import sidero.base.internal.logassert;

package(sidero.eventloop):

CoroutinePair!ResultType ctfeConstructExternalTriggerState(ResultType)(return scope CoroutineDescriptor!ResultType* descriptorStorage,
        return scope ref CoroutineAllocatorMemoryDescriptor.FunctionPrototype[1] functionsStorage) {
    CoroutinePair!ResultType pair;
    pair.descriptor = descriptorStorage;

    alias CoroutineState2 = CoroutineState!ResultType;

    pair.descriptor.base.createInstanceState = (RCAllocator allocator, void* args) @trusted nothrow @nogc {
        CoroutineState2* ret = allocator.make!CoroutineState2;

        ret.base.allocator = allocator;
        ret.base.toDeallocate = (cast(void*)ret)[0 .. CoroutineState2.sizeof];
        ret.base.deinit = (scope void[] memory) @trusted nothrow @nogc {
            CoroutineState2* state = cast(CoroutineState2*)memory.ptr;
            (*state).destroy;
        };

        auto arg = *cast(Result!ResultType***)args;
        *arg = &ret.result;

        ret.base.conditionToContinue.isExternalTrigger = true;
        return &ret.base;
    };

    pair.descriptor.base.setErrorResult = (scope CoroutineAllocatorMemoryState* state, ErrorInfo errorInfo) @trusted nothrow @nogc {
        CoroutineState2* actualState = cast(CoroutineState2*)state;
        actualState.base.conditionToContinue = CoroutineCondition.init;
        actualState.result = Result!ResultType(errorInfo.info, errorInfo.moduleName, errorInfo.line);

        actualState.base.nextFunctionTag = -2;
        actualState.base.setAsComplete();
    };

    pair.descriptor.base.functions = functionsStorage[];
    pair.descriptor.base.functions[0] = (scope CoroutineAllocatorMemoryDescriptor* descriptor,
            scope CoroutineAllocatorMemoryState* state) @trusted nothrow @nogc {
        CoroutineState2* actualState = cast(CoroutineState2*)state;
        actualState.base.conditionToContinue = CoroutineCondition.init;

        actualState.base.nextFunctionTag = -1;
        actualState.base.setAsComplete();
    };

    return pair;
}

package(sidero.eventloop.coroutine):

struct CoroutinePair(ResultType) {
    package(sidero.eventloop.coroutine) {
        CoroutineDescriptor!ResultType* descriptor;
        CoroutineState!ResultType* state;
    }

export @safe nothrow @nogc:
    this(scope ref CoroutinePair other) scope {
        this.tupleof = other.tupleof;
    }

    ~this() scope {
    }

    bool isNull() scope const {
        return state is null || descriptor is null;
    }

    void rc(bool add) scope {
        if(state !is null)
            state.base.rc(add);
        if(descriptor !is null)
            descriptor.base.rc(add);
    }

    ErrorResult resume() scope {
        if(state.base.nextFunctionTag < 0)
            return ErrorResult(MalformedInputException("Coroutine instance has completed"));
        if(state.base.nextFunctionTag >= descriptor.base.functions.length)
            return ErrorResult(MalformedInputException("Coroutine instance is in invalid state"));
        descriptor.base.functions[state.base.nextFunctionTag](&descriptor.base, &state.base);
        return ErrorResult.init;
    }

    bool isComplete() scope const {
        return this.isNull() || atomicLoad(state.base.isComplete);
    }

    bool canInstance() scope const {
        return descriptor !is null;
    }

    bool isWaiting() scope const {
        return state !is null && state.base.conditionToContinue.waitingOn != CoroutineCondition.WaitingOn.Nothing;
    }

    CoroutineAPair asGeneric() scope @trusted {
        CoroutineAPair ret;

        if(descriptor !is null)
            ret.descriptor = &this.descriptor.base;
        if(state !is null)
            ret.state = &this.state.base;

        return ret;
    }

    void blockUntilCompleteOrHaveValue(Duration timeout) scope @trusted {
        if(state is null)
            return;

        auto err = state.base.completionSynchronization.lock;
        logAssert(cast(bool)err, "Failed to lock", err.getError);

        if(!atomicLoad(state.base.isComplete)) {
            // we don't actually care what the return is
            cast(void)state.base.completionSynchronization.waitForCondition(timeout);
        }

        state.base.completionSynchronization.unlock;
    }
}

package(sidero.eventloop) struct CoroutineDescriptor(ResultType) {
    CoroutineAllocatorMemoryDescriptor base;
}

struct CoroutineState(ResultType) {
    CoroutineAllocatorMemoryState base;
    Result!ResultType result;
}

struct ArgsStorage(Args...) {
    Args values;
    alias values this;

    this(ref return scope ArgsStorage other) scope @trusted {
        this.tupleof = other.tupleof;
    }
}

struct CoroutineAPair {
    CoroutineAllocatorMemoryDescriptor* descriptor;
    CoroutineAllocatorMemoryState* state;

export @safe nothrow @nogc:
    this(return scope ref CoroutineAPair other) scope {
        this.tupleof = other.tupleof;
    }

    ~this() scope {
    }

    bool isNull() scope const {
        return state is null || descriptor is null;
    }

    void rc(bool add) scope @trusted {
        if(state !is null) {
            if(!state.rc(add))
                state = null;
        }
        if(descriptor !is null) {
            if(!descriptor.rc(add))
                descriptor = null;
        }
    }

    ErrorResult resume() scope {
        if(state.nextFunctionTag < 0)
            return ErrorResult(MalformedInputException("Coroutine instance has completed"));
        if(state.nextFunctionTag >= descriptor.functions.length)
            return ErrorResult(MalformedInputException("Coroutine instance is in invalid state"));
        descriptor.functions[state.nextFunctionTag](descriptor, state);
        return ErrorResult.init;
    }

    bool isComplete() scope {
        return this.isNull() || atomicLoad(state.isComplete);
    }

    bool canInstance() scope {
        return descriptor !is null;
    }

    bool isWaiting() scope {
        return state !is null && state.conditionToContinue.waitingOn != CoroutineCondition.WaitingOn.Nothing;
    }

    void blockUntilCompleteOrHaveValue(Duration timeout) scope @trusted {
        if(state is null)
            return;

        auto err = state.completionSynchronization.lock;
        logAssert(cast(bool)err, "Failed to lock", err.getError);

        if(!atomicLoad(state.isComplete)) {
            // we don't actually care what the return is
            cast(void)state.completionSynchronization.waitForCondition(timeout);
        }

        state.completionSynchronization.unlock;
    }
}

package(sidero.eventloop) struct CoroutineAllocatorMemoryDescriptor {
    alias FunctionPrototype = void function(scope CoroutineAllocatorMemoryDescriptor* descriptor, scope CoroutineAllocatorMemoryState* state) @safe nothrow @nogc;
    CoroutineAllocatorMemory parent;
    alias parent this;

    void*[] userFunctions;
    FunctionPrototype[] functions;

    CoroutineAllocatorMemoryState* function(RCAllocator allocator, void* args) @safe nothrow @nogc createInstanceState;
    void function(scope CoroutineAllocatorMemoryState* state, ErrorInfo errorInfo) @safe nothrow @nogc setErrorResult;

export @safe nothrow @nogc:

     ~this() {
        if(!parent.allocator.isNull) {
            parent.allocator.dispose(userFunctions);
            parent.allocator.dispose(functions);
        }
    }

    ulong toHash() const {
        return 0;
    }

    bool opEquals(scope ref CoroutineAllocatorMemoryDescriptor other) const {
        return false;
    }
}

struct CoroutineAllocatorMemoryState {
    CoroutineAllocatorMemory parent;
    alias parent this;

    ptrdiff_t nextFunctionTag;
    CoroutineCondition conditionToContinue;

    SynchronizationPoint completionSynchronization;

    shared(bool) isComplete;

export @safe nothrow @nogc:

    void setAsComplete() scope @trusted {
        auto err = completionSynchronization.lock;
        logAssert(cast(bool)err, "Failed to lock", err.getError);

        atomicStore(isComplete, true);
        completionSynchronization.unlock;

        completionSynchronization.triggerCondition;
    }

    ulong toHash() const {
        return 0;
    }

    bool opEquals(scope ref CoroutineAllocatorMemoryState other) const {
        return false;
    }
}

struct CoroutineAllocatorMemory {
    RCAllocator allocator;
    shared(ptrdiff_t) refCount;
    void[] toDeallocate;

    void function(scope void[] memory) @safe nothrow @nogc deinit;

export @safe nothrow @nogc:

    bool rc(bool add) scope @trusted {
        if(add) {
            atomicIncrementAndLoad(refCount, 1);
        } else if(atomicDecrementAndLoad(refCount, 1) == 0) {
            RCAllocator allocator = this.allocator;
            if(allocator.isNull)
                return false;

            void[] toDeallocate = toDeallocate;

            // run destructors ext.
            if(this.deinit !is null)
                this.deinit(toDeallocate);

            allocator.dispose(toDeallocate);
            return false;
        }

        return true;
    }
}
