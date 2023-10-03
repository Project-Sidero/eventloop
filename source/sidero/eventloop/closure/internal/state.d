module sidero.eventloop.closure.internal.state;
import sidero.base.allocators;
import sidero.base.errors;

package(sidero.eventloop.closure):

struct ClosureDescriptor {
    shared(ptrdiff_t) refCount;
    RCAllocator allocator;

    void[] toDeallocate;

    void function(void[] toDeallocate) @safe nothrow @nogc deinit;

export @safe nothrow @nogc:

    void rc(bool add) scope @trusted {
        import sidero.base.internal.atomic;

        if(add)
            atomicIncrementAndLoad(this.refCount, 1);
        else if(atomicDecrementAndLoad(this.refCount, 1) == 0) {
            if(this.deinit !is null)
                this.deinit(toDeallocate);

            RCAllocator allocator = this.allocator;
            allocator.dispose(toDeallocate);
        }
    }
}

struct ClosureTypedDescriptor(ReturnType, Args...) {
    ClosureDescriptor* untyped;
    alias untyped this;

    Result!ReturnType delegate(void*, Args) @safe nothrow @nogc typedToCall;
}

struct ClosureGenericDescriptor {
    ClosureDescriptor* untyped;
    alias untyped this;

    void delegate() typedToCall;
    ErrorResult function(void*, void delegate() typedToCall) @safe nothrow @nogc untypedToCall;
}

struct ClosureArgsStorage(Args...) {
    Args values;
    alias values this;

    this(ref return scope ClosureArgsStorage other) scope @trusted {
        this.tupleof = other.tupleof;
    }
}

struct ClosureGenericPartialWrapper {
    CPS* state;
    ErrorResult delegate(void* storage, void delegate() partialTypedToCall, void delegate() realTypedToCall) @safe nothrow @nogc untypedToCall;
    void delegate() partialTypedToCall;

export @safe nothrow @nogc:

    this(scope return ref ClosureGenericPartialWrapper other) scope {
        import sidero.base.internal.atomic;

        this.tupleof = other.tupleof;

        if(state !is null)
            atomicIncrementAndLoad(state.refCount, 1);
    }

    ~this() scope @trusted {
        import sidero.base.internal.atomic;

        if(state !is null && atomicDecrementAndLoad(state.refCount, 1) == 0) {
            state.deinit(state);
            auto allocator = state.allocator;
            allocator.dispose(state);
        }
    }

    bool isNull() scope {
        return state is null;
    }

    static struct CPS {
        shared(ptrdiff_t) refCount = 1;
        RCAllocator allocator;

        void function(CPS*) @safe nothrow @nogc deinit;
    }
}

struct ClosurePartialAStateWrapper(ReturnType) {
    ClosurePartialAState!ReturnType* state;

export @safe nothrow @nogc:

    this(scope return ref ClosurePartialAStateWrapper other) scope {
        import sidero.base.internal.atomic;

        this.state = other.state;

        if(state !is null)
            atomicIncrementAndLoad(state.refCount, 1);
    }

    ~this() scope @trusted {
        import sidero.base.internal.atomic;

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

struct ClosurePartialAState(ReturnType) {
    shared(ptrdiff_t) refCount;
    RCAllocator allocator;

    void function(scope ClosurePartialAState*) @safe nothrow @nogc deinit;
    Result!ReturnType delegate(void* storage, void* args, void delegate() del) @safe nothrow @nogc typedToCall;

    ClosurePartialAStateWrapper!ReturnType next;
}

struct ClosurePartialState(ReturnType, HidingNArgs...) {
    shared(ptrdiff_t) refCount;
    RCAllocator allocator;

    void function(ClosurePartialState*) @safe nothrow @nogc deinit;
    Result!ReturnType delegate(void* storage, void* args, void delegate() del) @safe nothrow @nogc typedToCall;

    ClosurePartialAStateWrapper!ReturnType next;
    ClosureArgsStorage!HidingNArgs argsStorage;

export @safe nothrow @nogc:

    Result!ReturnType typedToCallImpl(ExposedNArgs...)(void* storage, void* args, void delegate() del) scope @trusted {
        ClosureArgsStorage!ExposedNArgs* inputStorage = cast(ClosureArgsStorage!ExposedNArgs*)args;
        ClosureArgsStorage!(HidingNArgs, ExposedNArgs) tempStorage;

        tempStorage.values[0 .. HidingNArgs.length] = argsStorage.values;
        tempStorage.values[HidingNArgs.length .. $] = inputStorage.values;

        if(next.isNull) {
            if (del.ptr !is null) {
                auto t = del.ptr;
                del.ptr = del.funcptr;
                del.funcptr = cast(typeof(del.funcptr))t;
            }

            return (cast(Result!ReturnType delegate(void*, typeof(tempStorage.values))@safe nothrow @nogc)del)(storage, tempStorage.values);
        } else {
            return this.next.state.typedToCall(storage, cast(void*)&tempStorage, del);
        }
    }
}
