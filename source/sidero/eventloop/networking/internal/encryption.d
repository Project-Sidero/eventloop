module sidero.eventloop.networking.internal.encryption;
import sidero.eventloop.networking.internal.state;
import sidero.eventloop.networking.sockets;
import sidero.eventloop.certificates;
import sidero.base.containers.dynamicarray;
import sidero.base.containers.readonlyslice;
import sidero.base.containers.list.concurrentlinkedlist;
import sidero.base.errors;
import sidero.base.synchronization.mutualexclusion;

struct EncryptionState {
    package(sidero.eventloop.networking.internal) {
        Certificate currentCertificate;
        Certificate.Type encryptionEngine;
        Socket.EncryptionProtocol currentProtocol;
        size_t bufferSize;

        DecryptedState decryptedState;

        version (Windows) {
            import sidero.eventloop.networking.internal.windows.encryption;

            EncryptionStateWinCrypt winCrypt;
        }
    }

@safe nothrow @nogc:

    void cleanup() scope {
        final switch (encryptionEngine) {
        case Certificate.Type.None:
            break;

        case Certificate.Type.WinCrypt:
            version (Windows) {
                winCrypt.cleanup;
            }
            break;

        case Certificate.Type.Default:
            assert(0);
        }
    }

    bool addEncryption(scope SocketState* socketState, Certificate certificate, Socket.EncryptionProtocol protocol, bool validateCertificates) scope @trusted {
        // wanted raw & is raw
        if (encryptionEngine == Certificate.Type.None && (protocol == Socket.EncryptionProtocol.None &&
                certificate.type == Certificate.Type.None))
            return true;
        else if (!currentCertificate.isNull || currentProtocol != Socket.EncryptionProtocol.None)
            return false;

        final switch (certificate.type) {
        case Certificate.Type.None:
            version (Windows) {
                goto case Certificate.Type.WinCrypt;
            } else
                return false;
        case Certificate.Type.WinCrypt:
            version (Windows) {
                return winCrypt.add(socketState, certificate, protocol, validateCertificates);
            } else
                return false;
        case Certificate.Type.Default:
            assert(0);
        }
    }

    size_t amountNeedToBeRead(scope SocketState* socketState) scope {
        if (encryptionEngine == Certificate.Type.None || currentProtocol == Socket.EncryptionProtocol.None) {
            const amount = socketState.readingState.getWantedAmount();
            return (amount > 0 && amount < uint.max) ? amount : 4096;
        }

        if (this.bufferSize == 0)
            return 4096;
        else
            return this.bufferSize;
    }

    void readData(scope SocketState* socketState, scope size_t delegate(DynamicArray!ubyte data) @safe nothrow @nogc del) scope {
        if (encryptionEngine == Certificate.Type.None || currentProtocol == Socket.EncryptionProtocol.None) {
            // ok we use the raw buffer directly
            socketState.rawReadingState.protectReadForEncryption(del);
            return;
        }

        bool doneOne;

        while ((socketState.rawReadingState.haveDataToRead || decryptedState.haveDataToRead) && !doneOne) {
            final switch (encryptionEngine) {
            case Certificate.Type.WinCrypt:
                version (Windows) {
                    winCrypt.readData(socketState);
                    break;
                } else
                    assert(0);

            case Certificate.Type.None:
            case Certificate.Type.Default:
                assert(0);
            }

            doneOne = decryptedState.tryFulfillRequest(socketState, del);
        }
    }

    Expected writeData(scope SocketState* socketState, return scope Slice!ubyte data) scope @trusted {
        if (encryptionEngine == Certificate.Type.None || currentProtocol == Socket.EncryptionProtocol.None) {
            socketState.rawWritingState.dataToSend(data);
            return Expected(data.length, data.length);
        }

        final switch (encryptionEngine) {
        case Certificate.Type.WinCrypt:
            version (Windows) {
                return winCrypt.writeData(socketState, data);
            } else
                assert(0);

        case Certificate.Type.None:
        case Certificate.Type.Default:
            assert(0);
        }
    }
}

struct DecryptedState {
    TestTestSetLockInline mutex;
    ConcurrentLinkedList!(DynamicArray!ubyte) decryptedData;

@safe nothrow @nogc:

    bool haveDataToRead() scope {
        mutex.pureLock;
        scope (exit)
            mutex.unlock;

        return decryptedData.length > 0;
    }

    void addDecryptedData(return scope DynamicArray!ubyte data) {
        mutex.pureLock;

        decryptedData ~= data;

        mutex.unlock;
    }

    bool tryFulfillRequest(scope SocketState* socketState, scope size_t delegate(DynamicArray!ubyte data) @safe nothrow @nogc del) scope @trusted {
        mutex.pureLock;

        bool doneOne = decryptedData.length == 0;
        size_t handled = doneOne ? 0 : 1;

        while (decryptedData.length > 0 && handled > 0) {
            auto da = decryptedData[0];
            assert(da);

            handled = del(da.get);

            if (handled > 0) {
                auto sliced = da.get[handled .. $];
                assert(sliced);

                if (sliced.length > 0)
                    decryptedData[0] = sliced;
                else
                    decryptedData.remove(0, 1);

                doneOne = true;
            }
        }

        mutex.unlock;
        return doneOne;
    }
}
