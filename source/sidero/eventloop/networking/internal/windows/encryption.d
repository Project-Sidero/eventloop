module sidero.eventloop.networking.internal.windows.encryption;
import sidero.eventloop.networking.internal.state;
import sidero.eventloop.networking.sockets;
import sidero.eventloop.certificates;
import sidero.base.text;
import sidero.base.logger;
import sidero.base.containers.readonlyslice;
import sidero.base.containers.dynamicarray;
import sidero.base.containers.list.concurrentlinkedlist;
import sidero.base.errors;
import sidero.base.allocators;
import sidero.base.synchronization.mutualexclusion;

version (Windows) {
    import sidero.eventloop.internal.windows.bindings;

    static immutable SecurityPackageName = "Schannel"w;

    private __gshared {
        LoggerReference logger;
        size_t maxTokenSize;
    }

@safe nothrow @nogc:

    bool setupWinCryptEncryption() @trusted {
        logger = Logger.forName(String_UTF8(__MODULE__));
        if (!logger || logger.isNull)
            return false;

        {
            // handle getting of the buffer size needed
            SecPkgInfoW* spi;

            QuerySecurityPackageInfoW(cast(wchar*)SecurityPackageName.ptr, &spi);

            maxTokenSize = spi.cbMaxToken;
            logger.trace("Max WinCrypt token size for ", SecurityPackageName, ": ", maxTokenSize);

            FreeContextBuffer(spi);
        }

        return true;
    }

    struct EncryptionStateWinCrypt {
        private {
            NegotationState negotationState;

            CredHandle credentialHandle;
            bool credentialHandleSet;

            uint encryptedPacketHeaderSize, encryptedMessageSize, encryptedPacketTrailerSize, maxEncryptedPacketSize;
        }

    @safe nothrow @nogc:

        void cleanup() scope @trusted {
            if (credentialHandleSet) {
                FreeCredentialsHandle(&credentialHandle);
                credentialHandleSet = false;
            }
        }

        bool add(scope SocketState* socketState, Certificate certificate, Socket.EncryptionProtocol protocol) scope @trusted {
            socketState.encryptionState.currentCertificate = certificate;
            socketState.encryptionState.currentProtocol = protocol;
            socketState.encryptionState.bufferSize = maxTokenSize;

            {

                PCCERT_CONTEXT certificateContext;
                TLS_PARAMETERS[1] tlsParameters;

                SCH_CREDENTIALS tlsCredentials;
                tlsCredentials.dwVersion = SCH_CREDENTIALS_VERSION;
                tlsCredentials.cCreds = 1;
                tlsCredentials.paCred = &certificateContext;
                tlsCredentials.cTlsParameters = 1;
                tlsCredentials.pTlsParameters = tlsParameters.ptr;

                /+SCHANNEL_CRED tlsCredentials;
                tlsCredentials.dwVersion = SCHANNEL_CRED_VERSION;
                tlsCredentials.cCreds = 1;
                tlsCredentials.paCred = &certificateContext;
                tlsCredentials.grbitEnabledProtocol = SP_PROT_TLS1_2_SERVER;
                tlsCredentials.dwFlags = SCH_USE_STRONG_CRYPTO;+/

                auto certificateHandle = socketState.encryptionState.currentCertificate.unsafeGetHandle;
                if (certificateHandle.type == WinCryptCertificateHandleType) {
                    // ok
                    certificateContext = cast(PCCERT_CONTEXT)certificateHandle.handle;
                } else {
                    // what???
                    // this should be possible
                    logger.fatal("Fatal error: got a certificate that was not from WinCrypt??? ", certificateHandle.type);
                    assert(0);
                }

                auto ss = AcquireCredentialsHandleW(null, cast(wchar*)SecurityPackageName.ptr, SECPKG_CRED_INBOUND,
                        null, &tlsCredentials, null, null, &credentialHandle, null);
                if (ss != SEC_E_OK) {
                    // failed
                    // log it, close socket!

                    logger.warning("Unable to negotate socket encryption using provided certificate ", socketState.handle, " ", ss);
                    socketState.close(true);
                    return false;
                }

                credentialHandleSet = true;
            }

            negotationState.negotiating = true;
            socketState.triggerRead(socketState, false);
            return true;
        }

        void readData(scope SocketState* socketState) scope {
            if (negotationState.ifNegotiatingQueueRead(socketState))
                return;

            bool renegotiate;

            socketState.rawReadingState.protectReadForEncryption((DynamicArray!ubyte data) @trusted {
                SecBuffer[4] buffers = [
                    SecBuffer(cast(uint)data.length, SECBUFFER_DATA, data.ptr), SecBuffer(0, SECBUFFER_EMPTY),
                    SecBuffer(0, SECBUFFER_EMPTY), SecBuffer(0, SECBUFFER_EMPTY),
                ];

                SecBufferDesc buffersDescription;
                buffersDescription.ulVersion = SECBUFFER_VERSION;
                buffersDescription.cBuffers = 4;
                buffersDescription.pBuffers = buffers.ptr;

                auto ss = DecryptMessage(&negotationState.contextHandle, &buffersDescription, 0, null);

                renegotiate = ss == SEC_I_RENEGOTIATE;
                if (ss != SEC_E_OK && !renegotiate) {
                    return 0;
                }

                size_t consumed;

                foreach (ref buffer; buffers) {
                    if (buffer.BufferType == SECBUFFER_DATA) {
                        consumed = data.length;

                        if (buffer.cbBuffer > 0) {
                            DynamicArray!ubyte da;
                            da ~= (cast(ubyte*)buffer.pvBuffer)[0 .. buffer.cbBuffer];
                            socketState.encryptionState.decryptedState.addDecryptedData(da);
                        }
                        break;
                    }
                }

                if (consumed > 0) {
                    foreach_reverse (ref buffer; buffers) {
                        if (buffer.BufferType == SECBUFFER_EXTRA) {
                            consumed -= buffer.cbBuffer;
                            break;
                        }
                    }
                }

                return consumed;
            });

            if (renegotiate) {
                negotationState.triggerNegotiation(socketState);
            }
        }

        Expected writeData(scope SocketState* socketState, return scope Slice!ubyte data) scope @trusted {
            const originalLength = data.length;

            if (negotationState.ifNegotiatingQueue(data)) {
                return Expected(originalLength, originalLength);
            }

            RCAllocator allocator = globalAllocator();

            while (data.length > 0) {
                auto todo = data.unsafeGetLiteral[0 .. data.length >= encryptedMessageSize ? encryptedMessageSize: data.length];

                ubyte[] fullBuffer = allocator.makeArray!ubyte(maxEncryptedPacketSize);
                Slice!ubyte sliceBuffer = Slice!ubyte(fullBuffer, allocator);

                foreach (i, b; todo) {
                    fullBuffer[encryptedPacketHeaderSize + i] = b;
                }

                SecBuffer[3] buffers = [
                    SecBuffer(encryptedPacketHeaderSize, SECBUFFER_STREAM_HEADER, fullBuffer.ptr),
                    SecBuffer(cast(uint)todo.length, SECBUFFER_DATA, &fullBuffer[encryptedPacketHeaderSize]),
                    SecBuffer(encryptedPacketTrailerSize, SECBUFFER_STREAM_TRAILER, &fullBuffer[encryptedPacketHeaderSize + todo.length])
                ];

                SecBufferDesc buffersDescription;
                buffersDescription.ulVersion = SECBUFFER_VERSION;
                buffersDescription.cBuffers = 3;
                buffersDescription.pBuffers = buffers.ptr;

                auto ss = EncryptMessage(&negotationState.contextHandle, 0, &buffersDescription, 0);
                if (ss != SEC_E_OK) {
                    break;
                }

                const usedLength = buffers[0].cbBuffer + buffers[1].cbBuffer + buffers[2].cbBuffer;
                auto sliced = sliceBuffer[0 .. usedLength];
                assert(sliced);

                socketState.rawWritingState.dataToSend(sliced);
                auto sliced2 = data[todo.length .. $];
                assert(sliced2);
                data = sliced2;
            }

            return Expected(originalLength, originalLength - data.length);
        }
    }

    struct NegotationState {
        TestTestSetLockInline mutex;
        ConcurrentLinkedList!(Slice!ubyte) queueToEncrypt;
        bool negotiating, isReadQueued, isWriteQueued;

        CtxtHandle contextHandle;
        bool haveContextHandle;
        size_t tokenLeft;

    @safe nothrow @nogc:

        bool ifNegotiatingQueueRead(scope SocketState* socketState) scope {
            mutex.pureLock;
            scope (exit)
                mutex.unlock;

            if (negotiating) {
                isReadQueued = true;

                negotiateWrapper(socketState);
                return negotiating;
            }

            return false;
        }

        bool ifNegotiatingQueue(return scope Slice!ubyte data) scope @trusted {
            mutex.pureLock;
            scope (exit)
                mutex.unlock;

            if (negotiating) {
                queueToEncrypt ~= data;
                return true;
            } else
                return false;
        }

        void triggerNegotiation(scope SocketState* socketState) scope {
            mutex.pureLock;
            isReadQueued = true;
            negotiating = true;

            negotiateWrapper(socketState);
            mutex.unlock;
        }

        void negotiateWrapper(scope SocketState* socketState) scope @trusted {
            bool didSomeNegotiations;

            if (negotiating) {
                mutex.unlock;

                if (socketState.cameFromServer)
                    didSomeNegotiations = negotiateServer(socketState);
                else
                    didSomeNegotiations = negotiateClient(socketState);

                mutex.pureLock;
            }

            if (didSomeNegotiations) {
                socketState.triggerRead(socketState, false);
            }

            if (!negotiating) {
                if (isReadQueued) {
                    isReadQueued = false;
                    mutex.unlock;

                    socketState.readingState.tryFulfillRequest(socketState);
                    mutex.pureLock;
                }

                if (isWriteQueued) {
                    foreach (toWrite; queueToEncrypt) {
                        mutex.unlock;

                        if (!socketState.encryptionState.winCrypt.writeData(socketState, toWrite)) {
                            mutex.pureLock;
                            break;
                        }

                        mutex.pureLock;
                    }

                    if (queueToEncrypt.length == 0)
                        isWriteQueued = false;
                }
            }
        }

        void updateStreamSizes(scope SocketState* socketState) scope @trusted {
            SecPkgContext_StreamSizes sizes;

            // Get stream data properties
            SECURITY_STATUS ss = QueryContextAttributesW(&contextHandle, SECPKG_ATTR_STREAM_SIZES, &sizes);

            if (ss != SEC_E_OK) {
                logger.warning("Could not acquire stream TLS properties for ", socketState.handle, " ", ss);
                return;
            }

            socketState.encryptionState.winCrypt.encryptedPacketHeaderSize = sizes.cbHeader;
            socketState.encryptionState.winCrypt.encryptedMessageSize = sizes.cbMaximumMessage;
            socketState.encryptionState.winCrypt.encryptedPacketTrailerSize = sizes.cbTrailer;
            socketState.encryptionState.winCrypt.maxEncryptedPacketSize = sizes.cbHeader + sizes.cbMaximumMessage + sizes.cbTrailer;
            logger.trace("Max WinCrypt encrypted package size for ", SecurityPackageName, ": ", socketState.encryptionState.winCrypt.maxEncryptedPacketSize);
        }

        bool negotiateServer(scope SocketState* socketState) scope @trusted {
            bool ret;
            if (tokenLeft == 0) {
                tokenLeft = maxTokenSize;
            }

            ULONG plAttributes = ISC_REQ_ALLOCATE_MEMORY | ISC_REQ_STREAM;

            logger.trace("starting negotation");

            socketState.rawReadingState.protectReadForEncryption((DynamicArray!ubyte data) @trusted {
                auto canDo = data.unsafeGetLiteral()[0 .. (data.length >= tokenLeft) ? tokenLeft: data.length];
                logger.trace(canDo.length);

                SecBuffer[2] buffersIn = [
                    SecBuffer(cast(uint)canDo.length, SECBUFFER_TOKEN, canDo.ptr), SecBuffer(0, SECBUFFER_EMPTY, null)
                ];
                SecBuffer[1] buffersOut = [SecBuffer(0, SECBUFFER_TOKEN, null)];

                SecBufferDesc buffersDescriptionIn, buffersDescriptionOut;

                buffersDescriptionIn.ulVersion = SECBUFFER_VERSION;
                buffersDescriptionIn.cBuffers = 2;
                buffersDescriptionIn.pBuffers = buffersIn.ptr;

                buffersDescriptionOut.ulVersion = SECBUFFER_VERSION;
                buffersDescriptionOut.cBuffers = 1;
                buffersDescriptionOut.pBuffers = buffersOut.ptr;

                auto ss = AcceptSecurityContext(&socketState.encryptionState.winCrypt.credentialHandle, haveContextHandle ? &contextHandle : null,
                    &buffersDescriptionIn, plAttributes, SECURITY_NATIVE_DREP, &contextHandle, &buffersDescriptionOut, &plAttributes, null);
                haveContextHandle = true;
                logger.trace(ss);

                if (buffersOut[0].cbBuffer > 0) {
                    auto sliced = Slice!ubyte((cast(ubyte*)buffersOut[0].pvBuffer)[0 .. buffersOut[0].cbBuffer]);
                    socketState.rawWritingState.dataToSend(sliced.dup);
                    FreeContextBuffer(buffersOut[0].pvBuffer);

                    logger.trace("sending data");
                }

                negotiating = ss == SEC_I_CONTINUE_NEEDED || ss == SEC_E_INCOMPLETE_MESSAGE;
                if (ss == SEC_E_INCOMPLETE_MESSAGE)
                    return 0;

                if (!negotiating) {
                    if (ss != SEC_E_OK) {
                        logger.warning("Unable to negotiate socket encryption ", socketState.handle);
                        socketState.close(true);
                    }
                }

                size_t consumed = canDo.length;
                if (buffersIn[1].BufferType == SECBUFFER_EXTRA)
                    consumed -= buffersIn[1].cbBuffer;

                ret = consumed > 0;
                return consumed;
            });

            if (!negotiating) {
                updateStreamSizes(socketState);
            }

            socketState.triggerWrite(socketState);
            return ret;
        }

        bool negotiateClient(scope SocketState* socketState) scope @trusted {
            assert(0);
        }
    }
}
