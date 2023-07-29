module sidero.eventloop.coroutine.internal.state;
import sidero.eventloop.coroutine.condition;
import sidero.base.errors;
import sidero.base.allocators;
import sidero.base.internal.atomic;

package(sidero.eventloop.coroutine):

struct CoroutinePair(ResultType) {
    package(sidero.eventloop.coroutine) {
        CoroutineDescriptor!ResultType* descriptor;
        CoroutineState!ResultType* state;
    }

export @safe nothrow @nogc:
    this(scope ref CoroutinePair other) scope {
        this.tupleof = other.tupleof;

        if(!this.isNull)
            rc(true);
    }

    ~this() {
        if(!this.isNull)
            rc(false);
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
        return state !is null && !state.base.conditionToContinue.isNull;
    }

    CoroutineAPair asGeneric() scope @trusted {
        CoroutineAPair ret;

        if(descriptor !is null)
            ret.descriptor = &this.descriptor.base;
        if(state !is null)
            ret.state = &this.state.base;

        return ret;
    }
}

struct CoroutineDescriptor(ResultType) {
    CoroutineAllocatorMemoryDescriptor base;
}

struct CoroutineState(ResultType) {
    CoroutineAllocatorMemoryState base;
    Result!ResultType result;
}

struct ArgsStorage(Args...) {
    Args values;
    alias values this;
}

struct CoroutineAPair {
    CoroutineAllocatorMemoryDescriptor* descriptor;
    CoroutineAllocatorMemoryState* state;

export @safe nothrow @nogc:
    this(return scope ref CoroutineAPair other) scope {
        this.tupleof = other.tupleof;

        if(!this.isNull)
            rc(true);
    }

    ~this() {
        if(!this.isNull)
            rc(false);
    }

    bool isNull() scope const {
        return state is null || descriptor is null;
    }

    void rc(bool add) scope {
        state.rc(add);
        descriptor.rc(add);
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
        return state !is null && !state.conditionToContinue.isNull;
    }
}

struct CoroutineAllocatorMemoryDescriptor {
    alias FunctionPrototype = void function(scope CoroutineAllocatorMemoryDescriptor* descriptor, scope CoroutineAllocatorMemoryState* state) @safe nothrow @nogc;

    CoroutineAllocatorMemory parent;
    alias parent this;

    void*[] userFunctions;
    FunctionPrototype[] functions;

    CoroutineAllocatorMemoryState* function(RCAllocator allocator, void* args) @safe nothrow @nogc createInstanceState;

export @safe nothrow @nogc:

     ~this() {
        parent.allocator.dispose(userFunctions);
        parent.allocator.dispose(functions);
    }
}

struct CoroutineAllocatorMemoryState {
    CoroutineAllocatorMemory parent;
    alias parent this;

    ptrdiff_t nextFunctionTag;
    CoroutineCondition conditionToContinue;

    shared(bool) isComplete;
}

struct CoroutineAllocatorMemory {
    RCAllocator allocator;
    shared(ptrdiff_t) refCount;
    void[] toDeallocate;

    void function(scope void[] memory) @safe nothrow @nogc deinit;

export @safe nothrow @nogc:

    void rc(bool add) scope {
        if(!add && atomicDecrementAndLoad(refCount, 1) == 0) {
            RCAllocator allocator = this.allocator;

            // run destructors ext.
            if(this.deinit !is null)
                this.deinit(toDeallocate);

            allocator.dispose(toDeallocate);
        } else if(add)
            atomicIncrementAndLoad(refCount, 1);
    }
}
