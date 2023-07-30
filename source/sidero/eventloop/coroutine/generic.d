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
