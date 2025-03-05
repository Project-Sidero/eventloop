module sidero.eventloop.sockets.client;
import sidero.eventloop.control;
import sidero.eventloop.sockets.server;
import sidero.eventloop.internal.networking.state;
import sidero.eventloop.handles;
import sidero.eventloop.certificates;
import sidero.eventloop.closure.callable;
import sidero.eventloop.coroutine.future;
import sidero.eventloop.coroutine.instanceable;
import sidero.base.path.hostname;
import sidero.base.attributes;
import sidero.base.containers.readonlyslice;
import sidero.base.containers.dynamicarray;
import sidero.base.allocators;
import sidero.base.errors;
import sidero.base.text;
import sidero.base.path.networking;
import sidero.base.internal.atomic;

export @safe nothrow @nogc:

///
enum SocketHandleIdentifier = SystemHandleType.from("socket");

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
    bool isNull() scope const {
        return state is null;
    }

    /// Warning: unsafe, you must handle reference counting and keeping this instance alive
    SystemHandle unsafeGetHandle() @system {
        if(isNull)
            return SystemHandle.init;
        return SystemHandle(cast(void*)this.state.handle, SocketHandleIdentifier);
    }

    ///
    bool isAlive() scope const {
        return !isNull && atomicLoad(state.isAlive);
    }

    ///
    bool isReadInProgress() scope {
        if(!isAlive)
            return false;

        bool ret;

        state.guard(() { ret = state.reading.inProgress; });

        return ret;
    }

    /// Stop sending & receiving of data
    void close(bool graceFully = true) scope {
        if(isNull)
            return;
        state.close(graceFully);
    }

    /// Can return less, if handle was closed
    Future!(Slice!ubyte) read(size_t amount) scope @trusted {
        if(isNull)
            return typeof(return).init;

        Future!(Slice!ubyte) ret;

        state.guard(() {
            const cond = state.reading.requestFromUser(amount, ret);

            if(cond)
                state.performReadWrite;
        });

        assert(!ret.isNull);
        return ret;
    }

    /// Reads a chunk that is 1 or more bytes big (depends upon implementation, and available data in stream)
    Future!(Slice!ubyte) readChunk() scope @trusted {
        if(isNull)
            return typeof(return).init;

        Future!(Slice!ubyte) ret;

        state.guard(() {
            const cond = state.reading.requestFromUserChunk(ret);

            if(cond)
                state.performReadWrite;
        });

        assert(!ret.isNull);
        return ret;
    }

    ///
    Future!(Slice!ubyte) readUntil(scope return DynamicArray!ubyte endCondition, bool giveDataOnEOF = false) scope {
        return this.readUntil(endCondition.asReadOnly(), giveDataOnEOF);
    }

    ///
    Future!(Slice!ubyte) readUntil(scope return String_ASCII endCondition, bool giveDataOnEOF = false) scope {
        return this.readUntil(endCondition.asSlice(), giveDataOnEOF);
    }

    ///
    Future!(Slice!ubyte) readUntil(scope return String_UTF8 endCondition, bool giveDataOnEOF = false) scope {
        return this.readUntil(endCondition.asRawSlice(), giveDataOnEOF);
    }

    ///
    Future!(Slice!ubyte) readUntil(scope return String_UTF16 endCondition, bool giveDataOnEOF = false) scope {
        return this.readUntil(endCondition.asRawSlice(), giveDataOnEOF);
    }

    ///
    Future!(Slice!ubyte) readUntil(scope return String_UTF32 endCondition, bool giveDataOnEOF = false) scope {
        return this.readUntil(endCondition.asRawSlice(), giveDataOnEOF);
    }

    ///
    Future!(Slice!ubyte) readUntil(scope return Slice!ubyte endCondition, bool giveDataOnEOF = false) scope @trusted {
        if(isNull)
            return typeof(return).init;

        Future!(Slice!ubyte) ret;

        state.guard(() @safe {
            const cond = state.reading.requestFromUser(endCondition, giveDataOnEOF, ret);

            if(cond)
                state.performReadWrite;
        });

        assert(!ret.isNull);
        return ret;
    }

    ///
    void write(scope return DynamicArray!ubyte data) scope {
        this.write(data.asReadOnly());
    }

    ///
    void write(scope return String_ASCII data) scope {
        this.write(data.asSlice());
    }

    ///
    void write(scope return String_UTF8 data) scope {
        this.write(data.asRawSlice());
    }

    ///
    void write(scope return String_UTF16 data) scope {
        this.write(data.asRawSlice());
    }

    ///
    void write(scope return String_UTF32 data) scope {
        this.write(data.asRawSlice());
    }

    ///
    void write(scope return Slice!ubyte data) scope {
        if(isAlive()) {
            state.guard(() @trusted { state.writing.appendToQueue(state, data); state.performReadWrite; });
        }
    }

    /// Add encryption to socket, uses client API by default
    alias addEncryption = addEncryptionClient;

    /**
        Adds encryption to socket, supply a certificate to represent this request and if you want to validate the servers' certificate.

        See_Also: addEncryption, addEncryptionServer
    */
    Result!FutureError addEncryptionClient(Hostname sniHostname = Hostname.init, EncryptionProtocol encryption = EncryptionProtocol.Best_TLS,
            Certificate certificate = Certificate.init, bool validateCertificates = true) scope {
        if(!isAlive())
            return typeof(return)(NullPointerException("Socket is not currently alive, so cannot be configured to have encryption"));

        Future!void ret;
        bool success;

        state.guard(() @safe {
            success = state.encryption.addEncryption(this.state, sniHostname, certificate, Closure!(Certificate,
                String_UTF8).init, encryption, validateCertificates);
            ret = state.encryption.encryptionSetupFuture;
        });

        if(!success)
            return typeof(return)(UnknownPlatformBehaviorException("Could not reinitialize encryption"));
        return typeof(return)(ret);
    }

    /**
        Adds encryption to listening socket, supply a certificate to represent this host for fallback purposes and a closure that'll provide SNI certificates.

        See_Also: addEncryption, addEncryptionClient
    */
    Result!FutureError addEncryptionServer(EncryptionProtocol encryption = EncryptionProtocol.Best_TLS,
            Certificate fallbackCertificate = Certificate.init, Closure!(Certificate, String_UTF8) acquireCertificateForSNI) scope {
        if(!isAlive())
            return typeof(return)(NullPointerException("Socket is not currently alive, so cannot be configured to have encryption"));

        Future!void ret;
        bool success;

        state.guard(() @safe {
            success = state.encryption.addEncryption(this.state, Hostname.init, fallbackCertificate,
                acquireCertificateForSNI, encryption, true);
            ret = state.encryption.encryptionSetupFuture;
        });

        if(!success)
            return typeof(return)(UnknownPlatformBehaviorException("Could not reinitialize encryption"));
        return typeof(return)(ret);
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

    /**
        Connect a socket to a network address.

        Params:
            address   = The network address to connect to, must not be a host name.
            protocol  = The socket protocol to connect via (TCP, UDP, ext.).
            allocator = The memory allocator use allocate with.

        Returns: The connected socket or the error.
    */
    static Result!Socket connectTo(NetworkAddress address, Socket.Protocol protocol, scope return RCAllocator allocator = RCAllocator.init) @trusted {
        import sidero.eventloop.control : registerAsTask;

        if(allocator.isNull)
            allocator = globalAllocator();

        if(!ensureItIsSetup)
            return typeof(return)(UnknownPlatformBehaviorException("Could not setup networking handling"));

        Socket ret;
        ret.state = allocator.make!SocketState(allocator, protocol);

        auto errorResult = ret.state.startUp(address);
        if(!errorResult)
            return typeof(return)(errorResult.getError());

        return typeof(return)(ret);
    }

    /**
        Connect a socket to a network address using a coroutine handler.

        Params:
            onConnect = The coroutine handler.
            address   = The network address to connect to, must not be a host name.
            protocol  = The socket protocol to connect via (TCP, UDP, ext.).
            allocator = The memory allocator use allocate with.

        Returns: The connected socket or the error.
    */
    static Result!Socket connectTo(InstanceableCoroutine!(void, Socket) onConnect, NetworkAddress address,
            Socket.Protocol protocol, scope return RCAllocator allocator = RCAllocator.init) @trusted {
        import sidero.eventloop.control : registerAsTask;

        if(onConnect.isNull)
            return typeof(return)(MalformedInputException("On connect coroutine cannot be null"));

        if(allocator.isNull)
            allocator = globalAllocator();

        typeof(return) ret = Socket.connectTo(address, protocol, allocator);

        if(ret) {
            auto connectSocketCO = onConnect.makeInstance(allocator, ret);
            registerAsTask(connectSocketCO);
        }

        return ret;
    }

    package(sidero.eventloop) static Socket fromListen(ListenSocketPair listenSocketPair, NetworkAddress localAddress,
            NetworkAddress remoteAddress, scope return RCAllocator allocator = RCAllocator.init) {
        if(allocator.isNull)
            allocator = globalAllocator();

        Socket ret;
        ret.state = allocator.make!SocketState(allocator, listenSocketPair);
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
        if(this.state < other.state)
            return -1;
        else if(this.state > other.state)
            return 1;
        else
            return 0;
    }

    /// A unique id, not the system handle.
    ulong toHash() scope const {
        return cast(size_t)state;
    }

    ///
    String_UTF8 toString() @trusted {
        StringBuilder_UTF8 ret = StringBuilder_UTF8();
        toString(ret);
        return ret.asReadOnly;
    }

    ///
    void toString(scope ref StringBuilder_UTF8 builder) @trusted {
        builder.formattedWrite("Socket({:p})", this.unsafeGetHandle().handle);
    }

    ///
    String_UTF8 toStringPretty(PrettyPrint pp) @trusted {
        StringBuilder_UTF8 ret = StringBuilder_UTF8();
        toStringPretty(ret, pp);
        return ret.asReadOnly;
    }

    ///
    void toStringPretty(scope ref StringBuilder_UTF8 builder, PrettyPrint pp) @trusted {
        pp.emitPrefix(builder);

        builder.formattedWrite("Socket({:p}@{:p}, isAlive={:s}, isReadInProgress={:s})", this.unsafeGetHandle().handle,
                cast(void*)this.state, this.isAlive, this.isReadInProgress);
    }
}
