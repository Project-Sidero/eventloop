module sidero.eventloop.networking.internal.windows.socketserver;
import sidero.eventloop.networking.internal.windows.socketclient;
import sidero.eventloop.networking.internal.state;
import sidero.eventloop.internal.windows.bindings;
import sidero.base.path.networking;

@safe nothrow @nogc:

alias PlatformListenSocketKey = void*;

struct PlatformListenSocket {
    version(Windows) {
        SOCKET handle;
        WSAEVENT eventHandle;
    }

    shared(ptrdiff_t) isAlive;
    NetworkAddress address;

@safe nothrow @nogc:

    this(return scope ref PlatformListenSocket other) scope {
        this.tupleof = other.tupleof;
    }
}

void forceClose(scope PlatformListenSocket* socketState) scope @trusted {
    version(Windows) {
        closesocket(socketState.handle);
    } else
        assert(0);
}

void cleanup(scope PlatformListenSocket* socketState) scope @trusted {
    version(Windows) {
        CloseHandle(socketState.eventHandle);
    } else
        assert(0);
}

bool listenOnAddress(scope ListenSocketState* listenSocket, bool reuseAddr, bool keepAlive) {
    assert(0);
}
