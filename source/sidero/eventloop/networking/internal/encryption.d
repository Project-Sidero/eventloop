module sidero.eventloop.networking.internal.encryption;
import sidero.eventloop.networking.internal.state;
import sidero.eventloop.networking.sockets;
import sidero.eventloop.certificates;
import sidero.base.containers.dynamicarray;

struct EncryptionState {
    package(sidero.eventloop.networking.internal) {
        Certificate currentCertificate;
        Socket.EncryptionProtocol currentProtocol;
        size_t bufferSize;

        version (Windows) {
            import sidero.eventloop.networking.internal.windows.encryption;

            EncryptionStateWinCrypt winCrypt;
        }
    }

@safe nothrow @nogc:

    void cleanup() scope {
        final switch (currentCertificate.type) {
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

    bool reinitializeEncryption(scope SocketState* socketState, Socket.EncryptionProtocol protocol) scope @trusted {
        // wanted raw & is raw
        if (currentCertificate.type == Certificate.Type.None && (protocol == Socket.EncryptionProtocol.None))
            return true;

        final switch (currentCertificate.type) {
        case Certificate.Type.None:
            // we can't actually remove encryption once added when it comes to TLS
            return false;
        case Certificate.Type.WinCrypt:
            version (Windows) {
                return winCrypt.replace(socketState, currentCertificate, protocol);
            } else
                return false;
        case Certificate.Type.Default:
            assert(0);
        }
    }

    bool reinitializeEncryption(scope SocketState* socketState, Certificate certificate, Socket.EncryptionProtocol protocol) scope @trusted {
        // wanted raw & is raw
        if (currentCertificate.type == Certificate.Type.None && (protocol == Socket.EncryptionProtocol.None ||
                certificate.type == Certificate.Type.None))
            return true;

        final switch (certificate.type) {
        case Certificate.Type.None:
            // we can't actually remove encryption once added when it comes to TLS
            return false;
        case Certificate.Type.WinCrypt:
            version (Windows) {
                if (currentCertificate.type == Certificate.Type.None) {
                    return winCrypt.add(socketState, certificate, protocol);
                } else {
                    return winCrypt.replace(socketState, certificate, protocol);
                }
            } else
                return false;
        case Certificate.Type.Default:
            assert(0);
        }
    }

    void protectRead(scope SocketState* socketState, scope size_t delegate(DynamicArray!ubyte data) @safe nothrow @nogc del) scope {
        if (currentCertificate.type == Certificate.Type.None || currentProtocol == Socket.EncryptionProtocol.None) {
            // ok we use the raw buffer directly
            socketState.rawReadingState.protectReadForEncryption(del);
            return;
        }

        final switch (currentCertificate.type) {
        case Certificate.Type.WinCrypt:
            break;

        case Certificate.Type.None:
        case Certificate.Type.Default:
            assert(0);
        }
    }

    size_t amountNeedToBeRead(scope SocketState* socketState) {
        if (currentCertificate.type == Certificate.Type.None || currentProtocol == Socket.EncryptionProtocol.None) {
            const amount = socketState.readingState.getWantedAmount();
            return amount < size_t.max ? amount : 4096;
        }

        if (this.bufferSize == 0)
            return 4096;
        else
            return this.bufferSize;
    }
}
