module sidero.eventloop.closure.callable;
import sidero.eventloop.closure.generic;
import sidero.base.errors;

///
struct Closure(ReturnType, Args...) {
    static if(is(ReturnType : Result!RealReturnType, RealReturnType)) {
    } else {
        ///
        alias RealReturnType = ReturnType;
    }

    package(sidero.eventloop.closure) {
        import sidero.eventloop.closure.internal.state;

        ClosureTypedDescriptor!(RealReturnType, Args) descriptor;
        ClosurePartialAStateWrapper!RealReturnType partialState;
    }

export @safe nothrow @nogc:

    ///
    this(ref return scope Closure other) scope {
        this.tupleof = other.tupleof;

        if(descriptor.untyped !is null)
            descriptor.untyped.rc(true);
    }

    ///
    ~this() scope {
        if(descriptor.untyped !is null)
            descriptor.untyped.rc(false);
    }

    ///
    bool isNull() scope const {
        return descriptor.untyped is null;
    }

    ///
    Result!RealReturnType opCall(Args args) scope @trusted {
        if(isNull)
            return typeof(return)(NullPointerException("Closure is null"));

        if(partialState.isNull) {
            static if(is(ReturnType == void)) {
                cast(void)descriptor.typedToCall(descriptor.untyped.toDeallocate.ptr, args);
                return typeof(return).init;
            } else {
                return typeof(return)(descriptor.typedToCall(descriptor.untyped.toDeallocate.ptr, args));
            }
        } else {
            ClosureArgsStorage!Args storage;
            storage.values = args;

            static if(is(ReturnType == void)) {
                cast(void)partialState.state.typedToCall(descriptor.untyped.toDeallocate.ptr, &storage,
                        cast(void delegate())descriptor.typedToCall);
                return typeof(return).init;
            } else {
                return typeof(return)(partialState.state.typedToCall(descriptor.untyped.toDeallocate.ptr, &storage,
                        cast(void delegate())descriptor.typedToCall));
            }
        }
    }

    static if(Args.length == 0) {
        ///
        GenericClosure asGeneric() return scope @trusted {
            GenericClosure ret;

            if(this.descriptor.untyped !is null) {
                this.descriptor.untyped.rc(true);
                ret.descriptor.untyped = this.descriptor.untyped;
                ret.descriptor.typedToCall = cast(void delegate())this.descriptor.typedToCall;
                ret.descriptor.untypedToCall = (void* storage, void delegate() typedToCall) @trusted {
                    auto toCall = cast(Result!RealReturnType delegate(void* storage)@safe nothrow @nogc)typedToCall;
                    auto got = toCall(storage);

                    static if(!is(ReturnType == RealReturnType)) {
                        if(!got) {
                            auto ei = got.getError();
                            return ErrorResult(ei, ei.moduleName, ei.line);
                        }
                    }

                    return ErrorResult.init;
                };

                if(!partialState.isNull) {
                    ClosureGenericPartialWrapper cgp;
                    cgp.state = cast(ClosureGenericPartialWrapper.CPS*)this.partialState.state;
                    cgp.__ctor(cgp);

                    cgp.partialTypedToCall = cast(void delegate())this.partialState.state.typedToCall;
                    cgp.untypedToCall = (void* storage, void delegate() partialTypedToCall, void delegate() realTypedToCall) @trusted {
                        auto toCall = cast(Result!RealReturnType delegate(void* storage, void* args, void delegate() realTypedToCall)@safe nothrow @nogc)partialTypedToCall;
                        auto got = toCall(storage, null, realTypedToCall);

                        static if(!is(ReturnType == RealReturnType)) {
                            if(!got) {
                                auto ei = got.getError();
                                return ErrorResult(ei, ei.moduleName, ei.line);
                            }
                        }

                        return ErrorResult.init;
                    };

                    ret.partialState = cgp;
                }
            }

            return ret;
        }
    } else {
        ///
        Closure!(ReturnType, Args[PartialArgs.length .. Args.length]) partial(PartialArgs...)(return scope PartialArgs args) return scope @trusted {
            import sidero.base.allocators;
            RCAllocator allocator = globalAllocator();

            alias CPS = ClosurePartialState!(RealReturnType, Args[0 .. PartialArgs.length]);
            auto partialState = allocator.make!(CPS)(1, allocator, (CPS* state) @trusted {
                state.destroy;
            });
            partialState.typedToCall = &partialState.typedToCallImpl!(Args[PartialArgs.length .. $]);
            partialState.next = this.partialState;
            partialState.argsStorage.values = args;

            typeof(return) ret;
            ret.descriptor.untyped = this.descriptor.untyped;
            ret.descriptor.typedToCall = cast(typeof(ret.descriptor.typedToCall))this.descriptor.typedToCall;
            ret.partialState.state = cast(typeof(ret.partialState.state))partialState;

            ret.descriptor.untyped.rc(true);
            return ret;
        }
    }
}
