module sidero.eventloop.networking.sockets;
import sidero.eventloop.networking.internal.state;
import sidero.eventloop.networking.internal.platform;
import sidero.eventloop.certificates;
import sidero.eventloop.coroutine.instanceable;
import sidero.eventloop.coroutine.future;
import sidero.base.containers.dynamicarray;
import sidero.base.path.networking;
import sidero.base.path.hostname;
import sidero.base.allocators;
import sidero.base.attributes;
import sidero.base.containers.readonlyslice;
import sidero.base.containers.dynamicarray;
import sidero.base.errors;
import sidero.base.internal.atomic;

export @safe nothrow @nogc:

///
struct ListenSocket {
    package(sidero.eventloop) @PrintIgnore @PrettyPrintIgnore {
        ListenSocketState* state;
    }

export @safe nothrow @nogc:

    ///
    this(return scope ref ListenSocket other) scope {
        this.state = other.state;

        if(state !is null)
            state.rc(true);
    }

    ///
    ~this() scope {
        if(state !is null)
            state.rc(false);
    }

    ///
    bool isNull() scope {
        return state is null;
    }

    ///
    NetworkAddress address() scope {
        if(isNull)
            return NetworkAddress.init;
        return state.address;
    }

    ///
    bool isAlive() scope {
        return !isNull && atomicLoad(state.isAlive) > 0;
    }

    /// Listen on port
    static Result!ListenSocket from(InstanceableCoroutine!(void, Socket) onAccept, NetworkAddress address, Socket.Protocol protocol,
            Socket.EncryptionProtocol encryption = Socket.EncryptionProtocol.None, Certificate fallbackCertificate = Certificate.init,
            bool reuseAddr = true, bool keepAlive = true, bool validateCertificates = true,
            scope return RCAllocator allocator = RCAllocator.init) {

        if(!onAccept.canInstance)
            return typeof(return)(MalformedInputException("On accept coroutine cannot be null"));

        if(allocator.isNull)
            allocator = globalAllocator();

        if(!ensureItIsSetup)
            return typeof(return)(UnknownPlatformBehaviorException("Could not setup networking handling"));

        ListenSocket ret;
        ret.state = allocator.make!ListenSocketState(allocator, onAccept, address, protocol, encryption,
                fallbackCertificate, validateCertificates);

        if(!ret.state.startUp(reuseAddr, keepAlive))
            return typeof(return)(UnknownPlatformBehaviorException("Could not initialize socket"));

        return typeof(return)(ret);
    }
}

///
struct Socket {
    package(sidero.eventloop) @PrintIgnore @PrettyPrintIgnore {
        SocketState* state;
    }

export @safe nothrow @nogc:

    ///
    this(return scope ref Socket other) scope nothrow {
        this.state = other.state;

        if(state !is null)
            state.rc(true);
    }

    ///
    ~this() scope nothrow @nogc {
        if(state !is null)
            state.rc(false);
    }

    ///
    bool isNull() scope {
        return state is null;
    }

    ///
    bool isAlive() scope {
        return !isNull && atomicLoad(state.isAlive);
    }

    ///
    bool isReadInProgress() scope {
        if (!isAlive)
            return false;

        bool ret;

        state.guard(() {
            ret = state.reading.inProgress;
        });

        return ret;
    }

    /// Stop sending & receiving of data
    void close(bool graceFully = true) scope {
        if(isNull)
            return;
        state.close(graceFully);
    }

    ///
    Future!(Slice!ubyte) read(size_t amount) scope @trusted {
        Future!(Slice!ubyte) ret;

        state.guard(() {
            if(state.reading.requestFromUser(amount, ret))
                state.performReadWrite;
        });

        return ret;
    }

    ///
    Future!(Slice!ubyte) readUntil(scope return DynamicArray!ubyte endCondition) scope {
        return this.readUntil(endCondition.asReadOnly());
    }

    ///
    Future!(Slice!ubyte) readUntil(scope return Slice!ubyte endCondition) scope @trusted {
        Future!(Slice!ubyte) ret;

        state.guard(() @safe {
            if(state.reading.requestFromUser(endCondition, ret))
                state.performReadWrite;
        });

        return ret;
    }

    ///
    void write(scope return DynamicArray!ubyte data) scope {
        this.write(data.asReadOnly());
    }

    ///
    void write(scope return Slice!ubyte data) scope {
        if(isAlive()) {
            state.guard(() @trusted {
                state.writing.appendToQueue(state, data);
                state.performReadWrite;
            });
        }
    }

    /// Add encryption to socket, uses client API by default
    alias addEncryption = addEncryptionClient;

    /**
        Adds encryption to socket, supply a certificate to represent this request and if you want to validate the servers' certificate.

        See_Also: addEncryption, addEncryptionServer
    */
    ErrorResult addEncryptionClient(Hostname sniHostname = Hostname.init, EncryptionProtocol encryption = EncryptionProtocol.Best_TLS,
            Certificate certificate = Certificate.init, bool validateCertificates = true) scope {
        if(!isAlive())
            return ErrorResult(NullPointerException("Socket is not currently alive, so cannot be configured to have encryption"));

        if(!state.encryption.addEncryption(this.state, sniHostname, certificate, encryption, validateCertificates))
            return ErrorResult(UnknownPlatformBehaviorException("Could not reinitialize encryption"));
        return ErrorResult.init;
    }

    /**
        Adds encryption to listening socket, supply a certificate to represent this host for fallback purposes and a list of all SNI certificates.

        See_Also: addEncryption, addEncryptionClient
    */
    ErrorResult addEncryptionServer(EncryptionProtocol encryption = EncryptionProtocol.Best_TLS,
            Certificate fallbackCertificate = Certificate.init, Slice!Certificate sniCertificates = Slice!Certificate.init) scope {
        if(!isAlive())
            return ErrorResult(NullPointerException("Socket is not currently alive, so cannot be configured to have encryption"));

        if(!state.encryption.addEncryption(this.state, Hostname.init, fallbackCertificate, encryption, true, sniCertificates))
            return ErrorResult(UnknownPlatformBehaviorException("Could not reinitialize encryption"));
        return ErrorResult.init;
    }

    ///
    enum Protocol {
        ///
        TCP,
        ///
        UDP,
    }

    ///
    enum EncryptionProtocol {
        ///
        None,
        ///
        TLS_1_0,
        ///
        TLS_1_1,
        ///
        TLS_1_2,
        ///
        TLS_1_3,
        ///
        Best_TLS,
    }

    ///
    static Result!Socket connectTo(InstanceableCoroutine!(void, Socket) onConnect, NetworkAddress address,
            Socket.Protocol protocol, bool keepAlive = true, scope return RCAllocator allocator = RCAllocator.init) {
        import sidero.eventloop.tasks.workers : registerAsTask;

        if(!onConnect.canInstance)
            return typeof(return)(MalformedInputException("On connect coroutine cannot be null"));

        if(allocator.isNull)
            allocator = globalAllocator();

        if(!ensureItIsSetup)
            return typeof(return)(UnknownPlatformBehaviorException("Could not setup networking handling"));

        Socket ret;
        ret.state = allocator.make!SocketState(allocator, protocol, false);

        auto errorResult = ret.state.startUp(address, keepAlive);
        if(!errorResult)
            return typeof(return)(errorResult.getError());

        auto connectSocketCO = onConnect.makeInstance(RCAllocator.init, ret);
        registerAsTask(connectSocketCO);

        return typeof(return)(ret);
    }

    package(sidero.eventloop) static Socket fromListen(Protocol protocol, NetworkAddress localAddress,
            NetworkAddress remoteAddress, scope return RCAllocator allocator = RCAllocator.init) {
        if(allocator.isNull)
            allocator = globalAllocator();

        Socket ret;
        ret.state = allocator.make!SocketState(allocator, protocol, true);
        ret.state.localAddress = localAddress;
        ret.state.remoteAddress = remoteAddress;

        return ret;
    }
}

///
ErrorResult startUpNetworking() @trusted {
    mutex.pureLock;
    scope(exit)
        mutex.unlock;

    if(isInitialized)
        return ErrorResult.init;

    if(!startUpNetworkingMechanism)
        return ErrorResult(UnknownPlatformBehaviorException("Could not start networking"));

    isInitialized = true;
    return ErrorResult.init;
}

///
void shutdownNetworking() @trusted {
    import sidero.eventloop.internal.event_waiting;

    mutex.pureLock;
    scope(exit)
        mutex.unlock;

    if(!isInitialized)
        return;

    shutdownEventWaiterThreads;
    shutdownNetworkingMechanism;
    isInitialized = false;
}

private:
import sidero.base.synchronization.mutualexclusion;

__gshared {
    TestTestSetLockInline mutex;
    bool isInitialized;
}

bool ensureItIsSetup() {
    import sidero.eventloop.tasks.workers;

    if(!startUpNetworking)
        return false;
    else if(!startWorkers(1))
        return false;

    return true;
}
