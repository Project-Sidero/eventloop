module sidero.eventloop.networking.internal.state.rawwriting;
import sidero.eventloop.networking.internal.state.defs;
import sidero.eventloop.networking.internal.state.socket;
import sidero.eventloop.threads.osthread;
import sidero.base.containers.queue.concurrentqueue;
import sidero.base.containers.readonlyslice;

struct RawWritingState {
    package(sidero.eventloop.networking.internal) {
        FiFoConcurrentQueue!(Slice!ubyte) queue;
    }

    private {
        bool triggered;
        size_t amountFromFirst;
    }

@safe nothrow @nogc:

    // NOTE: this needs guarding
    bool inProgress() scope {
        return triggered || !queue.empty;
    }

    package(sidero.eventloop.networking.internal.state) bool tryWrite(scope SocketState* socketState) scope @trusted {
        if(triggered) {
            logger.debug_("Write is currently triggered");
            return false;
        }

        for(;;) {
            auto firstItem = queue.peek;

            if(firstItem) {
                firstItem = firstItem[amountFromFirst .. $];

                if(firstItem) {
                    if(firstItem.length == 0) {
                        cast(void)queue.pop;
                        amountFromFirst = 0;
                        logger.debug_("Done with first item");
                        continue;
                    } else {
                        logger.debug_("Attempting to write ", firstItem.length, " with offset ", amountFromFirst,
                                " items to socket ", socketState.handle, " on thread ", Thread.self);
                        triggered = true;
                        bool result = socketState.tryWrite(cast(ubyte[])firstItem.unsafeGetLiteral);

                        if(result) {
                            logger.debug_("Have triggered ", firstItem.length, " items to socket ", socketState.handle,
                                    " on thread ", Thread.self);
                            return true;
                        } else {
                            logger.info("Have failed to trigger ", firstItem.length, " items to socket ",
                                    socketState.handle, " on thread ", Thread.self);
                            triggered = false;
                            return false;
                        }
                    }
                } else {
                    return false;
                }
            } else {
                logger.debug_("Empty raw write queue");
                return false;
            }
        }

        assert(0);
    }

    // NOTE: this needs guarding
    void complete(scope SocketState* socketState, size_t completedAmount) scope @trusted {
        auto firstItem = queue.peek;
        triggered = false;

        if(!firstItem) {
            logger.info("Received notification of written data but no data was waiting for write ", completedAmount,
                    " on socket ", socketState.handle, " on thread ", Thread.self);
            amountFromFirst = 0;
            return;
        }

        logger.debug_("Received notification of written data for amount ", completedAmount, " on socket ",
                socketState.handle, " on thread ", Thread.self);

        const proposedAmount = amountFromFirst + completedAmount;

        if(proposedAmount < firstItem.length) {
            amountFromFirst = completedAmount;
        } else {
            cast(void)queue.pop;
            amountFromFirst = 0;
        }
    }
}
