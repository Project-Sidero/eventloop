module sidero.eventloop.coroutine.condition;
import sidero.eventloop.coroutine.generic;
import sidero.eventloop.handles;

///
struct CoroutineCondition {
    package(sidero.eventloop) {
        GenericCoroutine coroutine;
        bool isExternalTrigger;
    }

export @safe nothrow @nogc:

    this(return scope ref CoroutineCondition other) scope {
        this.tupleof = other.tupleof;
    }

    ~this() scope {
    }

    void opAssign(return scope CoroutineCondition other) scope {
        this.destroy;
        this.__ctor(other);
    }

    ///
    bool isNull() scope const {
        return coroutine.isNull;
    }

    ///
    WaitingOn waitingOn() scope const {
        if (isExternalTrigger)
            return WaitingOn.ExternalTrigger;
        else if(!coroutine.isNull)
            return WaitingOn.Coroutine;
        else
            return WaitingOn.Nothing;
    }

    export @safe nothrow @nogc:

    ///
    ulong toHash() const {
        return coroutine.toHash() ^ isExternalTrigger;
    }

    ///
    bool opEquals(scope ref CoroutineCondition other) const {
        return other.isExternalTrigger == isExternalTrigger && coroutine == other.coroutine;
    }

    ///
    enum WaitingOn {
        ///
        Nothing,
        ///
        Coroutine,
        ///
        ExternalTrigger,
    }
}
