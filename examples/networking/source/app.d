import sidero.base.text;
import sidero.eventloop.networking.sockets;
import sidero.base.console;
import sidero.base.containers.dynamicarray;
import sidero.base.containers.readonlyslice;
import sidero.base.path.hostname;
import sidero.eventloop.certificates;
import sidero.eventloop.coroutine;

//version = UseTLS;
//version = UseRemote;
//version = UseClient;

//version = UseServerTLS;
//version = UseServer;

version(Windows) {
    //version = UseServerOpenSSL;
} else {
    version = UseServerOpenSSL;
}

int main(string[] args) {
    import sidero.base.text.format;
    import sidero.base.path.networking;
    import sidero.eventloop.networking.sockets;
    import sidero.eventloop.tasks.workers;

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

    Certificate certificateToUseForServerTLS;

    version(UseServerOpenSSL) {
        // TODO: use a certificate we commit and load directly
    } else {
        CertificateStore store = CertificateStore.from(CertificateStore.WinCryptStore.Personal);
        assert(!store.isNull);

        // TODO: explain how to create the TestCertificate and load into personal store

        auto certificates = store.byFriendlyName(String_UTF8("TestCertificate"));
        assert(certificates.length == 1);
        certificateToUseForServerTLS = certificates[0].assumeOkay;
    }

    version(UseServer) {
        version(UseServerTLS) {
            auto listenSocket = ListenSocket.from(createServerCo(), NetworkAddress.fromAnyIPv4(portToListenOn),
                    Socket.Protocol.TCP, Socket.EncryptionProtocol.Best_TLS, certificateToUseForServerTLS);
        } else {
            auto listenSocket = ListenSocket.from(createServerCo(), NetworkAddress.fromAnyIPv4(portToListenOn),
                    Socket.Protocol.TCP, Socket.EncryptionProtocol.None);
        }

        if(!listenSocket)
            return 5;
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

        auto socket = Socket.connectTo(createClientCo(), address, Socket.Protocol.TCP);
        assert(socket);
    }

    acceptLoop;

    shutdownWorkers;
    shutdownNetworking;
    return 0;
}

shared(bool) allowedToShutdown;

void acceptLoop() {
    import sidero.base.datetime;
    import sidero.eventloop.threads;
    import sidero.base.internal.atomic : atomicLoad;

    writeln("Hit enter to stop:");

    for(;;) {
        auto got = readLine(10.seconds);
        if(atomicLoad(allowedToShutdown) && got && got.length > 0)
            break;
    }
}

@safe nothrow @nogc:

InstanceableCoroutine!(void, Socket) createServerCo() {
    static struct State {
        Socket socket;
        Future!(Slice!ubyte) nextLine;

    @safe nothrow @nogc:

        this(Socket socket) {
            this.socket = socket;
        }

        ~this() {
            import sidero.base.internal.atomic : atomicStore;

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
            writeln("RECEIVED: ", cast(string)result.unsafeGetLiteral());

            cast(void)state.socket.write(Slice!ubyte(cast(ubyte[])"> "));
            cast(void)state.socket.write(result);

            if(result.get == cast(ubyte[])"DONE\n") {
                state.socket.close;
                return Builder.complete();
            }
        }

        {
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
            import sidero.base.console;

            debugWriteln(socketTLSError);
            assert(socketTLSError);
        }

        cast(void)state.socket.write(Slice!ubyte(cast(ubyte[])"GET / HTTP/1.1\r\n"));

        version(UseRemote) {
            cast(void)state.socket.write(Slice!ubyte(cast(ubyte[])"Host: example.com\r\n"));
        }

        cast(void)state.socket.write(Slice!ubyte(cast(ubyte[])"Accept-Encoding: identity\r\n"));
        cast(void)state.socket.write(Slice!ubyte(cast(ubyte[])"\r\n"));

        state.nextLine = state.socket.readUntil(Slice!ubyte(cast(ubyte[])"\n"));
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
        }

        {
            state.nextLine = state.socket.readUntil(Slice!ubyte(cast(ubyte[])"\n"));
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
