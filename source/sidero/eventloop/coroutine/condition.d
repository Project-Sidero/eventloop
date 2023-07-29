module sidero.eventloop.coroutine.condition;
import sidero.eventloop.coroutine.generic;
import sidero.eventloop.handles;

///
struct CoroutineCondition {
    package(sidero.eventloop.coroutine) {
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
