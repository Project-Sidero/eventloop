module sidero.eventloop.networking.internal.windows.socket_server;
import sidero.eventloop.networking.internal.state;

@safe nothrow @nogc:

version (Windows) {
    bool listenOnAddress(ListenSocketState* listenSocketState, bool reuseAddr, bool keepAlive) @trusted {
        assert(0);
    }
}
