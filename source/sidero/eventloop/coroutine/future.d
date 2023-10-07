module sidero.eventloop.coroutine.future;
import sidero.eventloop.coroutine.internal.state;
import sidero.eventloop.coroutine.condition;
import sidero.eventloop.coroutine.generic;
import sidero.base.errors;

///
struct Future(ResultType) {
    package(sidero.eventloop.coroutine) {
        CoroutinePair!ResultType pair;
    }

export @safe nothrow @nogc:

    ///
    this(scope ref Future other) scope {
        this.tupleof = other.tupleof;
    }

    ///
    ~this() scope {
    }

    ///
    void opAssign(return scope Future other) scope {
        this.destroy;
        this.__ctor(other);
    }

    ///
    bool isNull() scope const {
        return pair.isNull;
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
        return ret;
    }

    ///
    Result!ResultType result() return scope {
        if(isNull)
            return typeof(return)(NullPointerException("Coroutine not instantiated"));
        return typeof(return)(this.pair.state.result);
    }

    /// Execute the coroutine step by step. Warning: you must handle condition to continue prior.
    ErrorResult unsafeResume() scope @system {
        return pair.resume;
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
    bool opEquals(scope Future other) scope const {
        return this.toHash() == other.toHash();
    }

    ///
    alias compare = opCmp;

    ///
    int opCmp(scope Future other) scope const @trusted {
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
            if (pair.state !is null) {
                import sidero.base.console;
                import sidero.base.internal.atomic;

                writeln(prefix, " debug ", cast(void*)pair.state, " rc ", atomicLoad(pair.state.base.refCount));
            }
        }
    }
}
