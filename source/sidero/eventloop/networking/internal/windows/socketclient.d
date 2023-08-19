module sidero.eventloop.networking.internal.windows.socketclient;
import sidero.eventloop.networking.internal.state.socket;
import sidero.eventloop.internal.windows.iocp;
import sidero.eventloop.internal.windows.bindings;
import sidero.eventloop.networking.sockets;
import sidero.base.containers.readonlyslice;
import sidero.base.errors;
import sidero.base.path.networking;

@safe nothrow @nogc:

struct PlatformSocket {
    version(Windows) {
        SOCKET handle;
        WSAEVENT onCloseEvent;
        OVERLAPPED readOverlapped, writeOverlapped;
        IOCPwork iocpWork;
    }

    shared(bool) isShutdown, isClosed;

@safe nothrow @nogc:
}

ErrorResult connectToSpecificAddress(Socket socket, NetworkAddress address, bool keepAlive) {
    assert(0);
}

void shutdown(scope SocketState* socketState, bool haveReferences = true) scope {
    assert(0);
}

void forceClose(scope SocketState* socketState) scope {
    assert(0);
}

bool tryWriteMechanism(scope SocketState* socketState, ubyte[] buffer) {
    assert(0);
}

bool tryReadMechanism(scope SocketState* socketState, ubyte[] buffer) {
    assert(0);
}
