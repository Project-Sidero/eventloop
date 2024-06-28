module sidero.eventloop.sockets.server;
import sidero.eventloop.sockets.control;
import sidero.eventloop.sockets.client;
import sidero.eventloop.internal.networking.state;
import sidero.eventloop.coroutine.instanceable;
import sidero.eventloop.certificates;
import sidero.base.attributes;
import sidero.base.path.networking;
import sidero.base.errors;
import sidero.base.datetime.duration;
import sidero.base.allocators;
import sidero.base.typecons : Optional;
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

    /**
        Listen on a set of network addresses with optional encryption using a coroutine handler per socket.

        Params:
            onAccept             = The coroutine that will be instanced with a socket.
            address              = The address to listen on, hostnames must map directly to a network address of this machine (such as localhost).
            protocol             = The socket protocol (TCP, UDP, ext.) to listen via, only set this if you don't need to do per-socket certificates.
            encryption           = The encryption protocol to apply to any connections established.
            fallbackCertificate  = If no certificate can be found, fallback to this one.
            reuseAddr            = Set the listen socket as having a reusable address, ideally with load balancing between processes.
            keepAliveInterval    = Start keep alive with a provided interval. Not all platforms support setting the interval so use a non-zero value.
            validateCertificates = Any certificates that are seen for encryption, do they need to validate? (Turn off for unsigned).
            allocator            = The memory allocator to use.

        Returns: The listen socket or the error.
    */
    static Result!ListenSocket from(InstanceableCoroutine!(void, Socket) onAccept, NetworkAddress address, Socket.Protocol protocol,
        Socket.EncryptionProtocol encryption = Socket.EncryptionProtocol.None, Certificate fallbackCertificate = Certificate.init,
        bool reuseAddr = true, Optional!Duration keepAliveInterval = Optional!Duration.init,
        bool validateCertificates = true, scope return RCAllocator allocator = RCAllocator.init) @trusted {

        if (onAccept.isNull)
            return typeof(return)(MalformedInputException("On accept coroutine cannot be null"));

        if (allocator.isNull)
            allocator = globalAllocator();

        if (!ensureItIsSetup)
            return typeof(return)(UnknownPlatformBehaviorException("Could not setup networking handling"));

        ListenSocket ret;
        ret.state = allocator.make!ListenSocketState(allocator, onAccept, address, protocol, encryption,
        fallbackCertificate, validateCertificates);

        if (!ret.state.startUp(reuseAddr, keepAliveInterval))
            return typeof(return)(UnknownPlatformBehaviorException("Could not initialize socket"));

        return typeof(return)(ret);
    }
}
