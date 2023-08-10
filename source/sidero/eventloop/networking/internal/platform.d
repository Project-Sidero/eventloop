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

        bool tryWriteMechanism(scope SocketState* socketState, ubyte[] buffer) scope {
            assert(0);
        }

        bool tryReadMechanism(scope SocketState* socketState, ubyte[] buffer) scope {
            assert(0);
        }
    }

    ErrorResult connectToSpecificAddress(Socket socket, NetworkAddress address, bool keepAlive) {
        assert(0);
    }

    void shutdown(scope SocketState* socketState, bool haveReferences = true) {
        assert(0);
    }

    void forceClose(scope SocketState* socketState) scope {
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

    }

    bool listenOnAddress(scope ListenSocket* listenSocket, bool reuseAddr, bool keepAlive) {
        assert(0);
    }

    void shutdown(scope PlatformListenSocket* socketState, bool haveReferences = true) {
        assert(0);
    }

    void forceClose(scope PlatformListenSocket* socketState) scope {
        assert(0);
    }

    void cleanup(scope PlatformListenSocket* socketState) scope {
        assert(0);
    }
}
