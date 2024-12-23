module sidero.eventloop.coroutine.builder;
import sidero.eventloop.coroutine.internal.state;
import sidero.eventloop.coroutine.condition;
import sidero.eventloop.coroutine.generic;
import sidero.eventloop.coroutine.future;
import sidero.eventloop.coroutine.instanceable;
import sidero.eventloop.handles;
import sidero.base.allocators;
import sidero.base.errors;
import sidero.base.internal.atomic;

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
    alias CoroutineResultType = CoroutineResult!(ResultType);
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
    Result!(InstanceableCoroutine!(ResultType, Args)) build(RCAllocator allocator = RCAllocator.init) scope @trusted {
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
            (*descriptor).destroy;
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
                (*state).destroy;
            };

            static if(Args.length > 0) {
                ArgsStorage!Args argsStorage = *cast(ArgsStorage!Args*)args;
                ret.userState = State(argsStorage.values);
            }

            return &ret.parent.base;
        };

        pair.descriptor.base.setErrorResult = (scope CoroutineAllocatorMemoryState* state, ErrorInfo errorInfo) @trusted nothrow @nogc {
            CoroutineState2* actualState = cast(CoroutineState2*)state;
            actualState.base.conditionToContinue = CoroutineCondition.init;
            actualState.result = Result!ResultType(errorInfo.info, errorInfo.moduleName, errorInfo.line);

            actualState.base.nextFunctionTag = -2;
            actualState.base.setAsComplete();
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
                    static if(!is(ResultType == void)) {
                        actualState.result = Result!ResultType(result.resultValue);
                    }

                    actualState.base.nextFunctionTag = -1;
                    actualState.base.setAsComplete();
                    break;
                case CoroutineResultType.Tag.Error:
                    actualState.result = Result!ResultType(result.error);
                    actualState.base.nextFunctionTag = -2;
                    actualState.base.setAsComplete();
                    break;
                case CoroutineResultType.Tag.Stage:
                    actualState.base.conditionToContinue = result.condition;
                    actualState.base.nextFunctionTag = cast(ptrdiff_t)result.stage;
                    break;
                }
            };
        }

        InstanceableCoroutine!(ResultType, Args) ret;
        ret.pair = pair;
        ret.pair.rc(true);

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
            auto ret = CoroutineResultType(CoroutineResultType.Tag.Value, Stages.init, ErrorInfo.init, CoroutineCondition.init, value);
            return ret;
        }
    }

    ///
    static CoroutineResultType complete(ErrorMessage error, string mod = __MODULE__, int line = __LINE__) {
        return CoroutineResultType(CoroutineResultType.Tag.Error, Stages.init, ErrorInfo(error, mod, line));
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
struct CoroutineResult(ResultType = void) {
    private {
        Tag tag;
        size_t stage;
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

    ~this() scope {
    }

    ///
    CoroutineResult after(ResultType)(Future!ResultType waitingOn) scope return @trusted {
        return this.after(waitingOn.asGeneric());
    }

    ///
    CoroutineResult after(ResultType, Args...)(InstanceableCoroutine!(ResultType, Args) waitingOn) scope return @trusted {
        return this.after(waitingOn.asGeneric());
    }

    ///
    CoroutineResult after(GenericCoroutine waitingOn) scope return @trusted {
        assert(tag == Tag.Stage);
        this.condition.coroutine = waitingOn;
        return this;
    }
}

///
unittest {
    InstanceableCoroutine!(int, int) createCo() {
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

        alias Builder = CoroutineBuilder!(State, Stages, int, int);
        Builder builder;

        builder[Stages.Multiply] = (scope ref state) {
            state.value *= 3;
            // workaround for: https://issues.dlang.org/show_bug.cgi?id=23835
            return Builder.nextStage(Stages.Add);
        };

        builder[Stages.Add] = (scope ref state) {
            state.value += 2;
            // workaround for: https://issues.dlang.org/show_bug.cgi?id=23835
            return Builder.complete(state.value);
        };

        auto got = builder.build();
        assert(got);
        return got.get;
    }

    auto co = createCo();
    assert(!co.isNull);

    auto co2 = co.makeInstance(RCAllocator.init, 4);
    assert(!co2.isNull);

    while(!co2.isComplete) {
        assert(co2.condition.waitingOn == CoroutineCondition.WaitingOn.Nothing);

        ErrorResult er = co2.unsafeResume();
        assert(er);
    }

    auto result = co2.result();
    assert(result);
    assert(result == 14);
}

///
unittest {
    static InstanceableCoroutine!(int, int) createCo1() {
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

        alias Builder = CoroutineBuilder!(State, Stages, int, int);
        Builder builder;

        builder[Stages.Multiply] = (scope ref state) {
            state.value *= 3;
            // workaround for: https://issues.dlang.org/show_bug.cgi?id=23835
            return Builder.nextStage(Stages.Add);
        };

        builder[Stages.Add] = (scope ref state) {
            state.value += 2;
            // workaround for: https://issues.dlang.org/show_bug.cgi?id=23835
            return Builder.complete(state.value);
        };

        auto got = builder.build();
        assert(got);
        return got.get;
    }

    static InstanceableCoroutine!(int, int) createCo2() {
        import sidero.base.synchronization.system.lock;

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
            INeedCoroutine,
            Done,
        }

        CoroutineBuilder!(State, Stages, int, int) builder;

        builder[Stages.INeedCoroutine] = (scope ref state) @trusted {
            state.lock.unlock;

            auto worker = createCo1();
            state.worker = worker.makeInstance(RCAllocator.init, state.value);
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
    assert(!co.isNull);

    auto coI = co.makeInstance(RCAllocator.init, 4);
    assert(!coI.isNull);

    while(!coI.isComplete) {
        final switch(coI.condition.waitingOn) {
        case CoroutineCondition.WaitingOn.Nothing:
            break;
        case CoroutineCondition.WaitingOn.ExternalTrigger:
            assert(0);
        case CoroutineCondition.WaitingOn.Coroutine:
            auto coI2 = coI.condition.coroutine;

            while(!coI2.isComplete) {
                assert(coI2.condition.waitingOn == CoroutineCondition.WaitingOn.Nothing);

                ErrorResult er = coI2.unsafeResume();
                assert(er);
            }
            break;
        }

        ErrorResult er = coI.unsafeResume();
        assert(er);
    }

    auto result = coI.result();
    assert(result);
    assert(result == 22);
}
