module sidero.eventloop.internal.pipes.rawreading;
import sidero.eventloop.threads.osthread;
import sidero.base.containers.dynamicarray;
import sidero.base.logger;
import sidero.base.allocators;

package(sidero.eventloop):

struct RawReadingState(StateObject, string TitleOfPipe) {
    private {
        DynamicArray!ubyte buffer;
        size_t toConsume, amountFilled, amountPrepared;
        bool triggered;

        LoggerReference logger;
    }

package(sidero.eventloop):
@safe nothrow @nogc:

    ~this() scope {
    }

    bool initialize() scope @trusted {
        import sidero.base.text;

        logger = Logger.forName(String_UTF8(__MODULE__ ~ "$" ~ TitleOfPipe));

        if(!logger || logger.isNull)
            return false;


        buffer = DynamicArray!ubyte(RCAllocator.init);
        return true;
    }

    // NOTE: this needs guarding
    bool inProgress() scope {
        return triggered;
    }

    // NOTE: this needs guarding
    bool tryRead(scope StateObject* stateObject) scope @trusted {
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

        const toRead = stateObject.amountToRead;
        const oldLength = buffer.length;

        if(oldLength < amountFilled + toRead) {
            buffer.length = amountFilled + toRead;
            amountPrepared = toRead;
        }

        triggered = true;
        if(attemptRead(stateObject)) {
            return true;
        } else {
            if(stateObject.attemptReadLater) {
                stateObject.delayReadForLater;
                return true;
            } else {
                logger.debug_("Failed to setup up raw reading for " ~ TitleOfPipe ~ " with a buffer of ", toRead, " for a length of ",
                        buffer.length, " from ", oldLength, " for socket ", stateObject.readHandle, " on thread ", Thread.self);
                triggered = false;
                return false;
            }
        }
    }

    // NOTE: this needs guarding
    bool attemptRead(scope StateObject* stateObject) scope @trusted {
        if(!triggered)
            return false;

        auto slice = buffer.unsafeGetLiteral;

        if(stateObject.tryRead(slice[amountFilled .. $])) {
            logger.debug_("Successfully performed raw reading for " ~ TitleOfPipe ~ " for a length of ", buffer.length,
                    " for " ~ TitleOfPipe ~ " ", stateObject.readHandle, " on thread ", Thread.self);
            return true;
        } else
            return false;
    }

    void readRaw(scope size_t delegate(DynamicArray!ubyte data) @safe nothrow @nogc del) scope @trusted {
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
    void complete(scope StateObject* stateObject, size_t completedAmount) scope @trusted {
        import sidero.base.internal.atomic;

        triggered = false;
        stateObject.notifiedOfReadComplete(stateObject);

        if(completedAmount > amountPrepared) {
            assert(logger);
            logger.info("Received too much data ", completedAmount, " with a prepared buffered count of ",
                    amountPrepared, " for " ~ TitleOfPipe ~ " ", stateObject.readHandle, " on thread ", Thread.self);

            return;
        }

        logger.debug_("Received data successfully ", completedAmount, " with a prepared buffered count of ",
                amountPrepared, " for " ~ TitleOfPipe ~ " ", stateObject.readHandle, " on thread ", Thread.self);

        amountFilled += completedAmount;
    }
}
