module sidero.eventloop.closure.generic;
import sidero.base.errors;

///
struct GenericClosure {
    package(sidero.eventloop.closure) {
        import sidero.eventloop.closure.internal.state;
        ClosureGenericDescriptor descriptor;
        ClosureGenericPartialWrapper partialState;
    }

export @safe nothrow @nogc:

    ///
    this(ref return scope GenericClosure other) scope {
        this.tupleof = other.tupleof;

        if (descriptor.untyped !is null)
            descriptor.untyped.rc(true);
    }

    ///
    ~this() scope {
        if (descriptor.untyped !is null)
            descriptor.untyped.rc(false);
    }

    ///
    bool isNull() scope const {
        return descriptor.untyped is null;
    }

    ///
    ErrorResult opCall() scope @trusted {
        if (isNull)
            return typeof(return)(NullPointerException("Closure is null"));

        if (partialState.isNull) {
            return descriptor.untypedToCall(descriptor.untyped.toDeallocate.ptr, descriptor.typedToCall);
        } else {
            return partialState.untypedToCall(descriptor.untyped.toDeallocate.ptr, partialState.partialTypedToCall, descriptor.typedToCall);
        }
    }
}
