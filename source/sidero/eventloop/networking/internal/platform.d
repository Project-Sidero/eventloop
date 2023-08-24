module sidero.eventloop.networking.internal.platform;
import sidero.eventloop.networking.internal.state;
import sidero.eventloop.networking.sockets;
import sidero.base.errors;
import sidero.base.path.networking;

@safe nothrow @nogc:

version(Windows) {
    public import sidero.eventloop.networking.internal.windows.mechanism;
} else {
    bool startUpNetworkingMechanism() {
        assert(0);
    }

    void shutdownNetworkingMechanism() {
        assert(0);
    }
}

version(Windows) {
    public import sidero.eventloop.networking.internal.windows.socketclient;
} else {
    struct PlatformSocket {
        void* handle;

    @safe nothrow @nogc:
    }

    ErrorResult connectToSpecificAddress(Socket socket, NetworkAddress address, bool keepAlive) {
        assert(0);
    }

    void shutdown(scope SocketState* socketState, bool haveReferences = true) {
        assert(0);
    }

    void forceClose(scope SocketState* socketState) {
        assert(0);
    }

    bool tryWriteMechanism(scope SocketState* socketState, ubyte[] buffer) {
        assert(0);
    }

    bool tryReadMechanism(scope SocketState* socketState, ubyte[] buffer) {
        assert(0);
    }
}

version(Windows) {
    public import sidero.eventloop.networking.internal.windows.socketserver;
} else {
    alias PlatformListenSocketKey = void*;

    struct PlatformListenSocket {
        shared(ptrdiff_t) isAlive;

    @safe nothrow @nogc:

        this(return scope ref PlatformListenSocket other) scope {
            this.tupleof = other.tupleof;
        }
    }

    bool listenOnAddress(scope ListenSocket* listenSocketState, bool reuseAddr, bool keepAlive) {
        assert(0);
    }

    void forceClose(scope PlatformListenSocket* listenSocketState) scope {
        assert(0);
    }

    void cleanup(scope PlatformListenSocket* listenSocketState) scope {
        assert(0);
    }
}
