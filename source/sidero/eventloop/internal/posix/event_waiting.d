module sidero.eventloop.internal.posix.event_waiting;
import sidero.eventloop.internal.event_waiting;
import sidero.eventloop.threads;
import sidero.base.containers.dynamicarray;

@safe nothrow @nogc:

struct EventWaiterThread {
    Thread thread;

    shared(bool) isAlive;

    DynamicArray!(void*) nextEventHandles, eventHandles;
    DynamicArray!(UserEventHandler) nextEventProcs, eventProcs;

    @safe nothrow @nogc:

    this(return scope ref EventWaiterThread other) scope {
        this.tupleof = other.tupleof;
    }

    void ourProc() nothrow {
    }
}

bool initializePlatformEventWaiting() {
    return false;
}

size_t maximumNumberOfHandlesPerEventWaiter() {
    return 0;
}

void triggerUpdatesOnThreads(size_t oldThreadCount) {
}

void shutdownEventWaiterThreadsMechanism() {
}
