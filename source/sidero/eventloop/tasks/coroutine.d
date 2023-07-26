module sidero.eventloop.tasks.coroutine;
import sidero.eventloop.handles;
import sidero.base.allocators;
import sidero.base.errors;

// there are no hooks on non-windows for on thread creation (but is for cleanup)
// basic_memory will need hooks for thread attach/detach

///
struct Future(ResultType) {
    private {
        CoroutinePair!ResultType pair;
    }

export @safe nothrow @nogc:

    ///
    this(scope ref Future other) scope {
        this.tupleof = other.tupleof;
    }

    ///
    ~this() {
    }

    ///
    bool isNull() scope const {
        return pair.isNull;
    }

    ///
    bool isInstantiated() scope const {
        return pair.state !is null;
    }

    /// Execute the coroutine step by step. Warning: you must handle condition to continue prior.
    ErrorResult resume() scope {
        return pair.resume;
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
    GenericCoroutine asGeneric() return scope {
        GenericCoroutine ret;
        ret.pair = this.pair.asGeneric();
        ret.pair.rc(true);
        return ret;
    }

    ///
    Result!ResultType result() {
        if(!isInstantiated)
            return typeof(return)(NullPointerException("Coroutine not instantiated"));
        return typeof(return)(this.pair.state.result);
    }
}

///
struct InstantiableCoroutine(ResultType, Args...) {
    private {
        CoroutinePair!ResultType pair;
    }

export @safe nothrow @nogc:

    ///
    this(scope ref InstantiableCoroutine other) scope {
        this.tupleof = other.tupleof;
    }

    ///
    ~this() {
    }

    ///
    bool isNull() scope const {
        return pair.isNull;
    }

    ///
    bool isInstantiated() scope const {
        return pair.state !is null;
    }

    ///
    bool canInstance() scope const {
        return pair.descriptor !is null && pair.canInstance();
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
        ret.pair.descriptor = this.pair.descriptor;
        ret.pair.state = cast(CoroutineState!ResultType*)ret.pair.descriptor.base.createInstanceState(allocator,
                cast(void*)&argsStorage);
        ret.pair.rc(true);

        return ret;
    }

    /// Execute the coroutine step by step. Warning: you must handle condition to continue prior.
    ErrorResult resume() scope {
        return pair.resume;
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
        if(!isInstantiated)
            return typeof(return)(NullPointerException("Coroutine not instantiated"));
        return this.pair.state.result;
    }
}

struct GenericCoroutine {
    private {
        CoroutineAPair pair;
    }

export @safe nothrow @nogc:

    ///
    this(return scope ref GenericCoroutine other) scope {
        this.tupleof = other.tupleof;
    }

    ///
    ~this() {
    }

    ///
    bool isNull() scope const {
        return pair.isNull;
    }

    /// Execute the coroutine step by step. Warning: you must handle condition to continue prior.
    ErrorResult resume() scope {
        return pair.resume;
    }

    ///
    bool isComplete() scope {
        return this.isNull() || pair.isComplete();
    }

    ///
    bool isInstantiated() scope const {
        return pair.state !is null;
    }

    ///
    CoroutineCondition condition() scope {
        if(pair.isWaiting)
            return pair.state.conditionToContinue;
        else
            return typeof(return).init;
    }
}

///
struct CoroutineCondition {
    private {
        SystemHandle systemHandle;
        GenericCoroutine coroutine;
    }

export @safe nothrow @nogc:

    this(return scope ref CoroutineCondition other) scope {
        this.tupleof = other.tupleof;
    }

    ///
    bool isNull() scope const {
        return systemHandle.isNull && coroutine.isNull;
    }

    ///
    WaitingOn waitingOn() scope {
        if(!systemHandle.isNull)
            return WaitingOn.SystemHandle;
        else if(!coroutine.isNull)
            return WaitingOn.Coroutine;
        else
            return WaitingOn.Nothing;
    }

    ///
    enum WaitingOn {
        ///
        Nothing,
        ///
        Coroutine,
        ///
        SystemHandle
    }
}

///
struct CoroutineBuilder(State, Stages, ResultType = void, Args...) {
    ///
    static assert(is(State == struct), "State of a coroutine can only be represented by a struct");
    static assert(!__traits(isNested, State), "State of a coroutine must not be a nested struct. Annotate with static.");
    ///
    static assert(() {
        size_t lastValue;

        foreach(Name; __traits(allMembers, Stages)) {
            if(__traits(getMember, Stages, Name) > lastValue + 1)
                return false;
            lastValue = __traits(getMember, Stages, Name);
        }

        return true;
    }(), "Stages must be an enum of 0 .. length in values and may have duplicates sequentially");

    ///
    alias CoroutineResultType = CoroutineResult!(Stages, ResultType);
    ///
    alias FunctionPrototype = CoroutineResultType function(scope ref State) @safe nothrow @nogc;

    private {
        FunctionPrototype[__traits(allMembers, Stages).length] functions;
    }

export @safe nothrow @nogc:

    ///
    void opIndexAssign(FunctionPrototype func, Stages stage) scope {
        functions[stage] = func;
    }

    ///
    Result!(InstantiableCoroutine!(ResultType, Args)) build(RCAllocator allocator = RCAllocator.init) scope @trusted {
        foreach(func; functions) {
            if(func is null)
                return typeof(return)(NullPointerException("All functions in vtable must be filled"));
        }

        if(allocator.isNull)
            allocator = globalAllocator();

        CoroutinePair!ResultType pair;
        pair.descriptor = allocator.make!(CoroutineDescriptor!ResultType)();

        pair.descriptor.base.allocator = allocator;
        pair.descriptor.base.toDeallocate = (cast(void*)pair.descriptor)[0 .. CoroutineDescriptor!ResultType.sizeof];
        pair.descriptor.base.deinit = (scope void[] memory) @trusted {
            CoroutineDescriptor!ResultType* descriptor = cast(CoroutineDescriptor!ResultType*)memory.ptr;
            descriptor.destroy;
        };

        pair.descriptor.base.userFunctions = allocator.makeArray!(void*)(this.functions.length);
        pair.descriptor.base.functions = allocator.makeArray!(CoroutineAllocatorMemoryDescriptor.FunctionPrototype)(this.functions.length);

        static struct CoroutineState2 {
            CoroutineState!ResultType parent;
            alias parent this;

            State userState;
        }

        pair.descriptor.base.createInstanceState = (RCAllocator allocator, void* args) @trusted {
            CoroutineState2* ret = allocator.make!CoroutineState2;

            ret.base.allocator = allocator;
            ret.base.toDeallocate = (cast(void*)ret)[0 .. CoroutineState2.sizeof];
            ret.base.deinit = (scope void[] memory) @trusted {
                CoroutineState2* state = cast(CoroutineState2*)memory.ptr;
                state.destroy;
            };

            static if(Args.length > 0) {
                ArgsStorage!Args argsStorage = *cast(ArgsStorage!Args*)args;
                ret.userState = State(argsStorage.values);
            }

            return &ret.parent.base;
        };

        static foreach(offset, Stage; __traits(allMembers, Stages)) {
            pair.descriptor.base.userFunctions[offset] = this.functions[__traits(getMember, Stages, Stage)];
            pair.descriptor.base.functions[offset] = (scope CoroutineAllocatorMemoryDescriptor* descriptor,
                    scope CoroutineAllocatorMemoryState* state) @trusted {
                CoroutineDescriptor!ResultType* actualDescriptor = cast(CoroutineDescriptor!ResultType*)descriptor;
                CoroutineState2* actualState = cast(CoroutineState2*)state;

                actualState.base.conditionToContinue = CoroutineCondition.init;

                FunctionPrototype actualFunction = cast(FunctionPrototype)actualDescriptor.base.userFunctions[offset];
                CoroutineResultType result = actualFunction(actualState.userState);

                final switch(result.tag) {
                case CoroutineResultType.Tag.Value:
                    actualState.result = Result!ResultType(result.resultValue);
                    atomicStore(actualState.base.isComplete, true);
                    actualState.base.nextFunctionTag = -1;
                    break;
                case CoroutineResultType.Tag.Error:
                    actualState.result = Result!ResultType(result.error);
                    atomicStore(actualState.base.isComplete, true);
                    actualState.base.nextFunctionTag = -2;
                    break;
                case CoroutineResultType.Tag.Stage:
                    actualState.base.conditionToContinue = result.condition;
                    actualState.base.nextFunctionTag = cast(ptrdiff_t)result.stage;
                    break;
                }
            };
        }

        pair.rc(true);
        InstantiableCoroutine!(ResultType, Args) ret;
        ret.pair = pair;

        return typeof(return)(ret);
    }

    static if(is(ResultType == void)) {
        ///
        static CoroutineResultType complete() {
            return CoroutineResultType.init;
        }
    } else {
        ///
        static CoroutineResultType complete(ResultType value) {
            return CoroutineResultType(CoroutineResultType.Tag.Value, Stages.init, ErrorInfo.init, CoroutineCondition.init, value);
        }
    }

    ///
    static CoroutineResultType complete(ErrorInfo error) {
        return CoroutineResultType(CoroutineResultType.Tag.Error, Stages.init, error);
    }

    ///
    static CoroutineResultType nextStage(Stages next) {
        return CoroutineResultType(CoroutineResultType.Tag.Stage, next);
    }
}

///
unittest {
    InstantiableCoroutine!(int, int) createCo() {
        static struct State {
            int value;

        @safe nothrow @nogc:

            this(int value) {
                this.value = value;
            }
        }

        enum Stages {
            Multiply,
            Add,
        }

        CoroutineBuilder!(State, Stages, int, int) builder;

        builder[Stages.Multiply] = (scope ref state) {
            state.value *= 3;
            // workaround for: https://issues.dlang.org/show_bug.cgi?id=23835
            return typeof(builder).nextStage(Stages.Add);
        };

        builder[Stages.Add] = (scope ref state) {
            state.value += 2;
            // workaround for: https://issues.dlang.org/show_bug.cgi?id=23835
            return typeof(builder).complete(state.value);
        };

        auto got = builder.build();
        assert(got);
        return got.get;
    }

    auto co = createCo();
    assert(co.canInstance);

    auto co2 = co.makeInstance(RCAllocator.init, 4);
    assert(!co2.isNull);
    assert(co2.isInstantiated);

    while(!co2.isComplete) {
        assert(co2.condition.waitingOn == CoroutineCondition.WaitingOn.Nothing);

        ErrorResult er = co2.resume();
        assert(er);
    }

    auto result = co2.result();
    assert(result);
    assert(result == 14);
}

///
unittest {
    static InstantiableCoroutine!(int, int) createCo1() {
        static struct State {
            int value;

        @safe nothrow @nogc:

            this(int value) {
                this.value = value;
            }
        }

        enum Stages {
            Multiply,
            Add,
        }

        CoroutineBuilder!(State, Stages, int, int) builder;

        builder[Stages.Multiply] = (scope ref state) {
            state.value *= 3;
            // workaround for: https://issues.dlang.org/show_bug.cgi?id=23835
            return typeof(builder).nextStage(Stages.Add);
        };

        builder[Stages.Add] = (scope ref state) {
            state.value += 2;
            // workaround for: https://issues.dlang.org/show_bug.cgi?id=23835
            return typeof(builder).complete(state.value);
        };

        auto got = builder.build();
        assert(got);
        return got.get;
    }

    static InstantiableCoroutine!(int, int) createCo2() {
        import sidero.eventloop.synchronization.system.lock;

        static struct State {
            SystemLock lock;
            int value;

            Future!int worker;

        @safe nothrow @nogc:

            this(int value) {
                this.value = value;
            }
        }

        enum Stages {
            INeedLock,
            INeedCoroutine,
            Done,
        }

        CoroutineBuilder!(State, Stages, int, int) builder;

        builder[Stages.INeedLock] = (scope ref state) @trusted {
            auto handle = state.lock.unsafeGetHandle();
            // workaround for: https://issues.dlang.org/show_bug.cgi?id=23835
            return typeof(builder).nextStage(Stages.INeedCoroutine).after(handle);
        };

        builder[Stages.INeedCoroutine] = (scope ref state) @trusted {
            state.lock.unlock;

            auto worker = createCo1();
            state.worker = worker.makeInstance(RCAllocator.init, state.value).asFuture;
            assert(!state.worker.isNull);

            // workaround for: https://issues.dlang.org/show_bug.cgi?id=23835
            return typeof(builder).nextStage(Stages.Done).after(state.worker);
        };

        builder[Stages.Done] = (scope ref state) @trusted {
            // workaround for: https://issues.dlang.org/show_bug.cgi?id=23835
            return typeof(builder).complete(state.worker.result.assumeOkay + 8);
        };

        auto got = builder.build();
        assert(got);
        return got.get;
    }

    auto co = createCo2();
    assert(co.canInstance);

    auto coI = co.makeInstance(RCAllocator.init, 4);
    assert(!coI.isNull);
    assert(coI.isInstantiated);

    while(!coI.isComplete) {
        final switch(coI.condition.waitingOn) {
        case CoroutineCondition.WaitingOn.Nothing:
            break;
        case CoroutineCondition.WaitingOn.SystemHandle:
            assert(!coI.condition.systemHandle.isNull);
            assert(coI.condition.systemHandle.waitForEvent !is null);

            auto result = coI.condition.systemHandle.waitForEvent(coI.condition.systemHandle.handle);
            assert(result);
            break;
        case CoroutineCondition.WaitingOn.Coroutine:
            auto coI2 = coI.condition.coroutine;

            while(!coI2.isComplete) {
                assert(coI2.condition.waitingOn == CoroutineCondition.WaitingOn.Nothing);

                ErrorResult er = coI2.resume();
                assert(er);
            }
            break;
        }

        ErrorResult er = coI.resume();
        assert(er);
    }

    auto result = coI.result();
    assert(result);
    assert(result == 22);
}

//
struct CoroutineResult(Stages, ResultType = void) {
    private {
        Tag tag;
        Stages stage;
        ErrorInfo error;

        CoroutineCondition condition;

        static if(!is(ResultType == void)) {
            ResultType resultValue;
        }

        enum Tag {
            Value,
            Stage,
            Error,
        }
    }

export @safe nothrow @nogc:

    this(scope ref CoroutineResult other) scope @trusted {
        this.tupleof = other.tupleof;
    }

    ///
    CoroutineResult after(SystemHandle waitingOn) scope return @trusted {
        assert(tag == Tag.Stage);
        this.condition.systemHandle = waitingOn;
        return this;
    }

    ///
    CoroutineResult after(ResultType)(Future!ResultType waitingOn) scope return @trusted {
        return this.after(waitingOn.asGeneric());
    }

    ///
    CoroutineResult after(ResultType, Args...)(InstantiableCoroutine!(ResultType, Args) waitingOn) scope return @trusted {
        return this.after(waitingOn.asGeneric());
    }

    ///
    CoroutineResult after(GenericCoroutine waitingOn) scope return @trusted {
        assert(tag == Tag.Stage);
        this.condition.coroutine = waitingOn;
        return this;
    }
}

private:
import core.atomic : atomicLoad, atomicStore;

struct CoroutinePair(ResultType) {
    private {
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
        import core.atomic : atomicOp;

        if(!add && atomicOp!"-="(refCount, 1) == 0) {
            RCAllocator allocator = this.allocator;

            // run destructors ext.
            if(this.deinit !is null)
                this.deinit(toDeallocate);

            allocator.dispose(toDeallocate);
        } else if(add)
            atomicOp!"+="(refCount, 1);
    }
}

struct ArgsStorage(Args...) {
    Args values;
    alias values this;
}
