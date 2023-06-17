module sidero.eventloop.internal.event_waiting;
import sidero.eventloop.synchronization.system.lock;
import sidero.eventloop.threads;
import sidero.base.containers.dynamicarray;
import sidero.base.containers.map.hashmap;
import sidero.base.containers.map.concurrenthashmap;
import sidero.base.attributes;
import sidero.base.logger;
import sidero.base.text;

version (Windows) {
    import sidero.eventloop.internal.windows.event_waiting;
} else
    static assert(0, "Unimplemented");

    export @safe nothrow @nogc:

    alias UserEventProc = void function(void* handle, void* user) @safe nothrow @nogc;

struct UserEventHandler {
    UserEventProc proc;
    void* user;
}

// minimal demonstration of what is required
version (none) {
    struct EventWaiterThread {
        Thread thread;

        shared(bool) isAlive;

        DynamicArray!(void*) nextEventHandles, eventHandles;
        DynamicArray!(UserEventHandler) nextEventProcs, eventProcs;

    export @safe nothrow @nogc:

        this(return scope ref EventWaiterThread other) scope {
            this.tupleof = other.tupleof;
        }

        void ourProc() nothrow {
        }
    }

    size_t maximumNumberOfHandlesPerEventWaiter() {
        return 0;
    }

    void triggerUpdatesOnThreads(size_t oldThreadCount) {
    }

    void shutdownEventWaiterThreadsMechanism() {
    }
}

package(sidero.eventloop.internal) __gshared {
    ConcurrentHashMap!(Thread, EventWaiterThread) eventWaiterThreads;
    SystemLock eventWaiterMutex;

    HashMap!(void*, UserEventHandler) allEventHandles;
    LoggerReference logger;
}

void addEventWaiterHandle(void* handleToWaitOn, UserEventProc proc, void* user) @trusted {
    auto lockError = eventWaiterMutex.lock;
    assert(lockError);

    if (handleToWaitOn !in allEventHandles) {
        allEventHandles[handleToWaitOn] = UserEventHandler(proc, user);
    }

    eventWaiterMutex.unlock;
}

void removeEventWaiterHandle(scope void* handleToNotWaitOn) @trusted {
    auto lockError = eventWaiterMutex.lock;
    assert(lockError);

    allEventHandles.remove(handleToNotWaitOn);

    eventWaiterMutex.unlock;
    updateEventWaiterThreads();
}

void shutdownEventWaiterThreads() {
    shutdownEventWaiterThreadsMechanism();
}

private @hidden:

void updateEventWaiterThreads() @trusted {
    import core.atomic : atomicLoad;

    const maxEventHandles = maximumNumberOfHandlesPerEventWaiter();

    auto lockError = eventWaiterMutex.lock;
    assert(lockError);

    if (logger.isNull)
        logger = Logger.forName(String_UTF8(__MODULE__));

    logger.trace("Updating event waiter thread handles");
    const oldThreadCount = eventWaiterThreads.length;

    {
        // step one: cleanup old threads that are no longer alive
        foreach (threadState; eventWaiterThreads) {
            if (atomicLoad(threadState.isAlive))
                eventWaiterThreads.remove(threadState.thread);
        }
    }

    DynamicArray!(void*) tempHandles;
    DynamicArray!UserEventHandler tempProcs;

    {
        // step two: construct the arrays that'll be passed to the threads
        tempHandles.length = allEventHandles.length;
        tempProcs.length = allEventHandles.length;

        size_t offset;
        foreach (handle, proc; allEventHandles) {
            tempHandles[offset] = handle;
            tempProcs[offset] = proc;
            offset++;
        }
    }

    {
        // step three: give each waiter thread its new handles
        foreach (threadState; eventWaiterThreads) {
            if (tempHandles.length > maxEventHandles) {
                threadState.nextEventHandles = tempHandles[0 .. maxEventHandles];
                threadState.nextEventProcs = tempProcs[0 .. maxEventHandles];

                tempHandles = tempHandles[maxEventHandles .. $];
                tempProcs = tempProcs[maxEventHandles .. $];
            } else {
                threadState.nextEventHandles = tempHandles;
                threadState.nextEventProcs = tempProcs;

                tempHandles = typeof(tempHandles).init;
                tempProcs = typeof(tempProcs).init;
            }
        }
    }

    {
        // step four: start up new threads to complete the handles

        while (tempHandles.length > 0) {
            auto gotThread = Thread.create(&threadStartProc);
            if (!gotThread) {
                logger.error("Thread failed to be created, stopping event waiting updating", gotThread.getError());
                break;
            }

            eventWaiterThreads[gotThread.get] = EventWaiterThread.init;

            auto threadState = eventWaiterThreads[gotThread.get];
            threadState.thread = gotThread.get;

            if (tempHandles.length > maxEventHandles) {
                threadState.eventHandles = tempHandles[0 .. maxEventHandles];
                threadState.eventProcs = tempProcs[0 .. maxEventHandles];

                tempHandles = tempHandles[maxEventHandles .. $];
                tempProcs = tempProcs[maxEventHandles .. $];
            } else {
                threadState.eventHandles = tempHandles;
                threadState.eventProcs = tempProcs;

                tempHandles = typeof(tempHandles).init;
                tempProcs = typeof(tempProcs).init;
            }
        }
    }

    triggerUpdatesOnThreads(oldThreadCount);
    eventWaiterMutex.unlock;
}

void threadStartProc() @trusted {
    auto lockError = eventWaiterMutex.lock;
    assert(lockError);

    auto threadState = eventWaiterThreads[Thread.self()];

    if (!threadState) {
        logger.error("Could not start event waiter thread, missing thread information");
        eventWaiterMutex.unlock;
        return;
    }
    eventWaiterMutex.unlock;

    threadState.ourProc();
}
