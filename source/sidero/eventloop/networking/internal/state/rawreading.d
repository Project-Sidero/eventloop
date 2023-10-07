module sidero.eventloop.networking.internal.state.rawreading;
import sidero.eventloop.networking.internal.state.defs;
import sidero.eventloop.networking.internal.state.socket;
import sidero.base.containers.dynamicarray;
import sidero.eventloop.threads.osthread;

struct RawReadingState {
    private {
        DynamicArray!ubyte buffer;
        size_t toConsume, amountFilled, amountPrepared;
        bool triggered;
    }

@safe nothrow @nogc:

    // NOTE: this needs guarding
    bool inProgress() scope {
        return triggered;
    }

    package(sidero.eventloop.networking.internal.state) bool tryRead(scope SocketState* socketState) scope @trusted {
        import std.algorithm : max;

        if(triggered)
            return false;

        // we are not currently triggered so it is safe to shift left the buffer
        if(toConsume > 0) {
            auto full = buffer.unsafeGetLiteral;
            auto filled = full[toConsume .. toConsume + amountFilled];

            foreach(i, b; filled) {
                full[i] = b;
            }

            toConsume = 0;
        }

        const toRead = max(socketState.encryption.amountOfBytesToRead(), 4096);
        const oldLength = buffer.length;

        if(oldLength < amountFilled + toRead) {
            buffer.length = amountFilled + toRead;
            amountPrepared = toRead;
        }

        auto slice = buffer.unsafeGetLiteral;

        triggered = true;
        if(socketState.tryRead(slice[amountFilled .. $])) {
            logger.debug_("Successfully set up raw reading for socket with a buffer of ", toRead, " for a length of ",
                    buffer.length, " from ", oldLength, " for socket ", socketState.handle, " on thread ", Thread.self);
            return true;
        } else {
            logger.debug_("Failed to setup up raw reading for socket with a buffer of ", toRead, " for a length of ",
                    buffer.length, " from ", oldLength, " for socket ", socketState.handle, " on thread ", Thread.self);
            triggered = false;
            return false;
        }
    }

    package(sidero.eventloop.networking.internal) void readRaw(scope size_t delegate(DynamicArray!ubyte data) @safe nothrow @nogc del) scope @trusted {
        if(amountFilled == 0) {
            del(DynamicArray!ubyte.init);
            return;
        }

        auto available = buffer[toConsume .. toConsume + amountFilled];
        if(!available) {
            del(DynamicArray!ubyte.init);
            return;
        }

        size_t consumed = del(available);
        if(consumed > available.length)
            consumed = available.length;

        // don't shift left here
        // we could be triggered and we'll lose data being received if we do that
        amountFilled -= consumed;
        toConsume += consumed;
    }

    // NOTE: this needs guarding
    void complete(scope SocketState* socketState, size_t completedAmount) scope @trusted {
        import sidero.base.internal.atomic;
        triggered = false;

        if(completedAmount > amountPrepared) {
            logger.info("Received too much data ", completedAmount, " with a prepared buffered count of ",
                    amountPrepared, " for socket ", socketState.handle, " on thread ", Thread.self);
            return;
        }

        logger.debug_("Received data successfully ", completedAmount, " with a prepared buffered count of ",
                amountPrepared, " for socket ", socketState.handle, " on thread ", Thread.self);

        amountFilled += completedAmount;
    }
}
