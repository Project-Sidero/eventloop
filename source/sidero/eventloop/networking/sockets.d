module sidero.eventloop.networking.sockets;
import sidero.eventloop.networking.internal.state;
import sidero.base.containers.dynamicarray;

///
alias ListenSocketOnAccept = void function(Socket) @safe nothrow  @nogc;
///
alias SocketReadCallback = void function(Socket socket, DynamicArray!ubyte data) @safe nothrow @nogc;

struct Socket {
    SocketState* state;

    enum Protocol {
        Error,
    }
}
