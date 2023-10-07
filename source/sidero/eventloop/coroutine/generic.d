module sidero.eventloop.coroutine.generic;
import sidero.eventloop.coroutine.condition;
import sidero.eventloop.coroutine.internal.state;
import sidero.base.errors;
import sidero.base.internal.atomic;
import sidero.base.allocators;

///
struct GenericCoroutine {
    package(sidero.eventloop.coroutine) {
        CoroutineAPair pair;
    }

export @safe nothrow @nogc:

    ///
    this(return scope ref GenericCoroutine other) scope {
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
    void opAssign(return scope GenericCoroutine other) scope {
        this.destroy;
        this.__ctor(other);
    }

    ///
    bool isComplete() scope {
        return this.isNull() || pair.isComplete();
    }

    ///
    CoroutineCondition condition() scope {
        if(pair.isWaiting)
            return pair.state.conditionToContinue;
        else
            return typeof(return).init;
    }

    /// Execute the coroutine step by step. Warning: you must handle condition to continue prior.
    ErrorResult unsafeResume() scope @system {
        return pair.resume;
    }

    /// Set the coroutine as having no condition to continue. Warning: consider an internal mechanism for eventloops.
    void unsafeUnblock() scope @system {
        if(isNull)
            return;

        pair.state.conditionToContinue = CoroutineCondition.init;
    }

    /// Set the coroutine as having an erroneous result. Warning: consider an internal mechanism for eventloops.
    void unsafeSetErrorResult(ErrorInfo errorInfo) scope @system {
        if(isNull)
            return;

        pair.descriptor.setErrorResult(pair.state, errorInfo);
    }

    @disable auto opCast(T)();

    ///
    ulong toHash() scope const @trusted {
        return cast(size_t)pair.state;
    }

    ///
    alias equals = opEquals;

    ///
    bool opEquals(scope GenericCoroutine other) scope const {
        return this.toHash() == other.toHash();
    }

    ///
    alias compare = opCmp;

    ///
    int opCmp(scope GenericCoroutine other) scope const @trusted {
        const a = this.toHash(), b = other.toHash();

        if(a < b)
            return -1;
        else if(a > b)
            return 1;
        else
            return 0;
    }

    package(sidero.eventloop) {
        void debugMe(string prefix) {
            if(pair.state !is null) {
                import sidero.base.console;
                import sidero.base.internal.atomic;

                writeln(prefix, " debug ", cast(void*)pair.state, " rc ", atomicLoad(pair.state.refCount));
            }
        }
    }
}
