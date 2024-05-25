module sidero.eventloop.sockets;
import sidero.eventloop.internal.networking.state;
import sidero.eventloop.internal.networking.platform;
import sidero.eventloop.certificates;
import sidero.eventloop.coroutine.instanceable;
import sidero.eventloop.coroutine.future;
import sidero.eventloop.closure.callable;
import sidero.eventloop.handles;
import sidero.base.containers.dynamicarray;
import sidero.base.path.networking;
import sidero.base.path.hostname;
import sidero.base.allocators;
import sidero.base.attributes;
import sidero.base.containers.readonlyslice;
import sidero.base.containers.dynamicarray;
import sidero.base.errors;
import sidero.base.internal.atomic;
import sidero.base.text;
import sidero.base.typecons : Optional;
import sidero.base.datetime.duration;

export @safe nothrow @nogc:

///
enum SocketHandleIdentifier = SystemHandleType.from("socket");

///
struct ListenSocket {
    package(sidero.eventloop) @PrintIgnore @PrettyPrintIgnore {
        ListenSocketState* state;
    }

export @safe nothrow @nogc:

    ///
    this(return scope ref ListenSocket other) scope {
        this.state = other.state;

        if (state !is null)
            state.rc(true);
    }

    ///
    ~this() scope {
        if (state !is null)
            state.rc(false);
    }

    ///
    bool isNull() scope const {
        return state is null;
    }

    ///
    NetworkAddress address() scope {
        if (isNull)
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
            bool reuseAddr = true, Optional!Duration keepAlive = Optional!Duration.init,
            bool validateCertificates = true, scope return RCAllocator allocator = RCAllocator.init) @trusted {

        if (!onAccept.canInstance)
            return typeof(return)(MalformedInputException("On accept coroutine cannot be null"));

        if (allocator.isNull)
            allocator = globalAllocator();

        if (!ensureItIsSetup)
            return typeof(return)(UnknownPlatformBehaviorException("Could not setup networking handling"));

        ListenSocket ret;
        ret.state = allocator.make!ListenSocketState(allocator, onAccept, address, protocol, encryption,
                fallbackCertificate, validateCertificates);

        if (!ret.state.startUp(reuseAddr, keepAlive))
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

        if (state !is null)
            state.rc(true);
    }

    ///
    ~this() scope nothrow @nogc {
        if (state !is null)
            state.rc(false);
    }

    ///
    bool isNull() scope const {
        return state is null;
    }

    /// Warning: unsafe, you must handle reference counting and keeping this instance alive
    SystemHandle unsafeGetHandle() @system {
        if (isNull)
            return SystemHandle.init;
        return SystemHandle(this.state.handle, SocketHandleIdentifier);
    }

    ///
    bool isAlive() scope const {
        return !isNull && atomicLoad(state.isAlive);
    }

    ///
    bool isReadInProgress() scope {
        if (!isAlive)
            return false;

        bool ret;

        state.guard(() { ret = state.reading.inProgress; });

        return ret;
    }

    /// Stop sending & receiving of data
    void close(bool graceFully = true) scope {
        if (isNull)
            return;
        state.close(graceFully);
    }

    ///
    Future!(Slice!ubyte) read(size_t amount) scope @trusted {
        if (isNull)
            return typeof(return).init;

        Future!(Slice!ubyte) ret;

        state.guard(() {
            const cond = state.reading.requestFromUser(amount, ret);
            const nowOrNever = state.haveBeenShutdown;

            if (cond) {
                state.performReadWrite;

                if (nowOrNever && !ret.isComplete()) {
                    state.reading.cleanup();
                }
            }
        });

        return ret;
    }

    ///
    Future!(Slice!ubyte) readUntil(scope return DynamicArray!ubyte endCondition) scope {
        return this.readUntil(endCondition.asReadOnly());
    }

    ///
    Future!(Slice!ubyte) readUntil(scope return Slice!ubyte endCondition) scope @trusted {
        if (isNull)
            return typeof(return).init;

        Future!(Slice!ubyte) ret;

        state.guard(() @safe {
            const cond = state.reading.requestFromUser(endCondition, ret);
            const nowOrNever = state.haveBeenShutdown;

            if (cond) {
                state.performReadWrite;

                if (nowOrNever && !ret.isComplete()) {
                    state.reading.cleanup();
                }
            }
        });

        return ret;
    }

    ///
    void write(scope return DynamicArray!ubyte data) scope {
        this.write(data.asReadOnly());
    }

    ///
    void write(scope return Slice!ubyte data) scope {
        if (isAlive()) {
            state.guard(() @trusted { state.writing.appendToQueue(state, data); state.performReadWrite; });
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
        if (!isAlive())
            return ErrorResult(NullPointerException("Socket is not currently alive, so cannot be configured to have encryption"));

        if (!state.encryption.addEncryption(this.state, sniHostname, certificate, Closure!(Certificate, String_UTF8)
                .init, encryption, validateCertificates))
            return ErrorResult(UnknownPlatformBehaviorException("Could not reinitialize encryption"));
        return ErrorResult.init;
    }

    /**
        Adds encryption to listening socket, supply a certificate to represent this host for fallback purposes and a closure that'll provide SNI certificates.

        See_Also: addEncryption, addEncryptionClient
    */
    ErrorResult addEncryptionServer(EncryptionProtocol encryption = EncryptionProtocol.Best_TLS,
            Certificate fallbackCertificate = Certificate.init, Closure!(Certificate, String_UTF8) acquireCertificateForSNI) scope {
        if (!isAlive())
            return ErrorResult(NullPointerException("Socket is not currently alive, so cannot be configured to have encryption"));

        if (!state.encryption.addEncryption(this.state, Hostname.init, fallbackCertificate, acquireCertificateForSNI, encryption, true))
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
            Socket.Protocol protocol, Optional!Duration keepAlive = Optional!Duration.init,
            scope return RCAllocator allocator = RCAllocator.init) @trusted {
        import sidero.eventloop.tasks.workers : registerAsTask;

        if (!onConnect.canInstance)
            return typeof(return)(MalformedInputException("On connect coroutine cannot be null"));

        if (allocator.isNull)
            allocator = globalAllocator();

        if (!ensureItIsSetup)
            return typeof(return)(UnknownPlatformBehaviorException("Could not setup networking handling"));

        Socket ret;
        ret.state = allocator.make!SocketState(allocator, protocol, false);

        auto errorResult = ret.state.startUp(address, keepAlive);
        if (!errorResult)
            return typeof(return)(errorResult.getError());

        auto connectSocketCO = onConnect.makeInstance(RCAllocator.init, ret);
        registerAsTask(connectSocketCO);

        return typeof(return)(ret);
    }

    package(sidero.eventloop) static Socket fromListen(Protocol protocol, NetworkAddress localAddress,
            NetworkAddress remoteAddress, scope return RCAllocator allocator = RCAllocator.init) {
        if (allocator.isNull)
            allocator = globalAllocator();

        Socket ret;
        ret.state = allocator.make!SocketState(allocator, protocol, true);
        ret.state.localAddress = localAddress;
        ret.state.remoteAddress = remoteAddress;

        return ret;
    }

    ///
    bool opEquals(scope const ref Socket other) scope const {
        return this.state is other.state;
    }

    ///
    int opCmp(scope const ref Socket other) scope const {
        if (this.state < other.state)
            return -1;
        else if (this.state > other.state)
            return 1;
        else
            return 0;
    }

    /// A unique id, not the system handle.
    ulong toHash() scope const {
        return cast(size_t)state;
    }

    ///
    String_UTF8 toString(RCAllocator allocator = RCAllocator.init) @trusted {
        StringBuilder_UTF8 ret = StringBuilder_UTF8(allocator);
        toString(ret);
        return ret.asReadOnly;
    }

    ///
    void toString(Sink)(scope ref Sink sink) @trusted {
        sink.formattedWrite("Socket({:p})", this.unsafeGetHandle().handle);
    }

    ///
    String_UTF8 toStringPretty(RCAllocator allocator = RCAllocator.init) @trusted {
        StringBuilder_UTF8 ret = StringBuilder_UTF8(allocator);
        toStringPretty(ret);
        return ret.asReadOnly;
    }

    ///
    void toStringPretty(Sink)(scope ref Sink sink) @trusted {
        sink.formattedWrite("Socket({:p}@{:p}, isAlive={:s}, isReadInProgress={:s})", this.unsafeGetHandle().handle,
                cast(void*)this.state, this.isAlive, this.isReadInProgress);
    }
}

///
ErrorResult startUpNetworking() @trusted {
    mutex.pureLock;
    scope (exit)
        mutex.unlock;

    if (isInitialized)
        return ErrorResult.init;

    if (!startUpNetworkingMechanism)
        return ErrorResult(UnknownPlatformBehaviorException("Could not start networking"));

    isInitialized = true;
    return ErrorResult.init;
}

///
void shutdownNetworking() @trusted {
    import sidero.eventloop.internal.event_waiting;

    mutex.pureLock;
    scope (exit)
        mutex.unlock;

    if (!isInitialized)
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

    if (!startUpNetworking)
        return false;
    else if (!startWorkers(0))
        return false;

    return true;
}
