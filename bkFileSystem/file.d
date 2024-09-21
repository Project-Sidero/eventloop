module sidero.eventloop.filesystem.file;
import sidero.eventloop.filesystem.introspection;
import sidero.eventloop.handles;
import sidero.eventloop.coroutine.future;
import sidero.eventloop.internal.filesystem.state;
import sidero.base.attributes;
import sidero.base.containers.readonlyslice;
import sidero.base.containers.dynamicarray;
import sidero.base.allocators;
import sidero.base.errors;
import sidero.base.text;
import sidero.base.path.file;

export @safe nothrow @nogc:

///
enum FileHandleIdentifier = SystemHandleType.from("file");

///
struct FileRights {
    ///
    bool read;
    ///
    bool write;
    ///
    bool create;
    ///
    bool forceAppend;
    ///
    bool createAsExecutable;
}

///
struct File {
    package(sidero.eventloop) @PrintIgnore @PrettyPrintIgnore {
        FileState* state;
    }

export @safe nothrow @nogc:

    this(return scope ref File other) scope nothrow {
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
        return this.state is null;
    }

    ///
    SystemHandle unsafeGetHandle() @system {
        if(this.isNull)
            return SystemHandle.init;
        else
            return SystemHandle(this.state.handle, FileHandleIdentifier);
    }

    ///
    bool isAlive() scope const {
        import sidero.base.internal.atomic;

        if (isNull)
            return false;
        return atomicLoad(this.state.isAlive);
    }

    ///
    bool isReadInProgress() scope {
        if (isNull)
            return false;

        bool ret;

        this.state.guard(() {
            ret = this.state.rawReading.inProgress();
        });

        return ret;
    }

    ///
    FileRights rights() scope {
        if(this.isNull)
            return FileRights.init;
        else
            return this.state.fileRights;
    }

    ///
    void close() scope {
        if (!isNull)
            state.close();
    }

    Future!(Slice!ubyte) read(size_t amount) scope @trusted;
    Future!(Slice!ubyte) readUntil(scope return DynamicArray!ubyte endCondition) scope;
    Future!(Slice!ubyte) readUntil(scope return Slice!ubyte endCondition) scope @trusted;
    void write(scope return DynamicArray!ubyte data) scope;
    void write(scope return Slice!ubyte data) scope;

    ///
    bool opEquals(scope const ref File other) scope const {
        return this.state !is null && this.state is other.state;
    }

    ///
    int opCmp(scope const ref File other) scope const {
        if(this.state < other.state)
            return -1;
        else if(this.state is other.state)
            return 0;
        else
            return 1;
    }

    ///
    ulong toHash() scope const {
        return cast(ulong)this.state;
    }

    ///
    String_UTF8 toString(RCAllocator allocator = RCAllocator.init) @trusted {
        StringBuilder_UTF8 ret = StringBuilder_UTF8(allocator);
        toString(ret);
        return ret.asReadOnly;
    }

    ///
    void toString(Sink)(scope ref Sink sink) @trusted {
        sink.formattedWrite("File({:p})", this.unsafeGetHandle().handle);
    }

    ///
    String_UTF8 toStringPretty(RCAllocator allocator = RCAllocator.init) @trusted {
        StringBuilder_UTF8 ret = StringBuilder_UTF8(allocator);
        toStringPretty(ret);
        return ret.asReadOnly;
    }

    ///
    void toStringPretty(Sink)(scope ref Sink sink) @trusted {
        sink.formattedWrite("File({:p}@{:p}, isAlive={:s}, isReadInProgress={:s})", this.unsafeGetHandle().handle,
                cast(void*)this.state, this.isAlive, this.isReadInProgress);
    }

    ///
    static Result!File from(FilePath path, bool read = true, bool write = false, bool create = false, bool forceAppend = false,
            bool createAsExecutable = false) {
        return File.from(path, FileRights(read, write, create, forceAppend, createAsExecutable));
    }

    ///
    static Result!File from(FilePath path, FileRights rights) @trusted {
        import sidero.eventloop.filesystem.control : ensureItIsSetup;
        if (!ensureItIsSetup)
            return typeof(return)(UnknownPlatformBehaviorException("Could not start filesystem and workers"));

        if(!rights.read && !rights.write)
            return typeof(return)(MalformedInputException("Expected file rights must include at least one requested"));
        ulong estimatedSize;

        {
            auto got = path.size;
            if(!got && !rights.create)
                return typeof(return)(MalformedInputException("Input path must point to a file system entry to open/create"));
            if(got)
                estimatedSize = got;
        }

        RCAllocator allocator = globalAllocator();
        File ret;
        ret.state = allocator.make!FileState(allocator, path.dup, rights, estimatedSize);

        auto err = connectToSpecificFile(ret);
        if (!err)
            return typeof(return)(err.getError);

        return typeof(return)(ret);
    }
}
