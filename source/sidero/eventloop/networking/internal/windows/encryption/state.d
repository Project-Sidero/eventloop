module sidero.eventloop.networking.internal.windows.encryption.state;
import sidero.eventloop.networking.internal.windows.encryption.negotiation;
import sidero.eventloop.networking.internal.windows.mechanism : logger;
import sidero.eventloop.networking.internal.state.socket;
import sidero.eventloop.certificates;
import sidero.eventloop.sockets;
import sidero.eventloop.threads;
import sidero.base.path.hostname;
import sidero.base.containers.readonlyslice;
import sidero.base.containers.dynamicarray;
import sidero.base.text;

version(Windows) {
    import sidero.eventloop.internal.windows.bindings;
}

private {
    shared bool isWinCryptSetup;

    void checkInit() @trusted nothrow @nogc {
        import sidero.base.internal.atomic;

        version(Windows) {
            if(!atomicLoad(isWinCryptSetup)) {
                {
                    // handle getting of the buffer size needed
                    SecPkgInfoW* spi;

                    QuerySecurityPackageInfoW(cast(wchar*)SecurityPackageName.ptr, &spi);

                    maxTokenSize = spi.cbMaxToken;
                    logger.debug_("Max WinCrypt token size for ", SecurityPackageName, ": ", maxTokenSize);

                    FreeContextBuffer(spi);
                }

                atomicStore(isWinCryptSetup, true);
            }
        }
    }
}

package(sidero.eventloop.networking.internal.windows.encryption) {
    static immutable SecurityPackageName = "Schannel"w;

    __gshared {
        size_t maxTokenSize;
    }
}

struct EncryptionStateWinCrypt {
    version(Windows) {
        NegotationState negotationState;

        CredHandle credentialHandle;
        bool credentialHandleSet;

        uint encryptedPacketHeaderSize, encryptedMessageSize, encryptedPacketTrailerSize, maxEncryptedPacketSize;

        String_UTF16 currentSniHostname;
    }

@safe nothrow @nogc:

    void acquireCredentials(scope SocketState* socketState) scope @trusted {
        version(Windows) {
            if (credentialHandleSet) {
                // cleanup the credential handle

                FreeCredentialsHandle(&credentialHandle);
                credentialHandleSet = false;
            }

            assert(!credentialHandleSet);

            {
                logger.debug_("Acquiring credentials for encrypting socket ", socketState.handle, " on ", Thread.self);

                checkInit;
                socketState.encryption.bufferSize = maxTokenSize;
                currentSniHostname = socketState.encryption.sniHostname.decoded.byUTF16.asReadOnly;
            }

            auto credDirection = socketState.cameFromServer ? SECPKG_CRED_INBOUND : SECPKG_CRED_OUTBOUND;

            PCCERT_CONTEXT certificateContext;
            TLS_PARAMETERS[1] tlsParameters;

            if(socketState.cameFromServer) {
                enum All = SP_PROT_SSL2_SERVER | SP_PROT_SSL3_SERVER | SP_PROT_TLS1_SERVER | SP_PROT_TLS1_1_SERVER |
                    SP_PROT_TLS1_2_SERVER | SP_PROT_TLS1_3_SERVER | SP_PROT_DTLS1_SERVER | SP_PROT_DTLS1_2_SERVER;

                static immutable Flags = [
                    All, All & (~(SP_PROT_TLS1_SERVER | SP_PROT_DTLS1_SERVER)),
                    All & (~(SP_PROT_TLS1_1_SERVER | SP_PROT_DTLS1_SERVER)),
                    All & (~(SP_PROT_TLS1_2_SERVER | SP_PROT_DTLS1_2_SERVER)),
                    All & (~(SP_PROT_TLS1_3_SERVER | SP_PROT_DTLS1_2_SERVER)),
                    All & (~(SP_PROT_TLS1_SERVER | SP_PROT_TLS1_1_SERVER | SP_PROT_TLS1_2_SERVER |
                            SP_PROT_TLS1_3_SERVER | SP_PROT_DTLS1_SERVER | SP_PROT_DTLS1_2_SERVER))
                ];
                static assert(Flags.length == __traits(allMembers, Socket.EncryptionProtocol).length);
                tlsParameters[0].grbitDisabledProtocols = Flags[socketState.encryption.currentProtocol];
            } else {
                enum All = SP_PROT_SSL2_CLIENT | SP_PROT_SSL3_CLIENT | SP_PROT_TLS1_CLIENT | SP_PROT_TLS1_1_CLIENT |
                    SP_PROT_TLS1_2_CLIENT | SP_PROT_TLS1_3_CLIENT | SP_PROT_DTLS1_CLIENT | SP_PROT_DTLS1_2_CLIENT;

                static immutable Flags = [
                    All, All & (~(SP_PROT_TLS1_CLIENT | SP_PROT_DTLS1_CLIENT)),
                    All & (~(SP_PROT_TLS1_1_CLIENT | SP_PROT_DTLS1_CLIENT)),
                    All & (~(SP_PROT_TLS1_2_CLIENT | SP_PROT_DTLS1_2_CLIENT)),
                    All & (~(SP_PROT_TLS1_3_CLIENT | SP_PROT_DTLS1_2_CLIENT)),
                    All & (~(SP_PROT_TLS1_CLIENT | SP_PROT_TLS1_1_CLIENT | SP_PROT_TLS1_2_CLIENT |
                            SP_PROT_TLS1_3_CLIENT | SP_PROT_DTLS1_CLIENT | SP_PROT_DTLS1_2_CLIENT))
                ];
                static assert(Flags.length == __traits(allMembers, Socket.EncryptionProtocol).length);
                tlsParameters[0].grbitDisabledProtocols = Flags[socketState.encryption.currentProtocol];
            }

            SCH_CREDENTIALS tlsCredentials;
            tlsCredentials.dwVersion = SCH_CREDENTIALS_VERSION;
            tlsCredentials.cCreds = (socketState.cameFromServer || !socketState.encryption.currentCertificate.isNull) ? 1 : 0;
            tlsCredentials.paCred = &certificateContext;
            tlsCredentials.cTlsParameters = 1;
            tlsCredentials.pTlsParameters = tlsParameters.ptr;

            if(socketState.encryption.validateCertificates) {
                tlsCredentials.dwFlags = SCH_CRED_AUTO_CRED_VALIDATION;
            } else {
                if(socketState.cameFromServer)
                    tlsCredentials.dwFlags = 0;
                else
                    tlsCredentials.dwFlags = SCH_CRED_MANUAL_CRED_VALIDATION | SCH_CRED_NO_SERVERNAME_CHECK;
            }

            auto certificateHandle = socketState.encryption.currentCertificate.unsafeGetHandle;
            if(certificateHandle.type == WinCryptCertificateHandleType) {
                // ok
                certificateContext = cast(PCCERT_CONTEXT)certificateHandle.handle;
            } else if(tlsCredentials.cCreds == 1) {
                // what???
                // this should be possible
                logger.fatal("Fatal error: got a certificate that was not from WinCrypt??? ", certificateHandle.type);
                assert(0);
            }

            auto ss = AcquireCredentialsHandleW(null, cast(wchar*)SecurityPackageName.ptr, credDirection, null,
                    &tlsCredentials, null, null, &credentialHandle, null);
            if(ss != SEC_E_OK) {
                // failed
                // log it, close socket!

                logger.warning("Unable to negotate socket encryption using provided certificate ", socketState.handle, " ", ss);
                socketState.close(true);
                return;
            }

            credentialHandleSet = true;
        } else
            assert(0);
    }

    Slice!ubyte encrypt(scope SocketState* socketState, return scope Slice!ubyte decrypted, ref size_t consumed) scope @trusted {
        version(Windows) {
            DynamicArray!ubyte tempRet;

            DynamicArray!ubyte fullBufferDA;
            fullBufferDA.length = maxEncryptedPacketSize;
            auto fullBuffer = fullBufferDA.unsafeGetLiteral;

            bool firstTime = true;

            if(decrypted.length > 0) {
                auto leftToDo = decrypted.unsafeGetLiteral;

                if(leftToDo.length > encryptedMessageSize)
                    leftToDo = leftToDo[0 .. encryptedMessageSize];

                foreach(i, b; leftToDo) {
                    fullBuffer[encryptedPacketHeaderSize + i] = b;
                }

                SecBuffer[3] buffers = [
                    SecBuffer(encryptedPacketHeaderSize, SECBUFFER_STREAM_HEADER, fullBuffer.ptr),
                    SecBuffer(cast(uint)leftToDo.length, SECBUFFER_DATA, &fullBuffer[encryptedPacketHeaderSize]),
                    SecBuffer(encryptedPacketTrailerSize, SECBUFFER_STREAM_TRAILER,
                            &fullBuffer[encryptedPacketHeaderSize + leftToDo.length])
                ];

                SecBufferDesc buffersDescription;
                buffersDescription.ulVersion = SECBUFFER_VERSION;
                buffersDescription.cBuffers = 3;
                buffersDescription.pBuffers = buffers.ptr;

                auto ss = EncryptMessage(&negotationState.contextHandle, 0, &buffersDescription, 0);
                if(ss != SEC_E_OK) {
                    return Slice!ubyte.init;
                }

                consumed = leftToDo.length;
                const usedLength = buffers[0].cbBuffer + buffers[1].cbBuffer + buffers[2].cbBuffer;

                if(firstTime && consumed < leftToDo.length) {
                    tempRet = fullBufferDA[0 .. usedLength].dup;
                    tempRet.reserve(leftToDo.length - consumed);
                } else if(!firstTime) {
                    tempRet ~= fullBuffer[0 .. usedLength];
                } else {
                    auto sliced = fullBufferDA[0 .. usedLength];
                    assert(sliced);
                    return sliced.asReadOnly;
                }

                firstTime = false;
            }

            return tempRet.asReadOnly;
        } else
            assert(0);
    }

    Slice!ubyte decrypt(scope SocketState* socketState, return scope DynamicArray!ubyte encrypted, ref size_t consumed) scope @trusted {
        version(Windows) {
            auto encryptedSlice = encrypted.unsafeGetLiteral;

            if(encryptedSlice.length > maxEncryptedPacketSize)
                encryptedSlice = encryptedSlice[0 .. maxEncryptedPacketSize];

            SecBuffer[4] buffers = [
                SecBuffer(cast(uint)encryptedSlice.length, SECBUFFER_DATA, encryptedSlice.ptr),
                SecBuffer(0, SECBUFFER_EMPTY), SecBuffer(0, SECBUFFER_EMPTY), SecBuffer(0, SECBUFFER_EMPTY),
            ];

            SecBufferDesc buffersDescription;
            buffersDescription.ulVersion = SECBUFFER_VERSION;
            buffersDescription.cBuffers = 4;
            buffersDescription.pBuffers = buffers.ptr;

            const ss = DecryptMessage(&negotationState.contextHandle, &buffersDescription, 0, null);

            if(ss == SEC_I_RENEGOTIATE)
                socketState.encryption.negotiating = true;
            if(ss != SEC_E_OK)
                return Slice!ubyte.init;

            {
                consumed = encrypted.length;

                foreach_reverse(ref buffer; buffers) {
                    if (buffer.BufferType == SECBUFFER_EXTRA) {
                        consumed -= buffer.cbBuffer;
                        break;
                    }
                }
            }

            foreach(ref buffer; buffers) {
                if(buffer.BufferType == SECBUFFER_DATA) {
                    return Slice!ubyte((cast(ubyte*)buffer.pvBuffer)[0 .. buffer.cbBuffer]).dup;
                }
            }

            return Slice!ubyte.init;
        } else
            assert(0);
    }

    bool negotiate(scope SocketState* socketState) scope {
        // returns if it did any work (consumed or written something)
        version(Windows) {
            if(socketState.cameFromServer)
                return negotationState.negotiateServer(socketState);
            else
                return negotationState.negotiateClient(socketState);
        } else
            assert(0);
    }

    void cleanup(scope SocketState* socketState) scope @trusted {
        version(Windows) {
            negotationState.cleanup(socketState);

            if(credentialHandleSet) {
                FreeCredentialsHandle(&credentialHandle);
                credentialHandleSet = false;
            }

            socketState.encryption.negotiating = false;
            socketState.encryption.enabled = false;
        } else
            assert(0);
    }
}
