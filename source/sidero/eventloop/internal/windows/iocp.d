module sidero.eventloop.internal.windows.iocp;
import sidero.eventloop.networking.sockets;

version (Windows) {
    import sidero.eventloop.internal.windows.bindings;
    import core.sys.windows.windows : HANDLE;

@safe nothrow @nogc:

    bool initializeWorkerMechanism(size_t count) {
        return false;
    }

    void shutdownWorkerMechanism() {
    }

    bool associateWithIOCP(Socket socket) @trusted {
        assert(0);
    }

    package(sidero.eventloop.internal) void workerProc() {
    }
}
