module sidero.eventloop.networking.internal.windows.socketserver;
import sidero.eventloop.networking.internal.windows.socketclient;
import sidero.eventloop.networking.internal.state;

@safe nothrow @nogc:

alias PlatformListenSocketKey = void*;

struct PlatformListenSocket {
    shared(ptrdiff_t) isAlive;
@safe nothrow @nogc:

}

bool listenOnAddress(scope ListenSocketState* listenSocket, bool reuseAddr, bool keepAlive) {
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
