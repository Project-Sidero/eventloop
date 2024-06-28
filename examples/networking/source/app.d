import sidero.base.text;
import sidero.eventloop.sockets;
import sidero.eventloop.sockets.control;
import sidero.eventloop.certificates;
import sidero.eventloop.coroutine;
import sidero.base.console;
import sidero.base.containers.dynamicarray;
import sidero.base.containers.readonlyslice;
import sidero.base.path.hostname;

//version = UseTLS;
//version = UseRemote;
//version = UseClientASync;
//version = UseClientSync;

//version = UseServerTLS;
//version = UseServer;

version(Windows) {
    //version = UseServerSelfSign;
} else {
    version = UseServerSelfSign;
}

version(UseClientASync) {
    version = UseClient;
} else version(UseClientSync) {
    version = UseClient;
}

int main(string[] args) {
    import sidero.eventloop.tasks.workers;
    import sidero.base.text.format;
    import sidero.base.path.networking;
    import sidero.base.datetime;
    import sidero.base.internal.atomic: atomicStore;

    /+if(args.length < 2) {
        writeln("Usage: port");
        return 1;
    }+/

    ushort portToListenOn;

    if(args.length > 1) {
        String_UTF8 arg = String_UTF8(args[1]);
        auto got = formattedRead(arg, "{:d}", portToListenOn);
        if(!got) {
            writeln("Could not parse port as a positive integer between 0 and 65535");
            return 2;
        }
    } else
        portToListenOn = 22965;

    version(all) {
        import sidero.base.bindings.openssl.libcrypto;
        import sidero.base.bindings.openssl.libssl;
        import sidero.base.path.file;

        auto lcFP = FilePath.from("C:/Program Files/OpenSSL-Win64/libcrypto-3-x64.dll");
        assert(lcFP);
        auto lsFP = FilePath.from("C:/Program Files/OpenSSL-Win64/libssl-3-x64.dll");
        assert(lsFP);

        loadLibCrypto(lcFP).debugWriteln;
        loadLibSSL(lsFP).debugWriteln;
    }

    version(all) {
        if(!startUpNetworking)
            return 3;
        if(!startWorkers(1))
            return 4;
    }

    {
        auto domainAddress = NetworkAddress.from(Hostname.from("example.com"), 80);
        auto addresses = domainAddress.resolve();
        assert(addresses.length > 0);
    }

    version(UseServer) {
        Certificate certificateToUseForServerTLS;

        version(UseServerSelfSign) {
            auto gotCertificate = createSelfSigned(2048, 1.day, String_UTF8("Self signed localhost certificate"),
                    Hostname.fromEncoded(String_ASCII("localhost")));
            assert(gotCertificate);
            certificateToUseForServerTLS = gotCertificate;
            assert(!certificateToUseForServerTLS.isNull);
        } else {
            CertificateStore store = CertificateStore.from(CertificateStore.WinCryptStore.Personal);
            assert(!store.isNull);

            // Using the Certificate Manager (certmgr), under Personal -> Certificates,
            //  you must have a certificate with the friendly name "TestCertificate".
            // It is not created by default, this is something that was introduced for this program.
            // To create it you can use IIS to create the certificate, export it and then import into the personal store.

            // Don't worry about it getting out of date.
            // Due to it being self signed, the client is going to have to not verify the server certificate.

            // Between the following two tutorials you should be able to figure out how to create it.
            // https://aboutssl.org/how-to-create-a-self-signed-certificate-in-iis/
            // https://techcommunity.microsoft.com/t5/windows-server-essentials-and/installing-a-self-signed-certificate-as-a-trusted-root-ca-in/ba-p/396105

            auto certificates = store.byFriendlyName(String_UTF8("TestCertificate"));
            assert(certificates.length == 1);
            certificateToUseForServerTLS = certificates[0].assumeOkay;
        }

        version(UseServerTLS) {
            auto listenSocket = ListenSocket.from(createServerCo(), NetworkAddress.fromAnyIPv4(portToListenOn),
                    Socket.Protocol.TCP, Socket.EncryptionProtocol.Best_TLS, certificateToUseForServerTLS);
        } else {
            auto listenSocket = ListenSocket.from(createServerCo(), NetworkAddress.fromAnyIPv4(portToListenOn),
                    Socket.Protocol.TCP, Socket.EncryptionProtocol.None);
        }

        if(!listenSocket) {
            debugWriteln(listenSocket);
            return 5;
        }

        atomicStore(haveACo, true);
    }

    version(UseClient) {
        version(UseRemote) {
            version(UseTLS) {
                auto domainAddress = NetworkAddress.from(Hostname.from("example.com"), 443);
            } else {
                auto domainAddress = NetworkAddress.from(Hostname.from("example.com"), 80);
            }
            auto addresses = domainAddress.resolve();
            assert(addresses.length > 0);

            foreach(address; addresses)
                writeln(address);

            auto address = addresses[1];
            assert(address);
        } else {
            version(UseTLS) {
                auto address = NetworkAddress.fromIPv4(443, 127, 0, 0, 1);
            } else {
                auto address = NetworkAddress.fromIPv4(80, 127, 0, 0, 1);
            }
        }

        version(UseClientASync) {
            auto socket = Socket.connectTo(createClientCo(), address, Socket.Protocol.TCP);
            assert(socket);
        } else version(UseClientSync) {
            auto socket = Socket.connectTo(address, Socket.Protocol.TCP);
            assert(socket);

            handleSyncClient(socket);
        }
    }

    acceptLoop;

    shutdownWorkers;
    shutdownNetworking;
    return 0;
}

shared(bool) allowedToShutdown, haveACo;

void acceptLoop() {
    import sidero.base.datetime;
    import sidero.eventloop.threads;
    import sidero.base.internal.atomic : atomicLoad;

    if(!atomicLoad(haveACo))
        return;

    writeln("Hit enter to stop:");
    bool wantClose;

    for(;;) {
        auto got = readLine(2.seconds);
        if(got && got.length > 0)
            wantClose = true;

        if((atomicLoad(allowedToShutdown) || !atomicLoad(haveACo)) && wantClose)
            break;

        //cast(void)Thread.sleep(1.seconds);
    }
}

@safe nothrow @nogc:

InstanceableCoroutine!(void, Socket) createServerCo() {
    import sidero.base.internal.atomic : atomicStore;

    static struct State {
        Socket socket;
        Future!(Slice!ubyte) nextLine;

    @safe nothrow @nogc:

        this(Socket socket) {
            this.socket = socket;
            atomicStore(haveACo, true);
        }

        ~this() {

            if(socket.isNull)
                return;

            if(socket.isAlive)
                writeln("Connection can be shutdown ", socket);
            else {
                writeln("Connection has been shutdown ", socket);
            }

            atomicStore(allowedToShutdown, true);
        }
    }

    enum Stages {
        OnConnect,
        OnLine,
    }

    alias Builder = CoroutineBuilder!(State, Stages, void, Socket);
    Builder builder;

    builder[Stages.OnConnect] = (scope ref state) @trusted {
        writeln("Connection has been made");

        state.nextLine = state.socket.readUntil(Slice!ubyte(cast(ubyte[])"\n"));
        assert(!state.nextLine.isNull);

        // workaround for: https://issues.dlang.org/show_bug.cgi?id=23835
        return Builder.nextStage(Stages.OnLine).after(state.nextLine);
    };

    builder[Stages.OnLine] = (scope ref state) @trusted {
        auto result = state.nextLine.result;

        if(!result) {
            if(state.socket.isAlive()) {
                writeln("Failed to complete read");
                return Builder.complete(result.getError());
            } else {
                writeln("Not alive and did not get a result");
                return Builder.complete();
            }
        }

        {
            String_UTF8 text = String_UTF8(cast(string)result.unsafeGetLiteral());
            if(text.endsWith("\r\n"))
                text = text[0 .. $ - 2];
            else if(text.endsWith("\n"))
                text = text[0 .. $ - 1];

            writeln("RECEIVED: ", text);

            cast(void)state.socket.write(Slice!ubyte(cast(ubyte[])"> "));
            cast(void)state.socket.write(result);

            if(result.get == cast(ubyte[])"DONE\n") {
                state.socket.close;
                return Builder.complete();
            }
        }

        {
            assert(!state.socket.isNull);
            state.nextLine = state.socket.readUntil(Slice!ubyte(cast(ubyte[])"\n"));
            assert(!state.nextLine.isNull);

            // workaround for: https://issues.dlang.org/show_bug.cgi?id=23835
            return Builder.nextStage(Stages.OnLine).after(state.nextLine);
        }
    };

    auto got = builder.build();
    assert(got);
    return got.get;
}

InstanceableCoroutine!(void, Socket) createClientCo() {
    import sidero.base.internal.atomic : atomicStore;

    static struct State {
        Socket socket;
        Future!(Slice!ubyte) nextLine;

    @safe nothrow @nogc:

        this(Socket socket) {
            this.socket = socket;
            atomicStore(haveACo, true);
        }

        ~this() {
            if(socket.isNull)
                return;

            if(socket.isAlive)
                writeln("Connection can be shutdown ", socket);
            else
                writeln("Connection has been shutdown ", socket);

            atomicStore(allowedToShutdown, true);
        }
    }

    enum Stages {
        OnConnect,
        OnLine,
    }

    alias Builder = CoroutineBuilder!(State, Stages, void, Socket);
    Builder builder;

    builder[Stages.OnConnect] = (scope ref state) @trusted {
        writeln("Connection has been made");

        version(UseTLS) {
            version(UseRemote) {
                auto socketTLSError = state.socket.addEncryption(Hostname.from("example.com"),
                        Socket.EncryptionProtocol.Best_TLS, Certificate.init, true);
            } else {
                auto socketTLSError = state.socket.addEncryption(Hostname.init, Socket.EncryptionProtocol.Best_TLS,
                        Certificate.init, false);
            }

            assert(socketTLSError);
        }

        auto tempSlice = Slice!ubyte(cast(ubyte[])"GET / HTTP/1.1\r\n");
        cast(void)state.socket.write(tempSlice);

        version(UseRemote) {
            tempSlice = Slice!ubyte(cast(ubyte[])"Host: example.com\r\n");
            cast(void)state.socket.write(tempSlice);
        }

        tempSlice = Slice!ubyte(cast(ubyte[])"Accept-Encoding: identity\r\n");
        cast(void)state.socket.write(tempSlice);
        tempSlice = Slice!ubyte(cast(ubyte[])"\r\n");
        cast(void)state.socket.write(tempSlice);

        tempSlice = Slice!ubyte(cast(ubyte[])"\n");
        state.nextLine = state.socket.readUntil(tempSlice);
        assert(!state.nextLine.isNull);

        // workaround for: https://issues.dlang.org/show_bug.cgi?id=23835
        auto ret = Builder.nextStage(Stages.OnLine).after(state.nextLine);
        return ret;
    };

    builder[Stages.OnLine] = (scope ref state) @trusted {
        auto result = state.nextLine.result;

        if(!result) {
            if(state.socket.isAlive()) {
                writeln("Failed to complete read");
                return Builder.complete(result.getError());
            } else {
                writeln("Not alive and did not get a result");
                return Builder.complete();
            }
        }

        {
            String_UTF8 text = String_UTF8(cast(string)result.unsafeGetLiteral());
            if(text.endsWith("\r\n"))
                text = text[0 .. $ - 2];
            else if(text.endsWith("\n"))
                text = text[0 .. $ - 1];

            writeln("RECEIVED: ", text);

            if(text == "</html>") {
                writeln("Saw end of expected input");
                return Builder.complete();
            }
        }

        {
            auto tempSlice = Slice!ubyte(cast(ubyte[])"\n");
            state.nextLine = state.socket.readUntil(tempSlice);
            assert(!state.nextLine.isNull);

            // workaround for: https://issues.dlang.org/show_bug.cgi?id=23835
            auto ret = Builder.nextStage(Stages.OnLine).after(state.nextLine);
            return ret;
        }
    };

    auto got = builder.build();
    assert(got);
    return got.get;
}

void handleSyncClient(Socket socket) @trusted {
    import sidero.base.internal.atomic : atomicStore;

    writeln("Connection has been made");

    scope(exit) {
        atomicStore(allowedToShutdown, true);
    }

    {
        version(UseTLS) {
            version(UseRemote) {
                auto socketTLSError = state.socket.addEncryption(Hostname.from("example.com"),
                        Socket.EncryptionProtocol.Best_TLS, Certificate.init, true);
            } else {
                auto socketTLSError = state.socket.addEncryption(Hostname.init, Socket.EncryptionProtocol.Best_TLS,
                        Certificate.init, false);
            }

            assert(socketTLSError);
        }
    }

    Future!(Slice!ubyte) nextLine;

    {
        auto tempSlice = Slice!ubyte(cast(ubyte[])"GET / HTTP/1.1\r\n");
        cast(void)socket.write(tempSlice);

        version(UseRemote) {
            tempSlice = Slice!ubyte(cast(ubyte[])"Host: example.com\r\n");
            cast(void)socket.write(tempSlice);
        }

        tempSlice = Slice!ubyte(cast(ubyte[])"Accept-Encoding: identity\r\n");
        cast(void)socket.write(tempSlice);
        tempSlice = Slice!ubyte(cast(ubyte[])"\r\n");
        cast(void)socket.write(tempSlice);

        tempSlice = Slice!ubyte(cast(ubyte[])"\n");
        nextLine = socket.readUntil(tempSlice);
        assert(!nextLine.isNull);
    }

    for(;;) {
        nextLine.blockUntilCompleteOrHaveValue;
        auto result = nextLine.result;

        if(!result) {
            if(socket.isAlive()) {
                writeln("Failed to complete read ", result);
            } else {
                writeln("Not alive and did not get a result");
            }

            return;
        }

        {
            String_UTF8 text = String_UTF8(cast(string)result.unsafeGetLiteral());
            if(text.endsWith("\r\n"))
                text = text[0 .. $ - 2];
            else if(text.endsWith("\n"))
                text = text[0 .. $ - 1];

            writeln("RECEIVED: ", text);

            if(text == "</html>") {
                writeln("Saw end of expected input");
                return;
            }
        }

        {
            auto tempSlice = Slice!ubyte(cast(ubyte[])"\n");
            nextLine = socket.readUntil(tempSlice);
            assert(!nextLine.isNull);
        }
    }
}
