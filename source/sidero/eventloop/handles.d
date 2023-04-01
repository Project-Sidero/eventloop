module sidero.eventloop.handles;
import sidero.base.text;

struct SystemHandle {
    void* handle;
    SystemHandleType type;

export @safe nothrow @nogc:
    bool isNull() scope {
        return handle is null || type.isNone;
    }
}

///
union SystemHandleType {
    ///
    long value;
    char[8] text_;
    alias value this;

export @safe nothrow @nogc:

    ///
    static SystemHandleType from(const char[] from...) scope @trusted
    in {
        assert(from.length > 0);
        assert(from.length <= 8);
    }
    do {
        ubyte[8] rstr = cast(ubyte)' ';
        rstr[0 .. from.length] = cast(ubyte[])from[];

        return SystemHandleType(rstr[0] | (rstr[1] << (1 * 8)) | (rstr[2] << (2 * 8)) | (rstr[3] << (3 * 8)) | (
                cast(long)rstr[4] << (4 * 8)) | (cast(long)rstr[5] << (5 * 8)) | (cast(long)rstr[6] << (6 * 8)) | (
                cast(long)rstr[7] << (7 * 8)));
    }

    ///
    @property static SystemHandleType all() scope {
        return SystemHandleType(0x2020202020202020);
    }

    ///
    @property static SystemHandleType none() scope {
        return SystemHandleType.init;
    }

    ///
    bool isNone() const scope {
        return this.value == 0;
    }

    ///
    String_UTF8 toString() const scope @trusted {
        char[8] text;
        ulong temp = value;
        foreach (i; 0 .. 8) {
            text[i] = cast(char)temp;

            temp /= 256;
        }

        return String_UTF8(text[]).stripRight.dup;
    }

    ///
    bool opEquals(const SystemHandleType other) const scope @trusted {
        import std.algorithm : countUntil;

        String_UTF8 first = String_UTF8(text_), second = String_UTF8(other.text_);
        const i = first.indexOf(" "), j = second.indexOf(" ");

        if ((i < j || j < 0) && i >= 0) {
            // this == other
            return first[0 .. i] == second[0 .. i];
        } else
            return value == other.value;
    }
}
