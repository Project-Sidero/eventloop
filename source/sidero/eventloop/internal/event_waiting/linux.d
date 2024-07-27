module sidero.eventloop.internal.event_waiting.linux;
import sidero.eventloop.internal.event_waiting;

version(linux) {
    import sidero.eventloop.internal.workers.kernelwait.linux;
}

export @safe nothrow @nogc:

bool initializeLinuxEventWaiting() {
    import sidero.eventloop.internal.workers.api;
    import sidero.base.system : operatingSystem, OperatingSystem;

    OperatingSystem os = operatingSystem();

    version(linux) {
        // EPOLLEXCLUSIVE was added in 4.5

        if((os.major > 4 || (os.major == 4 && os.minor >= 5)) && checkWorkerInit() && usesKernelWait())
            return true;
    }

    return false;
}

void addEventWaiterHandleStrategy(void* handleToWaitOn, UserEventProc proc, void* user) {
    version(linux) {
        addEpollHandleToWaitOn(cast(int)handleToWaitOn);
    } else
        assert(0);
}

void removeEventWaiterHandleStrategy(scope void* handleToNotWaitOn) {
    version(linux) {
        removeEpollHandleToWaitOn(cast(int)handleToNotWaitOn);
    } else
        assert(0);
}

void shutdownEventWaiterThreadsStrategy() {
    version(linux) {
    } else
        assert(0);
}
