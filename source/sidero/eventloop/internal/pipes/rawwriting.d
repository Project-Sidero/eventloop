module sidero.eventloop.internal.pipes.rawwriting;
import sidero.eventloop.threads.osthread;
import sidero.eventloop.coroutine;
import sidero.eventloop.coroutine.future_completion;
import sidero.base.allocators;
import sidero.base.containers.queue.concurrentqueue;
import sidero.base.containers.readonlyslice;
import sidero.base.logger;
import sidero.base.errors;

struct QueuedWrite {
    Slice!ubyte data;
    ulong position;
    FutureTriggerStorage!void* toTrigger;

@safe nothrow @nogc:

    this(scope ref QueuedWrite other) scope @trusted {
        this.tupleof = other.tupleof;
    }

    void opAssign(scope QueuedWrite other) scope {
        this.__ctor(other);
    }
}

struct RawWritingState(StateObject, string TitleOfPipe) {
    private {
        FiFoConcurrentQueue!QueuedWrite queue;

        LoggerReference logger;
    }

    private {
        bool triggered;
        size_t amountFromFirst;
    }

@safe nothrow @nogc:

     ~this() scope {
    }

    bool initialize() scope {
        import sidero.base.text;

        logger = Logger.forName(String_UTF8(__MODULE__ ~ "$" ~ TitleOfPipe));

        if(!logger || logger.isNull)
            return false;
        return true;
    }

    // NOTE: this needs guarding
    void push(Slice!ubyte data, long position = 0) scope {
        queue.push(QueuedWrite(data, position));
    }

    // NOTE: this needs guarding
    void push(Slice!ubyte data, long position, out GenericCoroutine onCompletionCo) scope @trusted {
        FutureTriggerStorage!void* triggerForHandler;

        auto ifu = acquireInstantiableFuture!void;
        auto future = ifu.makeInstance(RCAllocator.init, &triggerForHandler);
        assert(!future.isNull);

        cast(void)waitOnTrigger(future, triggerForHandler);
        assert(triggerForHandler !is null);

        queue.push(QueuedWrite(data, position, triggerForHandler));
        onCompletionCo = future.asGeneric;
    }

    // NOTE: this needs guarding
    Result!QueuedWrite pop() scope {
        return queue.pop;
    }

    // NOTE: this needs guarding
    bool inProgress() scope {
        return triggered || !queue.empty;
    }

    bool tryWrite(scope StateObject* stateObject) scope @trusted {
        if(!logger || logger.isNull)
            return false;

        if(triggered) {
            logger.debug_("Write is currently triggered");
            return false;
        }

        for(;;) {
            auto firstItem = queue.peek;

            if(firstItem) {
                auto firstItemData = firstItem.data[amountFromFirst .. $];

                if(firstItemData) {
                    if(firstItemData.length == 0) {
                        cast(void)queue.pop;
                        amountFromFirst = 0;
                        logger.debug_("Done with first item");

                        continue;
                    } else {
                        logger.debug_("Attempting to write ", firstItemData.length, " with offset ", amountFromFirst,
                                " items to " ~ TitleOfPipe ~ " ", stateObject.writeHandle, " on thread ", Thread.self);
                        triggered = true;
                        bool result = stateObject.tryWrite(cast(ubyte[])firstItemData.unsafeGetLiteral,
                                firstItem.position + amountFromFirst);

                        if(result) {
                            logger.debug_("Have triggered ", firstItemData.length, " items to " ~ TitleOfPipe ~ " ",
                                    stateObject.writeHandle, " on thread ", Thread.self);
                            return true;
                        } else {
                            logger.info("Have failed to trigger ", firstItemData.length,
                                    " items to " ~ TitleOfPipe ~ " ", stateObject.writeHandle, " on thread ", Thread.self);
                            triggered = false;
                            return false;
                        }
                    }
                } else {
                    return false;
                }
            } else {
                assert(logger && !logger.isNull);
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

        if(proposedAmount < firstItem.data.length) {
            amountFromFirst = completedAmount;
        } else {
            auto got = queue.pop;
            assert(got);

            if(got.toTrigger !is null) {
                auto errorResult = trigger(got.toTrigger);

                if(!errorResult)
                    logger.info("Failed to trigger future completion of write due to ", errorResult,
                            " on " ~ TitleOfPipe ~ " ", stateObject.writeHandle, " on thread ", Thread.self);
            }

            amountFromFirst = 0;
        }
    }
}
