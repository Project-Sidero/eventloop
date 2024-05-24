module sidero.eventloop.internal.networking.state.encryption;
import sidero.eventloop.internal.networking.state.defs;
import sidero.eventloop.internal.networking.state.socket;
import sidero.eventloop.sockets;
import sidero.eventloop.certificates;
import sidero.eventloop.closure.callable;
import sidero.eventloop.threads;
import sidero.base.path.hostname;
import sidero.base.containers.readonlyslice;
import sidero.base.containers.dynamicarray;
import sidero.base.text;

version (none) {
    struct EncryptionStateImpl {
    @safe nothrow @nogc:

        void acquireCredentials(scope SocketState* socketState) scope {
            assert(0);
        }

        Slice!ubyte encrypt(scope SocketState* socketState, return scope Slice!ubyte decrypted, out size_t consumed) scope {
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
    import sidero.eventloop.internal.networking.openssl : OpenSSLEncryptionStateImpl;

    package(sidero.eventloop.internal.networking) {
        Certificate.Type encryptionEngine;
        Certificate currentCertificate, fallbackCertificate;
        Socket.EncryptionProtocol currentProtocol;
        Closure!(Certificate, String_UTF8) acquireCertificateForSNI;

        bool validateCertificates;
        size_t bufferSize;

        version (Windows) {
            import sidero.eventloop.internal.networking.windows.encryption.state;

            EncryptionStateWinCrypt winCrypt;
        }

        OpenSSLEncryptionStateImpl openssl;
    }

    Hostname sniHostname;
    bool enabled;
    bool negotiating;

@safe nothrow @nogc:

    ~this() scope {
    }

    size_t amountOfBytesToRead() scope {
        // openssl uses 16kb for TLS packet size, so we'll use that here
        return bufferSize > 0 ? bufferSize : (16 * 1024);
    }

    bool addEncryption(scope SocketState* socketState, Hostname sniHostname, Certificate certificate, Closure!(Certificate,
            String_UTF8) acquireCertificateForSNI, Socket.EncryptionProtocol protocol, bool validateCertificates) scope @trusted {
        // wanted raw & is raw
        if (encryptionEngine == Certificate.Type.None && (protocol == Socket.EncryptionProtocol.None &&
                certificate.type == Certificate.Type.None))
            return true;
        else if (!currentCertificate.isNull || currentProtocol != Socket.EncryptionProtocol.None)
            return false;

        this.encryptionEngine = Certificate.Type.Default;
        this.currentCertificate = Certificate.init;

        this.fallbackCertificate = certificate;
        this.currentProtocol = protocol;
        this.acquireCertificateForSNI = acquireCertificateForSNI;
        this.validateCertificates = validateCertificates;
        this.sniHostname = sniHostname;

        this.enabled = true;
        this.negotiating = true;
        return true;
    }

    bool negotiate(scope SocketState* socketState) scope @trusted {
        assert(enabled);
        assert(negotiating);

        bool acquireContext, noDataForSNI;

        if (this.encryptionEngine == Certificate.Type.None || this.encryptionEngine == Certificate.Type.Default) {
            if (socketState.cameFromServer) {
                if (socketState.encryption.acquireCertificateForSNI.isNull) {
                    this.currentCertificate = this.fallbackCertificate;
                } else {
                    socketState.rawReading.readRaw((data) @trusted {
                        import sidero.eventloop.internal.networking.utils.tls;

                        if (data.length == 0) {
                            noDataForSNI = true;
                        } else {
                            TLS_Packet_Info tlsPacket = TLS_Packet_Info(data.unsafeGetLiteral);

                            if (tlsPacket.handshakeType == TLS_HandShake_ClientHello) {
                                const useSNI = !tlsPacket.sni.isNull;

                                if (useSNI && !socketState.encryption.acquireCertificateForSNI.isNull) {
                                    // we need to use this value as the basis for our certificate if possible
                                    this.currentCertificate = socketState.encryption.acquireCertificateForSNI(tlsPacket.sni);
                                }

                                if (this.currentCertificate.isNull)
                                    this.currentCertificate = this.fallbackCertificate;
                            }
                        }

                        return 0;
                    });
                }

                this.encryptionEngine = this.currentCertificate.type;
            } else if (fallbackCertificate.isNull) {
                // we don't have a fallback certificate, for clients this isn't an issue

                version (Windows) {
                    this.encryptionEngine = Certificate.Type.WinCrypt;
                } else {
                    this.encryptionEngine = Certificate.Type.OpenSSL;
                }
            } else {
                this.currentCertificate = this.fallbackCertificate;
                this.encryptionEngine = this.currentCertificate.type;
            }

            acquireContext = true;
        }

        if (acquireContext) {
            logger.debug_("Acquiring encryption context for socket ", socketState.handle, " for ", encryptionEngine, " on ", Thread.self);
        }

        if (noDataForSNI)
            return false;

        final switch (encryptionEngine) {
        case Certificate.Type.None:
        case Certificate.Type.Default:
            this.enabled = false;
            this.negotiating = false;

            if (sniHostname.isNull)
                logger.info("Could not acquire a certificate for encrypting socket ", socketState.handle, " on ", Thread.self);
            else
                logger.info("Could not acquire a certificate for encrypting socket ", socketState.handle,
                        " with SNI hostname ", sniHostname, " on ", Thread.self);

            socketState.close(true);
            return false;

        case Certificate.Type.WinCrypt:
            version (Windows) {
                if (acquireContext) {
                    winCrypt.acquireCredentials(socketState);
                    assert(winCrypt.credentialHandleSet);
                }

                return winCrypt.negotiate(socketState);
            } else
                assert(0);

        case Certificate.Type.OpenSSL:
            if (acquireContext) {
                openssl.acquireCredentials(socketState);
            }

            return openssl.negotiate(socketState);
        }
    }

    bool encryptDecrypt(scope SocketState* socketState) scope @trusted {
        assert(enabled);
        assert(!negotiating);
        bool ret, didSomething;

        do {
            ret = ret || didSomething;
            didSomething = false;

            {
                auto got = socketState.writing.queue.pop;
                Slice!ubyte toEncrypt;

                size_t consumed;
                Slice!ubyte encrypted;
                bool canEncrypt;

                if (got)
                    toEncrypt = got.get;

                final switch (encryptionEngine) {
                case Certificate.Type.None:
                case Certificate.Type.Default:
                    break;

                case Certificate.Type.WinCrypt:
                    version (Windows) {
                        encrypted = winCrypt.encrypt(socketState, toEncrypt, consumed);
                        canEncrypt = true;
                        break;
                    } else
                        assert(0);

                case Certificate.Type.OpenSSL:
                    encrypted = openssl.encrypt(socketState, toEncrypt, consumed);
                    assert(encrypted.isNull); // never set
                    break;
                }

                if (canEncrypt) {
                    if (encrypted.length > 0) {
                        logger.debug_("Encrypted data for socket ", socketState.handle, " as ", encrypted.length,
                                " from ", got.length, " and consumed ", consumed, " on ", Thread.self);
                        socketState.rawWriting.push(encrypted);
                        didSomething = true;
                    } else if (encrypted.length > 0) {
                        logger.debug_("Failed to encrypt data for socket ", socketState.handle, " with ",
                                toEncrypt.length, " on ", Thread.self);
                    }
                }

                if (consumed > 0 && consumed < toEncrypt.length) {
                    socketState.writing.reappendToQueue(socketState, toEncrypt[consumed .. $]);
                } else if (consumed < toEncrypt.length) {
                    socketState.writing.reappendToQueue(socketState, toEncrypt);
                }
            }

            {
                Slice!ubyte decrypted;
                size_t encryptedLength, consumed;
                bool haveDecrypted;

                socketState.rawReading.readRaw((encrypted) @trusted {
                    final switch (encryptionEngine) {
                    case Certificate.Type.None:
                    case Certificate.Type.Default:
                        break;

                    case Certificate.Type.WinCrypt:
                        version (Windows) {
                            decrypted = winCrypt.decrypt(socketState, encrypted, consumed);
                            haveDecrypted = true;
                            break;
                        } else
                            assert(0);

                    case Certificate.Type.OpenSSL:
                        decrypted = openssl.decrypt(socketState, encrypted, consumed);
                        assert(decrypted.isNull); // never set
                        break;
                    }

                    encryptedLength = encrypted.length;
                    return consumed;
                });

                if (consumed > 0) {
                    logger.debug_("Decrypted data for socket ", socketState.handle, " with ", decrypted.length,
                            " from ", encryptedLength, " and consumed ", consumed, " on ", Thread.self);

                    if (decrypted.length > 0)
                        socketState.reading.push(decrypted);
                    didSomething = true;
                } else if (haveDecrypted && encryptedLength > 0) {
                    logger.debug_("Failed to decrypt data for socket ", socketState.handle, " with ",
                            encryptedLength, " on ", Thread.self);
                }
            }
        }
        while (didSomething);

        return ret;
    }

    void cleanup(scope SocketState* socketState) scope {
        final switch (encryptionEngine) {
        case Certificate.Type.None:
        case Certificate.Type.Default:
            break;

        case Certificate.Type.WinCrypt:
            version (Windows) {
                winCrypt.cleanup(socketState);
            }
            break;

        case Certificate.Type.OpenSSL:
            openssl.cleanup(socketState);
            break;
        }
    }
}
