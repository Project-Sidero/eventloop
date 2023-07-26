module sidero.eventloop.networking.internal.state;
import sidero.eventloop.networking.internal.encryption;
import sidero.eventloop.networking.sockets;
import sidero.eventloop.certificates;
import sidero.base.synchronization.mutualexclusion;
import sidero.base.containers.list.concurrentlinkedlist;
import sidero.base.containers.dynamicarray;
import sidero.base.containers.readonlyslice;
import sidero.base.containers.map.concurrenthashmap;
import sidero.base.path.networking;
import sidero.base.allocators;
import sidero.base.errors;

package(sidero.eventloop):

version(Windows) {
    import sidero.eventloop.networking.internal.windows.socket_server;
    import sidero.eventloop.networking.internal.windows.socket_client;
    public import sidero.eventloop.networking.internal.windows.mechanism;
} else
    static assert(0, "Unimplemented");

struct ListenSocketState {
package(sidero.eventloop):

    RCAllocator allocator;
    shared(ptrdiff_t) refCount = 1;
    shared(ptrdiff_t) isAlive;

    NetworkAddress address;
    Socket.Protocol protocol;

    Certificate certificate;
    Socket.EncryptionProtocol encryption;
    bool validateCertificates;

    ListenSocketOnAccept onAcceptHandler;
    SocketShutdownCallback onShutdownHandler;

    ConcurrentHashMap!(PlatformListenSocketKey, PlatformListenSocket) platformSockets;

@safe nothrow @nogc:
    void rc(bool addRef) scope @trusted {
        import core.atomic : atomicOp, atomicLoad;

        if(addRef)
            atomicOp!"+="(refCount, 1);
        else {
            ptrdiff_t refCount = atomicOp!"-="(this.refCount, 1);

            if(refCount == 0) {
                if(atomicLoad(isAlive)) {
                    foreach(pls; platformSockets) {
                        if(pls) {
                            if(atomicLoad(pls.isAlive))
                                pls.forceClose;
                        }
                    }
                }

                foreach(pls; platformSockets) {
                    if(pls) {
                        if(atomicLoad(pls.isAlive))
                            pls.cleanup;
                    }
                }

                RCAllocator allocator = this.allocator;
                allocator.dispose(&this);
            } else if(refCount == 1 && atomicLoad(isAlive) > 0) {
                // we are pinned, but nobody knows about this socket anymore, ugh oh...
                foreach(pls; platformSockets) {
                    if(pls) {
                        if(atomicLoad(pls.isAlive))
                            pls.shutdown;
                    }
                }
            }
        }
    }

    void pin(ptrdiff_t amount) scope {
        import core.atomic : atomicLoad, atomicStore;

        if(atomicLoad(isAlive) > 0)
            assert(0, "Pinned");

        rc(true);
        atomicStore(isAlive, amount);
    }

    void unpin() scope {
        import core.atomic : atomicLoad, atomicOp;

        if(atomicLoad(isAlive) == 0)
            assert(0, "Not pinned");

        if(atomicOp!"-="(isAlive, 1) == 0)
            rc(false);
    }

    bool startUp(bool reuseAddr = true, bool keepAlive = true) scope @trusted {
        return listenOnAddress(&this, reuseAddr, keepAlive);
    }
}

struct SocketState {
package(sidero.eventloop):
    RCAllocator allocator;
    shared(ptrdiff_t) refCount = 1;
    shared(bool) isAlive;

    bool cameFromServer;
    SocketShutdownCallback onShutdownHandler;

    Socket.Protocol protocol;
    NetworkAddress localAddress, remoteAddress;

    PlatformSocket platform;
    alias platform this;

    EncryptionState encryptionState;

    ReadingState readingState;
    RawReadingState rawReadingState;
    RawWritingState rawWritingState;

@safe nothrow @nogc:

    void rc(bool addRef) scope @trusted {
        import core.atomic : atomicLoad, atomicOp;

        if(addRef)
            atomicOp!"+="(refCount, 1);
        else {
            ptrdiff_t refCount = atomicOp!"-="(this.refCount, 1);

            if(refCount == 0) {
                encryptionState.cleanup;
                platform.shutdown(&this);
                platform.forceClose(&this);

                RCAllocator allocator = this.allocator;
                allocator.dispose(&this);
            } else if(refCount == 1 && atomicLoad(isAlive)) {
                // we are pinned, but nobody knows about this socket anymore, ugh oh...
                platform.shutdown(&this);
            }
        }
    }

    void pin() scope {
        import core.atomic : atomicLoad, atomicStore;

        if(atomicLoad(isAlive))
            assert(0, "Pinned");

        rc(true);
        atomicStore(isAlive, true);
    }

    void unpin() scope @trusted {
        import core.atomic : atomicLoad, atomicStore;

        if(!atomicLoad(isAlive))
            return;

        atomicStore(isAlive, false);
        platform.shutdown(&this);
        rc(false);
    }

    void close(bool gracefully) scope @trusted {
        import core.atomic : atomicLoad, atomicStore;

        if(!atomicLoad(isAlive))
            return;

        platform.shutdown(&this);

        if(!gracefully || (rawWritingState.protect(() { return !rawWritingState.haveData; }) && !readingState.inProgress)) {
            platform.forceClose(&this);
            atomicStore(isAlive, false);
            rc(false);
        }
    }

    ErrorResult startUp(NetworkAddress address, bool keepAlive = true) scope @trusted {
        Socket socket;
        socket.state = &this;
        this.rc(true);
        return connectToSpecificAddress(socket, address, keepAlive);
    }
}

struct ReadingState {
    TestTestSetLockInline mutex;
    size_t wantedAmount;
    Slice!ubyte stopArray;
    SocketReadCallback toCall;

    // only needed if it takes multiple read responses to complete
    DynamicArray!ubyte appendingArray;
@safe nothrow @nogc:

    bool inProgress() scope {
        mutex.pureLock;
        scope(exit)
            mutex.unlock;

        return toCall !is null;
    }

    size_t getWantedAmount() {
        if(!inProgress)
            return 0;

        mutex.pureLock;
        scope(exit)
            mutex.unlock;

        return wantedAmount > 0 ? wantedAmount : size_t.max;
    }

    bool requestFromUser(size_t amount, SocketReadCallback callback) scope {
        assert(amount > 0);
        assert(callback !is null);

        if(inProgress)
            return false;

        mutex.pureLock;
        scope(exit)
            mutex.unlock;

        toCall = callback;
        wantedAmount = amount;
        stopArray = typeof(stopArray).init;
        return true;
    }

    bool requestFromUser(Slice!ubyte stopCondition, SocketReadCallback callback) scope {
        assert(stopCondition.length > 0);
        assert(callback !is null);

        if(inProgress)
            return false;

        mutex.pureLock;
        scope(exit)
            mutex.unlock;

        toCall = callback;
        stopArray = stopCondition;
        wantedAmount = 0;

        return true;
    }

    bool tryFulfillRequest(scope SocketState* socketState) scope @trusted {
        import core.atomic : atomicLoad;

        // ok what is the source of our buffers?
        // we work through the encryption API, so it can figure it out if we are reading directly or not

        bool success;
        SocketReadCallback calling;
        Slice!ubyte dataToCallWith;

        socketState.encryptionState.readData(socketState, (DynamicArray!ubyte availableData) @trusted {
            if(toCall is null)
                return 0;

            size_t tryingToConsume;

            bool checkIfStop(ptrdiff_t start1, ptrdiff_t end1, ptrdiff_t start2, ptrdiff_t end2) {
                auto first = appendingArray[start1 .. end1];
                if(!first)
                    return false;

                auto second = stopArray[start2 .. end2];
                if(!second)
                    return false;

                return first.get == second.get;
            }

            void subsetFromAvailable(ptrdiff_t amount) {
                auto sliced = availableData[0 .. amount];
                assert(sliced);
                auto slicedG = sliced.get;

                if(appendingArray.length == 0)
                    appendingArray = slicedG.dup;
                else
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
                assert(toCall !is null);
                calling = toCall;
                toCall = null;

                dataToCallWith = appendingArray.asReadOnly();
                appendingArray = typeof(appendingArray).init;

                return tryingToConsume;
            } else
                return 0;
        });

        if(success) {
            assert(calling !is null);

            Socket socket;
            socket.state = socketState;
            socket.state.rc(true);

            calling(socket, dataToCallWith);
        } else {
            assert(calling is null);

            if(!socketState.rawReadingState.protectTriggeringOfRead(() {
                    return socketState.rawReadingState.currentlyTriggered;
                }) && atomicLoad(socketState.isAlive)) {
                socketState.triggerRead(socketState, false);
            }
        }

        return success;
    }
}

struct RawReadingState {
    TestTestSetLockInline mutex;
    DynamicArray!ubyte bufferToReadInto, currentlyAvailableData;
    bool currentlyTriggered;

@safe nothrow @nogc:

    bool haveDataToRead() scope {
        mutex.pureLock;
        scope(exit)
            mutex.unlock;

        return currentlyAvailableData.length > 0;
    }

    void prepareBufferFor(size_t amount) scope @trusted {
        auto fullArray = bufferToReadInto.unsafeGetLiteral();
        auto sliced = currentlyAvailableData.unsafeGetLiteral();

        if(sliced !is null && sliced.ptr !is fullArray.ptr) {
            foreach(i, b; sliced) {
                fullArray[i] = b;
            }

            auto sliced2 = bufferToReadInto[0 .. sliced.length];
            assert(sliced2);
            currentlyAvailableData = sliced2.get;
        }

        const have = fullArray.length - sliced.length;
        const diff = amount - have;

        if(have < amount) {
            bufferToReadInto.length = diff + fullArray.length;
        }
    }

    void dataWasReceived(size_t amount) scope @trusted {
        mutex.pureLock;

        amount += currentlyAvailableData.length;
        if(amount > bufferToReadInto.length)
            amount = bufferToReadInto.length;

        auto sliced = bufferToReadInto[0 .. amount];
        assert(sliced);
        currentlyAvailableData = sliced;

        currentlyTriggered = false;
        mutex.unlock;
    }

    void protectReadForEncryption(scope size_t delegate(DynamicArray!ubyte data) @safe nothrow @nogc del) scope @trusted {
        mutex.pureLock;
        scope(exit)
            mutex.unlock;

        if(currentlyAvailableData.length == 0)
            return;

        size_t consumed = del(currentlyAvailableData);
        if(consumed > currentlyAvailableData.length)
            consumed = currentlyAvailableData.length;

        if(consumed > 0) {
            auto sliced = currentlyAvailableData[consumed .. $];
            assert(sliced);
            currentlyAvailableData = sliced.get;
        }
    }

    bool protectTriggeringOfRead(scope bool delegate() @safe nothrow @nogc del) scope @trusted {
        mutex.pureLock;
        scope(exit)
            mutex.unlock;

        if(this.currentlyTriggered)
            return false;

        bool result = del();
        if(result)
            this.currentlyTriggered = true;

        return result;
    }
}

struct RawWritingState {
    TestTestSetLockInline mutex;
    ConcurrentLinkedList!(Slice!ubyte) toSend;
    size_t waitingOnDataToSend;

@safe nothrow @nogc:

    void dataToSend(return scope Slice!ubyte data) scope {
        mutex.pureLock;
        toSend ~= data;
        mutex.unlock;
    }

    bool isWaitingOnDataToSend() {
        mutex.pureLock;
        scope(exit)
            mutex.unlock;

        return waitingOnDataToSend > 0;
    }

    bool protect(scope bool delegate() @safe nothrow @nogc del) scope {
        mutex.pureLock;
        scope(exit)
            mutex.unlock;

        return del();
    }

    bool haveData() scope {
        if(toSend.length == 0)
            return false;

        auto firstItem = toSend[0];
        assert(firstItem);
        return firstItem.length > 0;
    }

    void complete(size_t amount) scope {
        // already protected by mutex

        while(toSend.length > 0 && amount > 0) {
            auto firstItem = toSend[0];
            assert(firstItem);

            size_t canDo = firstItem.length;

            if(canDo > amount) {
                auto sliced = firstItem[amount .. $];
                assert(sliced);

                firstItem = sliced;
                amount = 0;
            } else {
                amount -= firstItem.length;
                toSend.remove(0, 1);
            }

            if(waitingOnDataToSend > canDo) {
                waitingOnDataToSend -= canDo;
            } else {
                waitingOnDataToSend = 0;
            }
        }
    }
}
