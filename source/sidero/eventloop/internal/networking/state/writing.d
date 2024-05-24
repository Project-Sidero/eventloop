module sidero.eventloop.internal.networking.state.writing;
import sidero.eventloop.internal.networking.state.socket;
import sidero.base.containers.queue.concurrentqueue;
import sidero.base.containers.readonlyslice;

struct WritingState {
    FiFoConcurrentQueue!(Slice!ubyte) queue;

@safe nothrow @nogc:

    ~this() {
    }

    // NOTE: this needs guarding
    void appendToQueue(scope SocketState* socketState, return scope Slice!ubyte slice) scope @trusted {
        if (socketState.encryption.enabled) {
            queue.push(slice);
        } else {
            socketState.rawWriting.push(slice);
        }
    }

    // NOTE: this needs guarding
    void reappendToQueue(scope SocketState* socketState, return scope Slice!ubyte slice) scope @trusted {
        if (socketState.encryption.enabled) {
            queue.push(slice, false);
        } else {
            socketState.rawWriting.push(slice);
        }
    }
}
