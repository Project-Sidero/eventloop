module sidero.eventloop.internal.pipes.rawwriting;
import sidero.eventloop.threads.osthread;
import sidero.base.containers.queue.concurrentqueue;
import sidero.base.containers.readonlyslice;
import sidero.base.logger;
import sidero.base.errors;

struct RawWritingState(StateObject, string TitleOfPipe) {
    private {
        FiFoConcurrentQueue!(Slice!ubyte) queue;

        LoggerReference logger;
    }

    private {
        bool triggered;
        size_t amountFromFirst;
    }

@safe nothrow @nogc:

    bool initialize() scope {
        import sidero.base.text;

        logger = Logger.forName(String_UTF8(__MODULE__ ~ "$" ~ TitleOfPipe));

        if(!logger)
            return false;
        return true;
    }

    // NOTE: this needs guarding
    void push(Slice!ubyte data) scope {
        queue.push(data);
    }

    // NOTE: this needs guarding
    Result!(Slice!ubyte) pop() scope {
        return queue.pop;
    }

    // NOTE: this needs guarding
    bool inProgress() scope {
        return triggered || !queue.empty;
    }

    bool tryWrite(scope StateObject* stateObject) scope @trusted {
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
                                " items to " ~ TitleOfPipe ~ " ", stateObject.writeHandle, " on thread ", Thread.self);
                        triggered = true;
                        bool result = stateObject.tryWrite(cast(ubyte[])firstItem.unsafeGetLiteral);

                        if(result) {
                            logger.debug_("Have triggered ", firstItem.length, " items to " ~ TitleOfPipe ~ " ",
                                    stateObject.writeHandle, " on thread ", Thread.self);
                            return true;
                        } else {
                            logger.info("Have failed to trigger ", firstItem.length, " items to " ~ TitleOfPipe ~ " ",
                                    stateObject.writeHandle, " on thread ", Thread.self);
                            triggered = false;
                            return false;
                        }
                    }
                } else {
                    return false;
                }
            } else {
                assert(logger);
                logger.debug_("Empty raw write queue");
                return false;
            }
        }

        assert(0);
    }

    // NOTE: this needs guarding
    void complete(scope StateObject* stateObject, size_t completedAmount) scope @trusted {
        auto firstItem = queue.peek;
        triggered = false;

        if(!firstItem) {
            logger.info("Received notification of written data but no data was waiting for write ", completedAmount,
                    " on " ~ TitleOfPipe ~ " ", stateObject.writeHandle, " on thread ", Thread.self);
            amountFromFirst = 0;
            return;
        }

        logger.debug_("Received notification of written data for amount ", completedAmount, " on " ~ TitleOfPipe ~ " ",
                stateObject.writeHandle, " on thread ", Thread.self);

        const proposedAmount = amountFromFirst + completedAmount;

        if(proposedAmount < firstItem.length) {
            amountFromFirst = completedAmount;
        } else {
            cast(void)queue.pop;
            amountFromFirst = 0;
        }
    }
}
