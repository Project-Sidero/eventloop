module sidero.eventloop.internal.workers.userland.api;

version (Posix) {
    public import sidero.eventloop.internal.workers.userland.posix;
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

alias initializeWorkerMechanism = initializeWorkerPlatformMechanism;
alias shutdownWorkerMechanism = shutdownWorkerPlatformMechanism;
