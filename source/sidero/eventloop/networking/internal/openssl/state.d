module sidero.eventloop.networking.internal.openssl.state;
import sidero.eventloop.networking.internal.state;
import sidero.base.bindings.openssl.libcrypto;
import sidero.base.bindings.openssl.libssl;
import sidero.base.containers.readonlyslice;
import sidero.base.containers.dynamicarray;
import sidero.base.logger;
import sidero.base.text;
import sidero.base.synchronization.mutualexclusion;

// https://github.com/darrenjs/openssl_examples/blob/master/common.h

private {
    shared bool isOpenSSLSetup;

    __gshared {
        TestTestSetLockInline initMutex;
        SSL_CTX* openSSLContext;
        LoggerReference logger;
    }

    bool checkInit() @trusted nothrow @nogc {
        import sidero.base.internal.atomic;

        initMutex.pureLock;
        scope(exit)
            initMutex.unlock;

        if(!atomicLoad(isOpenSSLSetup)) {
            logger = Logger.forName(String_UTF8(__MODULE__));
            if(!logger)
                return false;

            {
                auto err = loadLibCrypto();
                if(!err) {
                    logger.info("OpenSSL libcrypto could not be loaded, therefore OpenSSL based TLS encryption is disabled");
                    return false;
                }
            }

            {
                auto err = loadLibSSL();
                if(!err) {
                    logger.info("OpenSSL libssl could not be loaded, therefore OpenSSL based TLS encryption is disabled");
                    return false;
                }
            }

            {
                openSSLContext = SSL_CTX_new(TLS_method());
                if(openSSLContext is null) {
                    logger.warning("Could not create a SSL_CTX object, could not initialize OpenSSL based TLS encryption");
                    return false;
                }

                SSL_CTX_set_options(openSSLContext, SSL_OP_ALL | SSL_OP_NO_SSLv3);
            }

            atomicStore(isOpenSSLSetup, true);
            return true;
        }

        return true;
    }

    pragma(crt_destructor) extern (C) void deinitializeOpenSSLTLSencryption() @trusted nothrow @nogc {
        import sidero.base.internal.atomic;

        if(atomicLoad(isOpenSSLSetup)) {
            SSL_CTX_free(openSSLContext);
            atomicStore(isOpenSSLSetup, false);
        }
    }
}

struct OpenSSLEncryptionStateImpl {
    SSL* openSSL;
    BIO* rawReadBIO;
    BIO* rawWriteBIO;
    BUF_MEM* bufRawRead;
    BUF_MEM* bufRawWrite;

@safe nothrow @nogc:

    void acquireCredentials(scope SocketState* socketState) scope @trusted {
        const isInitialized = checkInit;
        if (!isInitialized) {
            socketState.encryption.enabled = false;
            return;
        }

        openSSL = SSL_new(openSSLContext);

        // we won't be writing to this BIO, but just incase lets set the read only flag, so nothing gets decallocated wrongly ext.
        rawReadBIO = BIO_new(BIO_s_mem());
        BIO_get_mem_ptr(rawReadBIO, bufRawRead);
        bufRawRead.flags |= BIO_FLAGS_MEM_RDONLY;

        // allow the raw write BIO to handle the memory, although we'll read and reset as we raw write
        rawWriteBIO = BIO_new(BIO_s_mem());
        BIO_get_mem_ptr(rawWriteBIO, bufRawWrite);

        if(socketState.cameFromServer) {
            SSL_set_accept_state(openSSL);
        } else {
            SSL_set_connect_state(openSSL);
        }

        socketState.encryption.currentCertificate.unsafeGetOpenSSLHandles((X509_INFO* publicKey, X509_PKEY* privateKey, STACK_OF!X509_INFO* chain) {
            const countChain = sk_X509_INFO_num(chain);
            STACK_OF!X509* chain2 = sk_X509_new(null, countChain);

            foreach(i; 0 .. countChain) {
                auto got = sk_X509_INFO_value(chain, i);

                if (got !is null && got.x509 !is null) {
                    sk_X509_push(chain2, got.x509);
                }
            }

            SSL_use_cert_and_key(openSSL, publicKey is null ? null : publicKey.x509, privateKey is null ?
                null : privateKey.dec_pkey, chain2, 0);
        });

        SSL_set_bio(openSSL, rawReadBIO, rawWriteBIO);

        socketState.encryption.negotiating = false;
    }

    Slice!ubyte encrypt(scope SocketState* socketState, return scope Slice!ubyte decrypted, out size_t consumed) scope @trusted {
        socketState.rawReading.readRaw((rawReadBuffer) @trusted {
            updateRawReadBuffer(rawReadBuffer.unsafeGetLiteral);

            auto toEncrypt = decrypted.unsafeGetLiteral;

            Loop: while(toEncrypt.length > 0) {
                size_t written;
                const err = SSL_write_ex(this.openSSL, toEncrypt.ptr, toEncrypt.length, &written);

                if(err == 1) {
                    toEncrypt = toEncrypt[written .. $];
                    consumed += written;
                } else {
                    const error = SSL_get_error(this.openSSL, err);

                    switch(error) {
                    case SSL_ERROR_WANT_READ:
                    case SSL_ERROR_WANT_WRITE:
                        break Loop;

                    default:
                        break;
                    }
                }

                applyRawWriteBuffer(socketState);
            }

            return bufRawRead.max - bufRawRead.length;
        });

        // raw writing has already been handled via applyRawWriteBuffer
        return Slice!ubyte.init;
    }

    Slice!ubyte decrypt(scope SocketState* socketState, return scope DynamicArray!ubyte encrypted, out size_t consumed) scope @trusted {
        ubyte[16 * 1024] buffer = void;

        updateRawReadBuffer(encrypted.unsafeGetLiteral);

        Loop: while(encrypted.length > 0) {
            size_t readBytes;
            const err = SSL_read_ex(this.openSSL, buffer.ptr, buffer.length, &readBytes);

            if(err == 1) {
                socketState.reading.queue.push(Slice!ubyte(buffer[0 .. readBytes]).dup);
                encrypted = encrypted[readBytes .. $];
            } else {
                const error = SSL_get_error(this.openSSL, err);

                switch(error) {
                case SSL_ERROR_WANT_READ:
                case SSL_ERROR_WANT_WRITE:
                    break Loop;

                default:
                    break;
                }
            }

            applyRawWriteBuffer(socketState);
        }

        consumed = bufRawRead.max - bufRawRead.length;

        // we'll push straight to reading
        return Slice!ubyte.init;
    }

    bool negotiate(scope SocketState* socketState) scope {
        // handled through other steps
        assert(0);
    }

    void cleanup(scope SocketState* socketState) scope @trusted {
        SSL_free(openSSL);

        openSSL = null;
        rawReadBIO = null;
        rawWriteBIO = null;
        bufRawRead = null;
        bufRawWrite = null;
    }

private:
    void updateRawReadBuffer(const(ubyte)[] toRead) scope @trusted {
        bufRawRead.length = toRead.length;
        bufRawRead.max = toRead.length;
        bufRawRead.data = cast(ubyte*)toRead.ptr;
    }

    void applyRawWriteBuffer(scope SocketState* socketState) scope @trusted {
        if(bufRawWrite.length < 1)
            return;

        socketState.rawWriting.queue.push(Slice!ubyte(bufRawWrite.data[0 .. bufRawWrite.length]).dup);
        bufRawWrite.length = 0;
    }
}
