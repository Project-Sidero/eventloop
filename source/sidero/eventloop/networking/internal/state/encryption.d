module sidero.eventloop.networking.internal.state.encryption;
import sidero.eventloop.networking.internal.state.socket;
import sidero.eventloop.networking.sockets;
import sidero.eventloop.certificates;
import sidero.base.path.hostname;
import sidero.base.containers.readonlyslice;
import sidero.base.containers.dynamicarray;

version(none) {
    struct EncryptionStateImpl {
    @safe nothrow @nogc:

        bool add(scope SocketState* socketState, Hostname sniHostname, Certificate certificate,
                Socket.EncryptionProtocol protocol, bool validateCertificates, Slice!Certificate sniCertificates) scope @trusted {
            assert(0);
        }

        Slice!ubyte encrypt(scope SocketState* socketState, return scope Slice!ubyte decrypted) scope {
            assert(0);
        }

        Slice!ubyte decrypt(scope SocketState* socketState, return scope DynamicArray!ubyte encrypted, out size_t consumed) scope {
            assert(0);
        }

        bool negotiate(scope SocketState* socketState) scope {
            assert(0);
        }

        void cleanup(scope SocketState* socketState) scope {
            assert(0);
        }
    }
}

struct EncryptionState {
    package(sidero.eventloop.networking.internal) {
        Certificate.Type encryptionEngine;
        Certificate currentCertificate;
        Socket.EncryptionProtocol currentProtocol;
        size_t bufferSize;

        Slice!Certificate currentSNICertificates;

        version(Windows) {
            import sidero.eventloop.networking.internal.windows.encryption.state;

            EncryptionStateWinCrypt winCrypt;
        }
    }

    bool enabled;
    bool negotiating;

@safe nothrow @nogc:

    size_t amountOfBytesToRead() {
        return bufferSize > 0 ? bufferSize : 4096;
    }

    bool addEncryption(scope SocketState* socketState, Hostname sniHostname, Certificate certificate,
            Socket.EncryptionProtocol protocol, bool validateCertificates, Slice!Certificate sniCertificates = Slice!Certificate.init) scope @trusted {
        // wanted raw & is raw
        if(encryptionEngine == Certificate.Type.None && (protocol == Socket.EncryptionProtocol.None &&
                certificate.type == Certificate.Type.None))
            return true;
        else if(!currentCertificate.isNull || currentProtocol != Socket.EncryptionProtocol.None)
            return false;

        final switch(certificate.type) {
        case Certificate.Type.None:
            version(Windows) {
                goto case Certificate.Type.WinCrypt;
            } else
                return false;
        case Certificate.Type.WinCrypt:
            version(Windows) {
                foreach(cert; sniCertificates) {
                    if(cert.type != Certificate.Type.WinCrypt)
                        return false;
                }

                return winCrypt.add(socketState, sniHostname, certificate, protocol, validateCertificates, sniCertificates);
            } else
                return false;
        case Certificate.Type.Default:
            assert(0);
        }
    }

    bool negotiate(scope SocketState* socketState) scope {
        assert(enabled);
        assert(negotiating);

        final switch(encryptionEngine) {
        case Certificate.Type.None:
        case Certificate.Type.Default:
            return false;

        case Certificate.Type.WinCrypt:
            return winCrypt.negotiate(socketState);
        }
    }

    bool encryptDecrypt(scope SocketState* socketState) scope {
        assert(enabled);
        assert(!negotiating);
        bool ret, didSomething;

        do {
            ret = ret || didSomething;
            didSomething = false;

            {
                auto got = socketState.writing.queue.pop;
                if(got) {
                    final switch(encryptionEngine) {
                    case Certificate.Type.None:
                    case Certificate.Type.Default:
                        break;

                    case Certificate.Type.WinCrypt:
                        auto encrypted = winCrypt.encrypt(socketState, got.get);
                        if(encrypted.length > 0) {
                            socketState.rawWriting.queue.push(encrypted);
                            didSomething = true;
                        }
                        break;
                    }
                }
            }

            {
                socketState.rawReading.readRaw((encrypted) {
                    size_t consumed;

                    final switch(encryptionEngine) {
                    case Certificate.Type.None:
                    case Certificate.Type.Default:
                        break;

                    case Certificate.Type.WinCrypt:
                        auto decrypted = winCrypt.decrypt(socketState, encrypted, consumed);
                        if(consumed > 0) {
                            socketState.reading.queue.push(decrypted);
                            didSomething = true;
                        }
                        break;
                    }

                    return consumed;
                });
            }
        }
        while(didSomething);

        return ret;
    }

    void cleanup(scope SocketState* socketState) scope {
        final switch(encryptionEngine) {
        case Certificate.Type.None:
        case Certificate.Type.Default:
            break;

        case Certificate.Type.WinCrypt:
            winCrypt.cleanup(socketState);
            break;
        }
    }
}
