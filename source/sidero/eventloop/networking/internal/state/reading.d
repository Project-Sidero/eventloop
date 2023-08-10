module sidero.eventloop.networking.internal.state.reading;
import sidero.eventloop.networking.internal.state.defs;
import sidero.eventloop.networking.internal.state.socket;
import sidero.eventloop.threads.osthread;
import sidero.eventloop.coroutine.future;
import sidero.eventloop.tasks.future_completion;
import sidero.base.containers.queue.concurrentqueue;
import sidero.base.containers.readonlyslice;
import sidero.base.containers.dynamicarray;
import sidero.base.allocators;

struct ReadingState {
    package(sidero.eventloop.networking.internal) {
        // encryption needs to push
        FiFoConcurrentQueue!(Slice!ubyte) queue;
    }

    private {
        size_t amountFromFirst;

        size_t wantedAmount;
        Slice!ubyte stopArray;
        FutureTriggerStorage!(Slice!ubyte)* triggerForHandler;

        DynamicArray!ubyte appendingArray;
    }

@safe nothrow @nogc:

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

    package(sidero.eventloop.networking.internal.state) bool tryFulfillRequest(scope SocketState* socketState) scope {
        if(inProgress)
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
                auto sliced = availableData[0 .. amount];
                assert(sliced);
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
            auto availableData = firstItem.get[amountFromFirst .. $];
            assert(availableData);

            handleWithData(availableData, tryingToConsume);

            if(success) {
                if(tryingToConsume < availableData.length) {
                    amountFromFirst += tryingToConsume;
                } else {
                    amountFromFirst = 0;
                    cast(void)queue.pop;
                }
            }
        }

        if(!success && !socketState.encryption.enabled) {
            // if we don't have encryption we'll need to feed the data straight from the socket raw
            size_t tryingToConsume;

            socketState.rawReading.readRaw((availableData) {
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
