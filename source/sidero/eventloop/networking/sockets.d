module sidero.eventloop.networking.sockets;
import sidero.eventloop.networking.internal.state;
import sidero.eventloop.certificates;
import sidero.base.containers.dynamicarray;
import sidero.base.path.networking;
import sidero.base.allocators;
import sidero.base.attributes;
import sidero.base.containers.readonlyslice;
import sidero.base.containers.dynamicarray;
import sidero.base.errors;

export @safe nothrow @nogc:

///
alias ListenSocketOnAccept = void function(Socket) @safe nothrow @nogc;
///
alias SocketReadCallback = void function(Socket socket, Slice!ubyte data) @safe nothrow @nogc;
///
alias SocketShutdownCallback = void function(Socket socket) @safe nothrow @nogc;

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
    bool isNull() scope {
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
        import core.atomic : atomicLoad;

        return !isNull && atomicLoad(state.isAlive);
    }

    /// Listen on port
    static Result!ListenSocket from(ListenSocketOnAccept onAcceptCallback, SocketShutdownCallback onShutdownCallback, NetworkAddress address, Socket.Protocol protocol,
            Socket.EncryptionProtocol encryption = Socket.EncryptionProtocol.None, Certificate certificate = Certificate.init,
            bool reuseAddr = true, bool keepAlive = true, bool validateCertificates = true, scope return RCAllocator allocator = RCAllocator.init) {
        if (allocator.isNull)
            allocator = globalAllocator();

        if (!ensureItIsSetup)
            return typeof(return)(UnknownPlatformBehaviorException("Could not setup networking handling"));

        ListenSocket ret;
        ret.state = allocator.make!ListenSocketState;
        ret.state.allocator = allocator;

        ret.state.onAcceptHandler = onAcceptCallback;
        ret.state.onShutdownHandler = onShutdownCallback;
        ret.state.address = address;
        ret.state.protocol = protocol;
        ret.state.encryption = encryption;
        ret.state.certificate = certificate;
        ret.state.validateCertificates = validateCertificates;

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
    bool isNull() scope {
        return state is null;
    }

    ///
    bool isAlive() scope {
        import core.atomic : atomicLoad;

        return !isNull && atomicLoad(state.isAlive);
    }

    ///
    bool isReadInProgress() scope {
        return isAlive() && state.readingState.inProgress;
    }

    /// Stop sending & receiving of data
    void close(bool graceFully = true) scope {
        if (isNull)
            return;
        state.close(graceFully);
    }

    ///
    bool read(size_t amount, scope return SocketReadCallback onRecieve) scope @trusted {
        if (isReadInProgress)
            return false;

        if (!state.readingState.requestFromUser(amount, onRecieve))
            return false;

        return state.triggerRead(state);
    }

    ///
    bool readUntil(scope return DynamicArray!ubyte endCondition, scope return SocketReadCallback onRecieve) scope {
        return this.readUntil(endCondition.asReadOnly(), onRecieve);
    }

    ///
    bool readUntil(scope return Slice!ubyte endCondition, scope return SocketReadCallback onRecieve) scope @trusted {
        if (isReadInProgress)
            return false;

        if (!state.readingState.requestFromUser(endCondition, onRecieve))
            return false;

        state.triggerRead(state);
        return true;
    }

    ///
    Expected write(scope return DynamicArray!ubyte data) scope {
        return this.write(data.asReadOnly());
    }

    ///
    Expected write(scope return Slice!ubyte data) scope @trusted {
        if (!isAlive())
            return Expected(data.length, 0);

        auto expected = state.encryptionState.writeData(state, data);
        if (expected)
            state.triggerWrite(state);
        return expected;
    }

    ///
    ErrorResult addEncryption(EncryptionProtocol encryption = EncryptionProtocol.Best_TLS,
            Certificate certificate = Certificate.init, bool validateCertificates = true) scope {
        if (!isAlive())
            return ErrorResult(NullPointerException("Socket is not currently alive, so cannot be configured to have encryption"));

        if (!state.encryptionState.addEncryption(this.state, certificate, encryption, validateCertificates))
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
    static Result!Socket connectTo(SocketShutdownCallback onShutdownCallback, NetworkAddress address, Socket.Protocol protocol, bool keepAlive = true,
            scope return RCAllocator allocator = RCAllocator.init) {
        if (allocator.isNull)
            allocator = globalAllocator();

        Socket ret;
        ret.state = allocator.make!SocketState;
        ret.state.allocator = allocator;
        ret.state.onShutdownHandler = onShutdownCallback;

        ret.state.protocol = protocol;

        auto errorResult = ret.state.startUp(address, keepAlive);
        if (!errorResult)
            return typeof(return)(errorResult.getError());
        return typeof(return)(ret);
    }

    package(sidero.eventloop) static Socket fromListen(SocketShutdownCallback onShutdownCallback, Protocol protocol, NetworkAddress localAddress,
            NetworkAddress remoteAddress, scope return RCAllocator allocator = RCAllocator.init) {
        if (allocator.isNull)
            allocator = globalAllocator();

        Socket ret;
        ret.state = allocator.make!SocketState;
        ret.state.allocator = allocator;
        ret.state.onShutdownHandler = onShutdownCallback;

        ret.state.protocol = protocol;
        ret.state.localAddress = localAddress;
        ret.state.remoteAddress = remoteAddress;

        return ret;
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
    else if (!startWorkers(1))
        return false;

    return true;
}
