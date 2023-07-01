module sidero.eventloop.networking.sockets;
import sidero.eventloop.networking.internal.state;
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
alias SocketReadCallback = void function(Socket socket, DynamicArray!ubyte data) @safe nothrow @nogc;

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
    static Result!ListenSocket from(ListenSocketOnAccept handler, NetworkAddress address, Socket.Protocol protocol,
            bool reuseAddr = true, bool keepAlive = true, scope return RCAllocator allocator = RCAllocator.init) {
        if (allocator.isNull)
            allocator = globalAllocator();

        if (!ensureItIsSetup)
            return typeof(return)(UnknownPlatformBehaviorException("Could not setup networking handling"));

        ListenSocket ret;
        ret.state = allocator.make!ListenSocketState;
        ret.state.allocator = allocator;

        ret.state.onAcceptHandler = handler;
        ret.state.address = address;
        ret.state.protocol = protocol;

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
        return isAlive() && state.reading.inProgress;
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

        if (!state.reading.perform(amount, onRecieve))
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

        if (!state.reading.perform(endCondition, onRecieve))
            return false;

        return state.triggerRead(state);
    }

    ///
    bool write(scope return DynamicArray!ubyte data) scope {
        return this.write(data.asReadOnly());
    }

    ///
    bool write(scope return Slice!ubyte data) scope @trusted {
        state.writing.perform(data);
        state.triggerWrite(state);
        return true;
    }

    ///
    enum Protocol {
        ///
        TCP,
        ///
        UDP,
    }

    package(sidero.eventloop) static Socket fromListen(Protocol protocol, NetworkAddress localAddress,
            NetworkAddress remoteAddress, scope return RCAllocator allocator = RCAllocator.init) {
        if (allocator.isNull)
            allocator = globalAllocator();

        Socket ret;
        ret.state = allocator.make!SocketState;
        ret.state.allocator = allocator;

        ret.state.protocol = protocol;
        ret.state.localAddress = localAddress;
        ret.state.remoteAddress = remoteAddress;

        return ret;
    }
}

ErrorResult startUpNetworking() @trusted  {
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
