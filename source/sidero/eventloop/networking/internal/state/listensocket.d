module sidero.eventloop.networking.internal.state.listensocket;
import sidero.eventloop.networking.internal.platform;
import sidero.eventloop.coroutine.instanceable;
import sidero.eventloop.sockets;
import sidero.eventloop.certificates;
import sidero.base.path.networking;
import sidero.base.containers.map.concurrenthashmap;
import sidero.base.allocators;
import sidero.base.internal.atomic;
import sidero.base.typecons : Optional;
import sidero.base.datetime.duration;

@safe nothrow @nogc:

struct ListenSocketState {
    private {
        RCAllocator allocator;

        shared(ptrdiff_t) refCount;
    }

    shared(ptrdiff_t) isAlive;

    NetworkAddress address;
    Socket.Protocol protocol;

    Certificate fallbackCertificate;
    Socket.EncryptionProtocol encryption;
    bool validateCertificates;

    InstanceableCoroutine!(void, Socket) onAccept;
    ConcurrentHashMap!(PlatformListenSocketKey, PlatformListenSocket) platformSockets;

@safe nothrow @nogc:

    this(return scope RCAllocator allocator, return scope InstanceableCoroutine!(void, Socket) onAccept,
            return scope NetworkAddress address, Socket.Protocol protocol, Socket.EncryptionProtocol encryption,
            return scope Certificate fallbackCertificate, bool validateCertificates) {
        this.allocator = allocator;
        this.refCount = 1;

        this.onAccept = onAccept;
        this.address = address;
        this.protocol = protocol;
        this.encryption = encryption;
        this.fallbackCertificate = fallbackCertificate;
        this.validateCertificates = validateCertificates;
    }

    void rc(bool addRef) scope @trusted {
        if(addRef)
            atomicIncrementAndLoad(refCount, 1);
        else {
            ptrdiff_t refCount = atomicDecrementAndLoad(this.refCount, 1);

            if(refCount == 0) {
                if(atomicLoad(isAlive)) {
                    foreach(pls; platformSockets) {
                        if(pls) {
                            if(atomicLoad(pls.isAlive))
                                forceClose(&pls.get());
                        }
                    }
                }

                foreach(pls; platformSockets) {
                    if(pls) {
                        if(atomicLoad(pls.isAlive))
                            cleanup(&pls.get());
                    }
                }

                RCAllocator allocator = this.allocator;
                allocator.dispose(&this);
            }
        }
    }

    void pin(ptrdiff_t amount) scope {
        if(atomicLoad(isAlive) > 0)
            assert(0, "Pinned");

        rc(true);
        atomicStore(isAlive, amount);
    }

    void unpin() scope {
        if(atomicLoad(isAlive) == 0)
            assert(0, "Not pinned");

        if(atomicDecrementAndLoad(isAlive, 1) == 0)
            rc(false);
    }

    bool startUp(bool reuseAddr, Optional!Duration keepAlive) scope @trusted {
        return listenOnAddress(&this, reuseAddr, keepAlive);
    }
}
