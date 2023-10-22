module sidero.eventloop.networking.internal.posix.socketserver;
import sidero.eventloop.networking.internal.state;

@safe nothrow @nogc:

alias PlatformListenSocketKey = void*;

struct PlatformListenSocket {
    shared(ptrdiff_t) isAlive;

@safe nothrow @nogc:

    this(return scope ref PlatformListenSocket other) scope {
        this.tupleof = other.tupleof;
    }
}

bool listenOnAddress(scope ListenSocketState* listenSocketState, bool reuseAddr, bool keepAlive) {
    assert(0);
}

void forceClose(scope PlatformListenSocket* listenSocketState) scope {
    assert(0);
}

void cleanup(scope PlatformListenSocket* listenSocketState) scope {
    assert(0);
}
