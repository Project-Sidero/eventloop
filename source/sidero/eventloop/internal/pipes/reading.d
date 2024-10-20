module sidero.eventloop.internal.pipes.reading;
import sidero.eventloop.threads.osthread;
import sidero.eventloop.coroutine.future;
import sidero.eventloop.coroutine.future_completion;
import sidero.base.containers.queue.concurrentqueue;
import sidero.base.containers.readonlyslice;
import sidero.base.containers.dynamicarray;
import sidero.base.allocators;
import sidero.base.logger;
import sidero.base.internal.logassert;
import sidero.base.errors;

struct ReadingState(StateObject, string TitleOfPipe, bool SupportEncryption) {
    private {
        size_t amountFromFirst;

        bool wantedAChunk;
        Slice!ubyte stopArray;

        FutureTriggerStorage!(Slice!ubyte)* triggerForHandler;
        bool giveDataOnEOF;

        DynamicArray!ubyte appendingArray;

        // encryption needs to push
        FiFoConcurrentQueue!(Slice!ubyte) queue;

        LoggerReference logger;
    }

    package(sidero.eventloop) {
        size_t wantedAmount;
    }

@safe nothrow @nogc:

     ~this() scope {
    }

    bool initialize() {
        import sidero.base.text;

        logger = Logger.forName(String_UTF8(__MODULE__ ~ "$" ~ TitleOfPipe));
        if(!logger || logger.isNull)
            return false;
        return true;
    }

    // this is last resort, cleanup routine
    void cleanup(scope StateObject* stateObject) scope {
        this.rawReadFailed(stateObject, true);

        if(triggerForHandler !is null) {
            auto got = trigger(triggerForHandler, UnknownPlatformBehaviorException("Could not complete future, " ~ TitleOfPipe ~ " has died"));
            triggerForHandler = null;
        }

        this.appendingArray = typeof(this.appendingArray).init;
        this.queue = typeof(this.queue).init;
        this.amountFromFirst = 0;
    }

    // NOTE: needs guarding
    bool inProgress() scope {
        return triggerForHandler !is null;
    }

    void push(Slice!ubyte data) scope {
        queue.push(data);
    }

    // NOTE: needs guarding
    bool requestFromUserChunk(out Future!(Slice!ubyte) future) scope @trusted {
        if(inProgress)
            return false;

        auto ifu = acquireInstantiableFuture!(Slice!ubyte);
        future = ifu.makeInstance(RCAllocator.init, &triggerForHandler);
        assert(!future.isNull);

        cast(void)waitOnTrigger(future, triggerForHandler);
        assert(triggerForHandler !is null);

        stopArray = typeof(stopArray).init;
        wantedAmount = 0;
        wantedAChunk = true;
        return true;
    }

    // NOTE: needs guarding
    bool requestFromUser(size_t amount, out Future!(Slice!ubyte) future) scope @trusted {
        assert(amount > 0);

        if(inProgress)
            return false;

        auto ifu = acquireInstantiableFuture!(Slice!ubyte);
        future = ifu.makeInstance(RCAllocator.init, &triggerForHandler);
        assert(!future.isNull);

        cast(void)waitOnTrigger(future, triggerForHandler);
        assert(triggerForHandler !is null);

        wantedAmount = amount;
        stopArray = typeof(stopArray).init;
        wantedAChunk = false;
        this.giveDataOnEOF = true;
        return true;
    }

    // NOTE: needs guarding
    bool requestFromUser(return scope Slice!ubyte stopCondition, bool giveDataOnEOF, out Future!(Slice!ubyte) future) scope @trusted {
        assert(stopCondition.length > 0);

        if(inProgress)
            return false;

        auto ifu = acquireInstantiableFuture!(Slice!ubyte);
        future = ifu.makeInstance(RCAllocator.init, &triggerForHandler);
        assert(!future.isNull);

        cast(void)waitOnTrigger(future, triggerForHandler);
        assert(triggerForHandler !is null);

        stopArray = stopCondition;
        wantedAmount = 0;
        wantedAChunk = false;
        this.giveDataOnEOF = giveDataOnEOF;
        return true;
    }

    // NOTE: needs guarding
    bool tryFulfillRequest(scope StateObject* stateObject) scope @trusted {
        logger.trace("Trying to fulfill a request for ", TitleOfPipe, " of ", stateObject.readHandle, " if ",
                inProgress, " with ", queue.empty, " wants chunk? ", this.wantedAChunk, " give on EOF? ",
                this.giveDataOnEOF, " on ", Thread.self);

        if(!inProgress)
            return false;

        if(appendingArray.isNull)
            appendingArray = DynamicArray!ubyte(globalAllocator());

        bool checkIfStop(ptrdiff_t start1, ptrdiff_t end1, ptrdiff_t start2, ptrdiff_t end2) @trusted {
            auto first = appendingArray[start1 .. end1];
            if(!first)
                return false;

            auto second = stopArray[start2 .. end2];
            if(!second)
                return false;

            return first.get == second.get;
        }

        FutureTriggerStorage!(Slice!ubyte)* toTrigger;
        Slice!ubyte dataToCallWith;
        bool success;

        void handleWithData(AD)(scope AD availableData, scope ref size_t tryingToConsume) @safe {
            if(availableData.isNull) // nothing we can do
                return;

            void subsetFromAvailable(ptrdiff_t amount) @trusted {
                if(amount == 0)
                    return;

                auto sliced = availableData[0 .. amount];
                logAssert(cast(bool)sliced, null, sliced.getError());
                auto slicedG = sliced.get;

                appendingArray ~= slicedG;
                tryingToConsume = slicedG.length;
            }

            if(wantedAChunk) {
                subsetFromAvailable(availableData.length);
                success = availableData.length > 0;
            } else if(wantedAmount > 0 && availableData.length > 0) {
                const canDo = wantedAmount > availableData.length ? availableData.length : wantedAmount;

                subsetFromAvailable(canDo);
                wantedAmount -= canDo;
                success = wantedAmount == 0;
            } else if(wantedAmount == 0 && stopArray.length > 0) {
                // ok stop condition is a little more complicated...

                size_t maxInFirst = stopArray.length - 1;
                if(maxInFirst > appendingArray.length)
                    maxInFirst = appendingArray.length;

                foreach(i; appendingArray.length - maxInFirst .. appendingArray.length) {
                    const amountToCheck = appendingArray.length - i;

                    if(checkIfStop(i, ptrdiff_t.max, 0, amountToCheck)) {
                        // ok existing in buffer ok, next up gotta check what has already been read
                        const inSecond = stopArray.length - amountToCheck;

                        if(inSecond <= availableData.length && checkIfStop(0, inSecond, amountToCheck, ptrdiff_t.max)) {
                            subsetFromAvailable(inSecond);
                            stopArray = typeof(stopArray).init;
                            success = true;
                        }
                    }
                }

                if(!success) {
                    ptrdiff_t index = availableData.indexOf(stopArray);

                    if(index < 0) {
                        subsetFromAvailable(ptrdiff_t.max);
                    } else {
                        subsetFromAvailable(index + stopArray.length);
                        stopArray = typeof(stopArray).init;
                        success = true;
                    }
                }
            }

            if(success) {
                assert(triggerForHandler !is null);
                toTrigger = triggerForHandler;
                triggerForHandler = null;

                dataToCallWith = appendingArray.asReadOnly();
                appendingArray = typeof(appendingArray).init;
            }
        }

        // if we have encryption we'll be using the queue that it'll put the data into
        // we will try this regardless of if encryption is turned on, in case it gets turned off
        while(!success && !queue.empty) {
            size_t tryingToConsume;

            auto firstItem = queue.peek;
            assert(firstItem);
            auto availableData = firstItem.get[amountFromFirst .. $];
            assert(availableData);

            handleWithData(availableData.get, tryingToConsume);

            if(success) {
                if(tryingToConsume < availableData.length) {
                    amountFromFirst += tryingToConsume;
                } else {
                    amountFromFirst = 0;
                    cast(void)queue.pop;
                }
            }
        }

        static if(SupportEncryption) {
            if(!success && !stateObject.encryption.enabled) {
                // if we don't have encryption we'll need to feed the data straight from the stream raw
                size_t tryingToConsume;

                stateObject.rawReading.readRaw((availableData) {
                    handleWithData(availableData, tryingToConsume);
                    return tryingToConsume;
                });
            }
        } else if(!success) {
            // if we don't have encryption we'll need to feed the data straight from the stream raw
            size_t tryingToConsume;

            stateObject.rawReading.readRaw((availableData) {
                handleWithData(availableData, tryingToConsume);
                if(!success)
                    tryingToConsume = 0;
                return tryingToConsume;
            });
        }

        if(success) {
            logger.debug_("Fulfilling request of read data by ", TitleOfPipe, " of ", stateObject.readHandle,
                    " with data count ", dataToCallWith.length, " on ", Thread.self);

            assert(toTrigger !is null);
            assert(triggerForHandler is null);
            cast(void)trigger(toTrigger, dataToCallWith);
        } else {
            assert(toTrigger is null);
        }

        return success;
    }

    // NOTE: needs guarding
    void rawReadFailed(scope StateObject* stateObject, bool isEOF = false) {
        logger.debug_("A raw read failed reading on a ", TitleOfPipe, " cannot complete of ", stateObject.readHandle,
                " if ", inProgress, " wants chunk? ", this.wantedAChunk, " give on EOF? ", this.giveDataOnEOF, " on ", Thread.self);

        if(triggerForHandler is null)
            return;

        if(this.tryFulfillRequest(stateObject))
            return;

        if(wantedAChunk) {
            Slice!ubyte dataToCallWith;

            stateObject.rawReading.readRaw((availableData) {
                dataToCallWith = availableData.asReadOnly;
                return availableData.length;
            });

            if(dataToCallWith.length > 0) {
                assert(triggerForHandler !is null);
                cast(void)trigger(triggerForHandler, dataToCallWith);
            } else {
                auto got = trigger(triggerForHandler, PlatformStateNotMatchingArgument("Could not complete future, read failed"));

                if(!got) {
                    logger.info("Failed to trigger failing read ", TitleOfPipe, " of ", stateObject.readHandle,
                            " with error ", got.getError(), " on ", Thread.self);
                }
            }

            triggerForHandler = null;
            wantedAChunk = false;
        } else if(isEOF) {
            if(this.giveDataOnEOF) {
                Slice!ubyte dataToCallWith;

                stateObject.rawReading.readRaw((availableData) {
                    dataToCallWith = availableData.asReadOnly;
                    return availableData.length;
                });

                assert(triggerForHandler !is null);
                cast(void)trigger(triggerForHandler, dataToCallWith);

                triggerForHandler = null;
                wantedAmount = 0;
                this.giveDataOnEOF = false;
            } else {
                assert(triggerForHandler !is null);
                auto got = trigger(triggerForHandler, PlatformStateNotMatchingArgument("Could not complete future, stream is EOF"));
                triggerForHandler = null;

                if(!got) {
                    logger.info("Failed to trigger EOF ", TitleOfPipe, " of ", stateObject.readHandle, " with error ",
                            got.getError(), " on ", Thread.self);
                }
            }
        }
    }
}
