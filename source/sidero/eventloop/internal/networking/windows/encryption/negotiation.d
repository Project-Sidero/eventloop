module sidero.eventloop.internal.networking.windows.encryption.negotiation;
import sidero.eventloop.internal.networking.windows.encryption.state;
import sidero.eventloop.internal.networking.windows.mechanism : logger;
import sidero.eventloop.internal.networking.state.socket;
import sidero.eventloop.coroutine.future_completion;
import sidero.eventloop.threads;
import sidero.eventloop.certificates;
import sidero.base.synchronization.mutualexclusion;
import sidero.base.containers.list.concurrentlinkedlist;
import sidero.base.containers.readonlyslice;

version (Windows) {
    import sidero.eventloop.internal.windows.bindings;
}

struct NegotationState {
    version (Windows) {
        CtxtHandle contextHandle;
        bool haveContextHandle;
    }

@safe nothrow @nogc:

    void cleanup(scope SocketState* socketState) scope @trusted {
        version (Windows) {
            if (this.haveContextHandle) {
                DeleteSecurityContext(&this.contextHandle);
                this.haveContextHandle = false;
            }
        }
    }

    bool negotiateServer(scope SocketState* socketState) scope @trusted {
        version (Windows) {
            bool didSomething;
            ULONG plAttributes = ASC_REQ_ALLOCATE_MEMORY | ASC_REQ_STREAM;

            logger.debug_("Negotation for server socket ", socketState.handle, " on ", Thread.self);

            socketState.rawReading.readRaw((data) @trusted {
                if (data.length == 0)
                    return 0;

                auto canDo = data.unsafeGetLiteral()[0 .. (data.length >= maxTokenSize) ? maxTokenSize: data.length];
                logger.trace("socket server received data ", socketState.handle, " for ", canDo.length, " on ", Thread.self);

                SecBuffer[2] buffersIn = [
                    SecBuffer(cast(uint)canDo.length, SECBUFFER_TOKEN, canDo.ptr), SecBuffer(0, SECBUFFER_EMPTY, null)
                ];
                SecBuffer[2] buffersOut = [SecBuffer(0, SECBUFFER_TOKEN, null), SecBuffer(0, SECBUFFER_EMPTY, null)];

                SecBufferDesc buffersDescriptionIn, buffersDescriptionOut;

                buffersDescriptionIn.ulVersion = SECBUFFER_VERSION;
                buffersDescriptionIn.cBuffers = 2;
                buffersDescriptionIn.pBuffers = buffersIn.ptr;

                buffersDescriptionOut.ulVersion = SECBUFFER_VERSION;
                buffersDescriptionOut.cBuffers = 1;
                buffersDescriptionOut.pBuffers = buffersOut.ptr;

                SECURITY_STATUS ss;

                if (haveContextHandle) {
                    ss = AcceptSecurityContext(&socketState.encryption.winCrypt.credentialHandle, &contextHandle,
                        &buffersDescriptionIn, plAttributes, 0, &contextHandle, &buffersDescriptionOut, &plAttributes, null);
                } else {
                    ss = AcceptSecurityContext(&socketState.encryption.winCrypt.credentialHandle, null,
                        &buffersDescriptionIn, plAttributes, 0, &contextHandle, &buffersDescriptionOut, &plAttributes, null);
                    haveContextHandle = true;
                }

                logger.trace("Socket server handshake ", socketState.handle, " with ", ss, " on ", Thread.self);

                if (buffersOut[0].cbBuffer > 0) {
                    auto sliced = Slice!ubyte((cast(ubyte*)buffersOut[0].pvBuffer)[0 .. buffersOut[0].cbBuffer]);
                    logger.debug_("Sending data for server socket ", socketState.handle, " for length ", sliced.length,
                        " on ", Thread.self);

                    socketState.rawWriting.push(sliced.dup);
                    FreeContextBuffer(buffersOut[0].pvBuffer);
                }

                assert(ss != SEC_I_COMPLETE_AND_CONTINUE);
                assert(ss != SEC_I_COMPLETE_NEEDED);
                socketState.encryption.negotiating = ss == SEC_I_CONTINUE_NEEDED || ss == SEC_E_INCOMPLETE_MESSAGE;

                if (ss == SEC_E_INCOMPLETE_MESSAGE)
                    return 0;

                if (!socketState.encryption.negotiating) {
                    if (ss != SEC_E_OK) {
                        logger.warning("Unable to negotiate socket encryption ", socketState.handle, " with ", ss, " on ", Thread.self);
                        socketState.close(true);
                    } else {
                        socketState.encryption.encryptionSetupDoneSuccess();
                        logger.debug_("Completed socket server negotation ", socketState.handle, " on ", Thread.self);
                    }
                }

                size_t consumed = canDo.length;
                if (buffersOut[1].BufferType == SECBUFFER_EXTRA) {
                    consumed -= buffersOut[1].cbBuffer;
                }

                didSomething = consumed > 0;
                return consumed;
            });

            if (!socketState.encryption.negotiating) {
                updateStreamSizes(socketState);
            }

            return didSomething;
        } else
            assert(0);
    }

    bool negotiateClient(scope SocketState* socketState) scope @trusted {
        version (Windows) {
            bool didSomething;
            ULONG plAttributes = ISC_REQ_SEQUENCE_DETECT | ISC_REQ_REPLAY_DETECT | ISC_REQ_CONFIDENTIALITY |
                ISC_REQ_EXTENDED_ERROR | ISC_REQ_ALLOCATE_MEMORY | ISC_REQ_MANUAL_CRED_VALIDATION | ISC_REQ_STREAM;

            logger.debug_("Negotation for client socket ", socketState.handle, " on ", Thread.self);

            socketState.rawReading.readRaw((data) @trusted {
                auto canDo = data.unsafeGetLiteral()[0 .. (data.length >= maxTokenSize) ? maxTokenSize: data.length];
                logger.trace("socket client received data ", socketState.handle, " for ", canDo.length, " on ", Thread.self);

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

                SECURITY_STATUS ss;

                if (haveContextHandle) {
                    ss = InitializeSecurityContextW(&socketState.encryption.winCrypt.credentialHandle, &contextHandle, null,
                        plAttributes, 0, SECURITY_NATIVE_DREP, &buffersDescriptionIn, 0, null,
                        &buffersDescriptionOut, &plAttributes, null);
                } else {
                    ss = InitializeSecurityContextW(&socketState.encryption.winCrypt.credentialHandle, null,
                        cast(wchar*)socketState.encryption.winCrypt.currentSniHostname.ptr, plAttributes, 0, SECURITY_NATIVE_DREP,
                        &buffersDescriptionIn, 0, &contextHandle, &buffersDescriptionOut, &plAttributes, null);
                    haveContextHandle = true;
                }

                logger.trace("Socket client handshake ", socketState.handle, " with ", ss, " on ", Thread.self);

                if (buffersOut[0].cbBuffer > 0) {
                    auto sliced = Slice!ubyte((cast(ubyte*)buffersOut[0].pvBuffer)[0 .. buffersOut[0].cbBuffer]);
                    logger.debug_("Sending data for client socket ", socketState.handle, " for length ", sliced.length,
                        " on ", Thread.self);

                    socketState.rawWriting.push(sliced.dup);
                    FreeContextBuffer(buffersOut[0].pvBuffer);
                }

                assert(ss != SEC_I_COMPLETE_AND_CONTINUE);
                assert(ss != SEC_I_COMPLETE_NEEDED);
                socketState.encryption.negotiating = ss == SEC_I_CONTINUE_NEEDED || ss == SEC_E_INCOMPLETE_MESSAGE;

                if (ss == SEC_E_INCOMPLETE_MESSAGE)
                    return 0;

                if (!socketState.encryption.negotiating) {
                    if (ss == SEC_E_WRONG_PRINCIPAL) {
                        logger.warning("Unable to negotiate socket encryption possibly due to invalidate certificate ",
                            socketState.handle, " with ", ss, " on ", Thread.self);
                        socketState.close(true);
                    } else if (ss != SEC_E_OK) {
                        logger.warning("Unable to negotiate socket encryption ", socketState.handle, " with ", ss, " on ", Thread.self);
                        socketState.close(true);
                    } else {
                        socketState.encryption.encryptionSetupDoneSuccess();
                        logger.debug_("Completed socket client negotation ", socketState.handle, " on ", Thread.self);
                    }
                }

                size_t consumed = canDo.length;
                if (buffersIn[1].BufferType == SECBUFFER_EXTRA) {
                    consumed -= buffersIn[1].cbBuffer;
                }

                didSomething = consumed > 0;
                return consumed;
            });

            if (!socketState.encryption.negotiating) {
                updateStreamSizes(socketState);
            }

            return didSomething;
        } else
            assert(0);
    }

    void updateStreamSizes(scope SocketState* socketState) scope @trusted {
        version (Windows) {
            SecPkgContext_StreamSizes sizes;

            // Get stream data properties
            SECURITY_STATUS ss = QueryContextAttributesW(&contextHandle, SECPKG_ATTR_STREAM_SIZES, &sizes);

            if (ss != SEC_E_OK) {
                logger.warning("Could not acquire stream TLS properties for ", socketState.handle, " ", ss);
                return;
            }

            socketState.encryption.winCrypt.encryptedPacketHeaderSize = sizes.cbHeader;
            socketState.encryption.winCrypt.encryptedMessageSize = sizes.cbMaximumMessage;
            socketState.encryption.winCrypt.encryptedPacketTrailerSize = sizes.cbTrailer;
            socketState.encryption.winCrypt.maxEncryptedPacketSize = sizes.cbHeader + sizes.cbMaximumMessage + sizes.cbTrailer;
            logger.debug_("Max WinCrypt encrypted package size for ", SecurityPackageName, ": ",
                    socketState.encryption.winCrypt.maxEncryptedPacketSize);
        } else
            assert(0);
    }
}
