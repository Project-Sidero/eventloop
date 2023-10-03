module sidero.eventloop.closure.builder;
import sidero.eventloop.closure.callable;
import sidero.eventloop.synchronization.system.lock;
import sidero.base.errors;
import sidero.base.allocators;

export @safe nothrow @nogc:

///
alias ClosureOnDeallocationDelegate = void delegate() @safe nothrow @nogc;

///
Closure!(ResultType, Args) buildClosure(ResultType, Args...)(return ResultType delegate(Args) @safe nothrow @nogc del,
        return ClosureOnDeallocationDelegate onDeallocation = null) @trusted {
    import sidero.eventloop.closure.internal.state;

    if(del is null)
        return typeof(return).init;

    static if(is(ResultType : Result!RT, RT)) {
        enum IsExactRT = true;
    } else {
        alias RT = ResultType;
        enum IsExactRT = false;
    }

    static struct Storage {
        ClosureDescriptor descriptor;
        ResultType delegate(Args) @safe nothrow @nogc toCall;
        ClosureOnDeallocationDelegate onDeallocation;
        SystemLock mutex;

    export @safe nothrow @nogc:

         ~this() {
            if(onDeallocation !is null)
                onDeallocation();
        }
    }

    RCAllocator allocator = globalAllocator();
    Closure!(RT, Args) ret;

    Storage* storage = allocator.make!Storage();
    storage.mutex = SystemLock.init;

    storage.descriptor = ClosureDescriptor(1, allocator, (cast(void*)storage)[0 .. Storage.sizeof], (toDeallocate) @trusted {
        Storage* storage = cast(Storage*)toDeallocate.ptr;
        storage.destroy;
    });
    storage.toCall = del;
    storage.onDeallocation = onDeallocation;

    ret.descriptor = ClosureTypedDescriptor!(RT, Args)(&storage.descriptor, (void* storage, Args args) @trusted {
        Storage* s = cast(Storage*)storage;

        auto gotL = s.mutex.lock;
        if (!gotL)
            return Result!RT(gotL.getError());

        scope(exit)
            s.mutex.unlock;

        static if(is(ResultType == void)) {
            s.toCall(args);
            return Result!RT.init;
        } else {
            static if(IsExactRT) {
                return s.toCall(args);
            } else {
                return Result!RT(s.toCall(args));
            }
        }
    });
    return ret;
}

///
unittest {
    static struct Context {
        bool init;
        int hit;

    @safe nothrow @nogc:

        this(bool init) {
            this.init = init;
        }

        ~this() {
            if(init)
                assert(hit == 4);
        }

        void call() {
            hit++;
        }
    }

    Context context;
    auto closure = buildClosure(&context.call);
    assert(!closure.isNull);

    auto got = closure();
    assert(got);
    got = closure();
    assert(got);

    auto gclosure = closure.asGeneric();
    got = gclosure();
    assert(got);
    got = gclosure();
    assert(got);
}

///
auto buildContextClosure(Context, string ToCall = "call", ContextArgs...)(return ContextArgs contextArgs) @trusted {
    static assert(is(Context == struct), "Context must be a struct");

    import sidero.eventloop.closure.internal.state;
    import std.traits : ReturnType, ParameterTypeTuple;

    static assert(__traits(hasMember, Context, ToCall), "Context type must contain the method " ~ ToCall);
    alias _RT = ReturnType!(__traits(getMember, Context, ToCall));

    static if(is(_RT : Result!RT, RT)) {
        enum IsExactRT = true;
    } else {
        alias RT = _RT;
        enum IsExactRT = false;
    }

    alias Args = ParameterTypeTuple!(__traits(getMember, Context, ToCall));

    static struct Storage {
        ClosureDescriptor descriptor;
        Context context;
        SystemLock mutex;

    export @safe nothrow @nogc:
         ~this() {
        }
    }

    RCAllocator allocator = globalAllocator();
    Closure!(RT, Args) ret;

    Storage* storage = allocator.make!Storage();
    storage.mutex = SystemLock.init;

    storage.descriptor = ClosureDescriptor(1, allocator, (cast(void*)storage)[0 .. Storage.sizeof], (toDeallocate) @trusted {
        Storage* storage = cast(Storage*)toDeallocate.ptr;
        storage.destroy;
    });
    storage.context = Context(contextArgs);

    ret.descriptor = ClosureTypedDescriptor!(RT, Args)(&storage.descriptor, (void* storage, Args args) @trusted {
        Storage* s = cast(Storage*)storage;

        auto gotL = s.mutex.lock;
        if (!gotL)
            return Result!RT(gotL.getError());

        scope(exit)
            s.mutex.unlock;

        static if(is(_RT == void)) {
            __traits(getMember, s.context, ToCall)(args);
            return Result!RT.init;
        } else {
            static if(IsExactRT) {
                return __traits(getMember, s.context, ToCall)(args);
            } else {
                return Result!RT(__traits(getMember, s.context, ToCall)(args));
            }
        }
    });

    return ret;
}

///
unittest {
    static struct Context {
        bool init;
        int hit;

    @safe nothrow @nogc:

        this(bool init) {
            this.init = init;
        }

        ~this() {
            if(init)
                assert(hit == 4);
        }

        void call() {
            hit++;
        }
    }

    auto closure = buildContextClosure!Context(true);
    assert(!closure.isNull);

    auto got = closure();
    assert(got);
    got = closure();
    assert(got);

    auto gclosure = closure.asGeneric();
    got = gclosure();
    assert(got);
    got = gclosure();
    assert(got);
}

///
unittest {
    static struct Context {
    @safe nothrow @nogc:

        void call(float x, int y, bool b) {
            assert(x != 0);
            assert(y != 0);
            assert(b);
        }
    }

    auto closure = buildContextClosure!Context();
    assert(!closure.isNull);

    auto closureP1 = closure.partial(1.32);
    assert(!closureP1.isNull);

    auto closureP2 = closureP1.partial(2);
    assert(!closureP2.isNull);

    auto got = closureP2(true);
    assert(got);
    got = closureP2(true);
    assert(got);

    auto closureP3 = closureP2.partial(true);
    assert(!closureP3.isNull);

    auto gclosure = closureP3.asGeneric();
    got = gclosure();
    assert(got);
    got = gclosure();
    assert(got);
}
