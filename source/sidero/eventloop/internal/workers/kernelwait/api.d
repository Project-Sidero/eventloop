module sidero.eventloop.internal.workers.kernelwait.api;

version (Windows) {
    public import sidero.eventloop.internal.workers.kernelwait.windows;
} else version (linux) {
    public import sidero.eventloop.internal.workers.kernelwait.linux;
} else {
    bool initializeWorkerPlatformMechanism(size_t count) @safe nothrow @nogc {
        return false;
    }

    void shutdownWorkerPlatformMechanism() @safe nothrow @nogc {
    }

    void triggerACoroutineMechanism(size_t count) @safe nothrow @nogc {
    }

    void workerProc() @safe nothrow @nogc {
    }
}

@safe nothrow @nogc:

alias initializeWorkerMechanism = initializeWorkerPlatformMechanism;
alias shutdownWorkerMechanism = shutdownWorkerPlatformMechanism;
