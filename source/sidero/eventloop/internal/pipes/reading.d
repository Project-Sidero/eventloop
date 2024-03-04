module sidero.eventloop.internal.pipes.reading;
import sidero.eventloop.threads.osthread;
import sidero.eventloop.coroutine.future;
import sidero.eventloop.tasks.future_completion;
import sidero.base.containers.queue.concurrentqueue;
import sidero.base.containers.readonlyslice;
import sidero.base.containers.dynamicarray;
import sidero.base.allocators;
import sidero.base.logger;

struct ReadingState(StateObject, string TitleOfPipe, bool SupportEncryption) {
    private {
        size_t amountFromFirst;

        size_t wantedAmount;
        Slice!ubyte stopArray;
        FutureTriggerStorage!(Slice!ubyte)* triggerForHandler;

        DynamicArray!ubyte appendingArray;

        // encryption needs to push
        FiFoConcurrentQueue!(Slice!ubyte) queue;

        LoggerReference logger;
    }

@safe nothrow @nogc:

    bool initialize() {
        import sidero.base.text;

        logger = Logger.forName(String_UTF8(__MODULE__ ~ "$" ~ TitleOfPipe));
        if(!logger)
            return false;
        return true;
    }

    // this is last resort, cleanup routine
    void cleanup() scope {
        import sidero.base.errors;

        if(triggerForHandler !is null) {
            auto got = trigger(triggerForHandler, UnknownPlatformBehaviorException("Could not complete future, socket has died"));
            triggerForHandler = null;
        }
    }

    // NOTE: needs guarding
    bool inProgress() scope {
        return triggerForHandler !is null;
    }

    // NOTE: needs guarding
    bool requestFromUser(size_t amount, out Future!(Slice!ubyte) future) scope @trusted {
        assert(amount > 0);

        if(inProgress)
            return false;

        future = acquireInstantiableFuture!(Slice!ubyte).makeInstance(RCAllocator.init, &triggerForHandler).asFuture;
        cast(void)waitOnTrigger(future, triggerForHandler);
        assert(triggerForHandler !is null);

        wantedAmount = amount;
        stopArray = typeof(stopArray).init;
        return true;
    }

    // NOTE: needs guarding
    bool requestFromUser(return scope Slice!ubyte stopCondition, out Future!(Slice!ubyte) future) scope @trusted {
        assert(stopCondition.length > 0);

        if(inProgress)
            return false;

        future = acquireInstantiableFuture!(Slice!ubyte).makeInstance(RCAllocator.init, &triggerForHandler).asFuture;
        cast(void)waitOnTrigger(future, triggerForHandler);
        assert(triggerForHandler !is null);

        stopArray = stopCondition;
        wantedAmount = 0;
        return true;
    }

    bool tryFulfillRequest(scope StateObject* stateObject) scope @trusted {
        logger.trace("Trying to fulfill a request for ", TitleOfPipe, " of ", stateObject.readHandle, " if ",
                inProgress, " with ", queue.empty, " on ", Thread.self);

        if(!inProgress)
            return false;

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
            void subsetFromAvailable(ptrdiff_t amount) @trusted {
                if(amount == 0)
                    return;

                auto sliced = availableData[0 .. amount];
                assert(sliced, sliced.getError().toString.unsafeGetLiteral());
                auto slicedG = sliced.get;

                if(appendingArray.length == 0)
                    appendingArray = typeof(appendingArray).init;
                appendingArray ~= slicedG;

                tryingToConsume = slicedG.length;
            }

            if(wantedAmount > 0 && availableData.length > 0) {
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
        } else if (!success) {
            // if we don't have encryption we'll need to feed the data straight from the stream raw
            size_t tryingToConsume;

            stateObject.rawReading.readRaw((availableData) {
                handleWithData(availableData, tryingToConsume);
                return tryingToConsume;
            });
        }

        if(success) {
            assert(toTrigger !is null);
            cast(void)trigger(toTrigger, dataToCallWith);
        } else {
            assert(toTrigger is null);
        }

        return success;
    }
}
