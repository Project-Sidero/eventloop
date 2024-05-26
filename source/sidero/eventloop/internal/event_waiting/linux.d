module sidero.eventloop.internal.event_waiting.linux;
import sidero.eventloop.internal.event_waiting;

version (linux) {
    import sidero.eventloop.internal.workers.kernelwait.linux;
}

export @safe nothrow @nogc:

bool initializeLinuxEventWaiting() {
    import sidero.eventloop.internal.workers.api;
    import sidero.base.system : operatingSystem, OperatingSystem;

    OperatingSystem os = operatingSystem();

    version (linux) {
        // EPOLLEXCLUSIVE was added in 4.5

        if ((os.major > 4 || (os.major == 4 && os.minor >= 5)) && startWorkers(0) && usesKernelWait())
            return true;
    }

    return false;
}

void addEventWaiterHandleStrategy(void* handleToWaitOn, UserEventProc proc, void* user) {
    addEpollHandleToWaitOn(cast(int)handleToWaitOn);
}

void removeEventWaiterHandleStrategy(scope void* handleToNotWaitOn) {
    removeEpollHandleToWaitOn(cast(int)handleToNotWaitOn);
}

void shutdownEventWaiterThreadsStrategy() {
}
