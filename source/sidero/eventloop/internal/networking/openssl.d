module sidero.eventloop.internal.networking.openssl;
import sidero.eventloop.internal.networking.state;
import sidero.eventloop.threads;
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
        scope (exit)
            initMutex.unlock;

        if (!atomicLoad(isOpenSSLSetup)) {
            logger = Logger.forName(String_UTF8(__MODULE__));
            if (!logger)
                return false;

            {
                auto err = loadLibCrypto();
                if (!err) {
                    logger.info("OpenSSL libcrypto could not be loaded, therefore OpenSSL based TLS encryption is disabled");
                    return false;
                }
            }

            {
                auto err = loadLibSSL();
                if (!err) {
                    logger.info("OpenSSL libssl could not be loaded, therefore OpenSSL based TLS encryption is disabled");
                    return false;
                }
            }

            {
                openSSLContext = SSL_CTX_new(TLS_method());
                if (openSSLContext is null) {
                    logger.warning("Could not create a SSL_CTX object, could not initialize OpenSSL based TLS encryption");
                    return false;
                }

                SSL_CTX_set_options(openSSLContext, SSL_OP_ALL | SSL_OP_NO_SSLv3);
            }

            {
                auto err = SSL_CTX_set_default_verify_paths(openSSLContext);

                if (err != 1) {
                    logger.info("OpenSSL loading of default paths failed");
                    return false;
                }
            }

            atomicStore(isOpenSSLSetup, true);
            return true;
        }

        return true;
    }

    pragma(crt_destructor) extern (C) void deinitializeOpenSSLTLSencryption() @trusted nothrow @nogc {
        import sidero.base.internal.atomic;

        if (atomicLoad(isOpenSSLSetup)) {
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

    String_ASCII currentSniHostname;

@safe nothrow @nogc:

    void acquireCredentials(scope SocketState* socketState) scope @trusted {
        const isInitialized = checkInit;
        if (!isInitialized) {
            socketState.close(true);
            return;
        }

        logger.debug_("Starting to acquire credentials for socket ", socketState.handle, " on ", Thread.self);

        socketState.encryption.bufferSize = 16 * 1024;
        openSSL = SSL_new(openSSLContext);

        if (openSSL is null) {
            logger.info("Failed to create new openssl context for socket ", socketState.handle, " on ", Thread.self);
            socketState.close(true);
            return;
        }

        {
            // we won't be writing to this BIO, but just incase lets set the read only flag, so nothing gets decallocated wrongly ext.
            rawReadBIO = BIO_new(BIO_s_mem());

            if (rawReadBIO is null) {
                logger.info("Failed to create new openssl raw read BIO for socket ", socketState.handle, " on ", Thread.self);
                socketState.close(true);
                return;
            }

            BIO_set_flags(rawReadBIO, BIO_FLAGS_MEM_RDONLY);
            BIO_get_mem_ptr(rawReadBIO, bufRawRead);
        }

        {
            // allow the raw write BIO to handle the memory, although we'll read and reset as we raw write
            rawWriteBIO = BIO_new(BIO_s_mem());

            if (rawWriteBIO is null) {
                logger.info("Failed to create new openssl raw write BIO for socket ", socketState.handle, " on ", Thread.self);
                socketState.close(true);
                return;
            }

            BIO_get_mem_ptr(rawWriteBIO, bufRawWrite);
        }

        SSL_set0_rbio(openSSL, rawReadBIO);
        SSL_set0_wbio(openSSL, rawWriteBIO);

        if (socketState.encryption.validateCertificates) {
            SSL_set_verify(openSSL, SSL_VERIFY_PEER, null);
        } else {
            SSL_set_verify(openSSL, SSL_VERIFY_NONE, null);
        }

        if (socketState.cameFromServer) {
            SSL_set_accept_state(openSSL);
        } else {
            SSL_set_connect_state(openSSL);

            this.currentSniHostname = socketState.encryption.sniHostname.get;

            if (this.currentSniHostname.length > 0) {
                if (!currentSniHostname.isPtrNullTerminated)
                    this.currentSniHostname = this.currentSniHostname.dup;

                SSL_set_tlsext_host_name(openSSL, cast(char*)this.currentSniHostname.ptr);
            }
        }

        {
            bool gotCerts;

            socketState.encryption.currentCertificate.unsafeGetOpenSSLHandles((X509* publicKey, EVP_PKEY* privateKey,
                    STACK_OF!X509_INFO* chain) {
                const countChain = sk_X509_INFO_num(chain);
                STACK_OF!X509* chain2 = sk_X509_new_reserve(null, countChain);

                foreach (i; 0 .. countChain) {
                    auto got = sk_X509_INFO_value(chain, i);

                    if (got !is null && got.x509 !is null) {
                        sk_X509_push(chain2, got.x509);
                    }
                }

                if (SSL_use_cert_and_key(openSSL, publicKey, privateKey, chain2, 0) != 1) {
                    logger.notice("OpenSSL TLS connection could not use public/private key with chain, encryption disabled for socket ", socketState.handle, " on ", Thread.self);
                    ERR_print_errors;
                }
                gotCerts = true;
            });

            if (!gotCerts && socketState.cameFromServer) {
                logger.info("Failed to initialize openssl TLS certificates for socket ", socketState.handle, " on ", Thread.self);
                socketState.close(true);
                return;
            }
        }
    }

    Slice!ubyte encrypt(scope SocketState* socketState, return scope Slice!ubyte decrypted, out size_t consumed) scope @trusted {
        if (decrypted.length == 0)
            return typeof(return).init;

        socketState.rawReading.readRaw((rawReadBuffer) @trusted {

        

            {
                updateRawReadBuffer(socketState, rawReadBuffer.unsafeGetLiteral);
                logger.trace("Encrypt raw read buffer ", bufRawRead, rawReadBuffer.toString());

                SSL_do_handshake(openSSL);
                applyRawWriteBuffer(socketState);
            }

            auto toEncrypt = decrypted.unsafeGetLiteral;

            Loop: while (toEncrypt.length > 0) {
                size_t written;
                const err = SSL_write_ex(this.openSSL, toEncrypt.ptr, toEncrypt.length, &written);
                applyRawWriteBuffer(socketState);

                if (err == 1) {
                    toEncrypt = toEncrypt[written .. $];
                    consumed += written;
                    logger.debug_("Socket openssl TLS encrypted ", written, " for ", socketState.handle, " on ", Thread.self);
                } else {
                    const error = SSL_get_error(this.openSSL, err);

                    switch (error) {
                    case SSL_ERROR_WANT_READ:
                    case SSL_ERROR_WANT_WRITE:
                        logger.debug_("Socket openssl TLS encrypt needs read/write for socket ", socketState.handle, " on ", Thread.self);
                        break Loop;

                    default:
                        logger.debug_("Socket openssl TLS encrypt unknown error ", error, " for socket ",
                            socketState.handle, " on ", Thread.self);
                        break Loop;
                    }
                }
            }

            return rawReadBuffer.length - bufRawRead.length;
        });

        // raw writing has already been handled via applyRawWriteBuffer
        return Slice!ubyte.init;
    }

    Slice!ubyte decrypt(scope SocketState* socketState, return scope DynamicArray!ubyte encrypted, out size_t consumed) scope @trusted {
        if (encrypted.length == 0)
            return typeof(return).init;

        ubyte[16 * 1024] buffer = void;

        updateRawReadBuffer(socketState, encrypted.unsafeGetLiteral);
        const startingLength = bufRawRead.length;

        scope (exit) {
            consumed = startingLength - bufRawRead.length;
        }

        {
            logger.trace("Decrypt raw read buffer ", bufRawRead, " ", encrypted.toString());
            const err = SSL_do_handshake(openSSL);
            applyRawWriteBuffer(socketState);

            logger.trace("decrypt handshake has done ", err, " as ", startingLength, " != ", bufRawRead.length);
        }

        Loop: while (bufRawRead.length > 0) {
            size_t readBytes;
            const err = SSL_read_ex(this.openSSL, buffer.ptr, buffer.length, &readBytes);
            applyRawWriteBuffer(socketState);

            if (err == 1) {
                logger.trace("Pushing ", readBytes, " to socket decrypt of ", socketState.handle, " on ", Thread.self);
                socketState.reading.push(Slice!ubyte(buffer[0 .. readBytes]).dup);
            } else {
                const error = SSL_get_error(this.openSSL, err);

                switch (error) {
                case SSL_ERROR_WANT_READ:
                case SSL_ERROR_WANT_WRITE:
                    logger.debug_("Socket openssl TLS decrypt needs read/write for socket ", socketState.handle, " on ", Thread.self);
                    break Loop;

                default:
                    logger.debug_("Socket openssl TLS decrypt unknown error ", error, " for socket ",
                            socketState.handle, " on ", Thread.self);
                    break Loop;
                }
            }
        }

        // we'll push straight to reading
        logger.debug_("OpenSSL TLS decryption has done ", startingLength, " != ", bufRawRead.length, " for socket ",
                socketState.handle, " on ", Thread.self);
        return Slice!ubyte.init;
    }

    bool negotiate(scope SocketState* socketState) scope {
        bool ret;

        socketState.rawReading.readRaw((rawReadBuffer) @trusted {
            updateRawReadBuffer(socketState, rawReadBuffer.unsafeGetLiteral);

            const err = SSL_do_handshake(openSSL);
            if (err == 1) {
                socketState.encryption.negotiating = false;
                ret = true;
                logger.debug_("Socket openssl TLS finished negotiating ", socketState.handle, " on ", Thread.self);
            } else {
                const error = SSL_get_error(openSSL, err);
                ret = false;

                switch (error) {
                case SSL_ERROR_WANT_READ:
                case SSL_ERROR_WANT_WRITE:
                    logger.debug_("Socket openssl TLS negotiate needs read/write for socket ", socketState.handle, " on ", Thread.self);
                    break;

                default:
                    logger.debug_("Socket openssl TLS negotiate unknown error ", error, " for socket ",
                        socketState.handle, " on ", Thread.self);
                    break;
                }
            }

            applyRawWriteBuffer(socketState);
            logger.trace("Post negotiate ", bufRawRead, " ", rawReadBuffer.length);
            return rawReadBuffer.length - bufRawRead.length;
        });

        return ret;
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
    void updateRawReadBuffer(scope SocketState* socketState, const(ubyte)[] toRead) scope @trusted {
        logger.debug_("Applying from read buffer ", toRead.length, " for ", socketState.handle, " on ", Thread.self);

        //bufRawRead = BUF_MEM_new();
        bufRawRead.length = toRead.length;
        bufRawRead.max = toRead.length;
        bufRawRead.data = cast(ubyte*)toRead.ptr;

        // this will update the read pointer so that it matches
        //BIO_set_mem_buf(rawReadBIO, bufRawRead, BIO_NOCLOSE);

        /+rawReadBIO = BIO_new(BIO_s_mem());
        BIO_set_flags(rawReadBIO, BIO_FLAGS_MEM_RDONLY);
        BIO_get_mem_ptr(rawReadBIO, bufRawRead);

        bufRawRead.length = toRead.length;
        bufRawRead.max = toRead.length;
        bufRawRead.data = cast(ubyte*)toRead.ptr;

        SSL_set0_rbio(openSSL, rawReadBIO);+/
    }

    void applyRawWriteBuffer(scope SocketState* socketState) scope @trusted {
        logger.debug_("Applying to write buffer ", bufRawWrite.length, " for ", socketState.handle, " on ", Thread.self);

        ubyte[16 * 1024] rawByteBuffer;
        size_t readBytes;
        BIO_read_ex(rawWriteBIO, rawByteBuffer.ptr, rawByteBuffer.length, &readBytes);

        socketState.rawWriting.push(Slice!ubyte(rawByteBuffer[0 .. readBytes]).dup);
        bufRawWrite.length = 0;
    }
}
