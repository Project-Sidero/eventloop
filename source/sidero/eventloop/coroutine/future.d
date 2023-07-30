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
