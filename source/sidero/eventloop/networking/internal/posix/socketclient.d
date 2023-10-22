module sidero.eventloop.networking.internal.posix.socketclient;
import sidero.eventloop.networking.internal.state;
import sidero.eventloop.networking.sockets;
import sidero.base.errors;
import sidero.base.path.networking;

@safe nothrow @nogc:

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
