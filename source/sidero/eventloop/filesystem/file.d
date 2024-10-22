module sidero.eventloop.filesystem.file;
import sidero.eventloop.filesystem.introspection;
import sidero.eventloop.handles;
import sidero.eventloop.coroutine;
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
    /// If file exists, it will fail to open.
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

        if(isNull)
            return false;
        return atomicLoad(this.state.isAlive);
    }

    ///
    bool isReadInProgress() scope {
        if(isNull)
            return false;

        bool ret;

        this.state.guard(() { ret = this.state.rawReading.inProgress(); });

        return ret;
    }

    ///
    FilePath path() scope {
        if(this.isNull)
            return FilePath.init;
        else
            return state.filePath;
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
        if(!isNull)
            state.close();
    }

    ///
    Result!ulong size() scope {
        import sidero.eventloop.internal.filesystem.platform;

        if(this.isNull)
            return typeof(return)(NullPointerException);
        else
            return typeof(return)(getFileSize(state));
    }

    /**
        Checks to see if read seek position is at or after end of file.
        Only call this if no reads are in progress, otherwise it will be inaccurate.
    */
    bool isReadEOF() scope {
        import sidero.eventloop.internal.filesystem.platform;

        if(this.isNull)
            return false;

        ulong position;
        bool inProgress;
        const size = getFileSize(state);

        state.guard(() {
            position = state.currentReadPosition;
        });

        return position >= size;
    }

    /// If pending read, this will be the position the read started at
    ulong seekReadPosition() scope {
        if(this.isNull)
            return 0;

        ulong ret;

        state.guard(() { ret = state.currentReadPosition; });

        return ret;
    }

    ///
    ulong seekWritePosition() scope {
        if(this.isNull)
            return 0;

        ulong ret;

        state.guard(() { ret = state.currentWritePosition; });

        return ret;
    }

    ///
    void seekRead(long offsetFromCurrent) scope {
        import sidero.eventloop.internal.filesystem.platform;

        if(this.isNull)
            return;

        state.guard(() {
            const size = getFileSize(state);
            long pos = state.currentReadPosition + offsetFromCurrent;

            if(pos < 0)
                pos = 0;
            else if(pos > size)
                pos = size;

            state.currentReadPosition = pos;
            state.noUpdateReadPosition = true;
        });
    }

    ///
    void seekReadFromStart(long offsetFromStart) scope {
        import sidero.eventloop.internal.filesystem.platform;

        if(this.isNull)
            return;

        state.guard(() {
            const size = getFileSize(state);
            long pos = offsetFromStart;

            if(pos < 0)
                pos = 0;
            else if(pos > size)
                pos = size;

            state.currentReadPosition = pos;
            state.noUpdateReadPosition = true;
        });
    }

    ///
    void seekReadFromEnd(long offsetFromEnd) scope {
        import sidero.eventloop.internal.filesystem.platform;

        if(this.isNull)
            return;

        state.guard(() {
            const size = getFileSize(state);
            long pos = size - offsetFromEnd;

            if(pos < 0)
                pos = 0;
            else if(pos > size)
                pos = size;

            state.currentReadPosition = pos;
            state.noUpdateReadPosition = true;
        });
    }

    ///
    void seekWrite(long offsetFromCurrent) scope {
        import sidero.eventloop.internal.filesystem.platform;

        if(this.isNull)
            return;

        state.guard(() {
            const size = getFileSize(state);
            long pos = state.currentWritePosition + offsetFromCurrent;

            if(pos < 0)
                pos = 0;
            else if(pos > size)
                pos = size;

            state.currentWritePosition = pos;
        });
    }

    ///
    void seekWriteFromStart(long offsetFromStart) scope {
        import sidero.eventloop.internal.filesystem.platform;

        if(this.isNull)
            return;

        state.guard(() {
            const size = getFileSize(state);
            long pos = offsetFromStart;

            if(pos < 0)
                pos = 0;
            else if(pos > size)
                pos = size;

            state.currentWritePosition = pos;
        });
    }

    ///
    void seekWriteFromEnd(long offsetFromEnd) scope {
        import sidero.eventloop.internal.filesystem.platform;

        if(this.isNull)
            return;

        state.guard(() {
            const size = getFileSize(state);
            long pos = size - offsetFromEnd;

            if(pos < 0)
                pos = 0;
            else if(pos > size)
                pos = size;

            state.currentWritePosition = pos;
        });
    }

    ///
    void seekReadWrite(long offsetFromCurrentRead, long offsetFromCurrentWrite) scope {
        import sidero.eventloop.internal.filesystem.platform;

        if(this.isNull)
            return;

        state.guard(() {
            const size = getFileSize(state);
            long posRead = state.currentReadPosition + offsetFromCurrentRead;
            long posWrite = state.currentWritePosition + offsetFromCurrentWrite;

            if(posRead < 0)
                posRead = 0;
            else if(posRead > size)
                posRead = size;

            if(posWrite < 0)
                posWrite = 0;
            else if(posWrite > size)
                posWrite = size;

            state.currentReadPosition = posRead;
            state.noUpdateReadPosition = true;

            state.currentWritePosition = posWrite;
        });
    }

    ///
    void seekReadWriteFromStart(long offsetFromStart) scope {
        import sidero.eventloop.internal.filesystem.platform;

        if(this.isNull)
            return;

        state.guard(() {
            const size = getFileSize(state);
            long pos = offsetFromStart;

            if(pos < 0)
                pos = 0;
            else if(pos > size)
                pos = size;

            state.currentReadPosition = pos;
            state.noUpdateReadPosition = true;

            state.currentWritePosition = pos;
        });
    }

    ///
    void seekReadWriteFromEnd(long offsetFromEnd) scope {
        import sidero.eventloop.internal.filesystem.platform;

        if(this.isNull)
            return;

        state.guard(() {
            const size = getFileSize(state);
            long pos = size - offsetFromEnd;

            if(pos < 0)
                pos = 0;
            else if(pos > size)
                pos = size;

            state.currentReadPosition = pos;
            state.noUpdateReadPosition = true;

            state.currentWritePosition = pos;
        });
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
    GenericCoroutine write(scope return DynamicArray!ubyte data) scope {
        return this.write(data.asReadOnly());
    }

    ///
    GenericCoroutine write(scope return String_ASCII data) scope {
        return this.write(data.asSlice());
    }

    ///
    GenericCoroutine write(scope return String_UTF8 data) scope {
        return this.write(data.asRawSlice());
    }

    ///
    GenericCoroutine write(scope return String_UTF16 data) scope {
        return this.write(data.asRawSlice());
    }

    ///
    GenericCoroutine write(scope return String_UTF32 data) scope {
        return this.write(data.asRawSlice());
    }

    ///
    GenericCoroutine write(scope return Slice!ubyte data) scope {
        GenericCoroutine ret;

        if(isAlive()) {
            state.guard(() @trusted {
                state.rawWriting.push(data, state.currentWritePosition, ret);
                state.currentWritePosition += data.length;
                state.performReadWrite;
            });
        }

        return ret;
    }

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
        import sidero.eventloop.control : ensureItIsSetup;
        import sidero.eventloop.internal.filesystem.platform;

        if(!ensureItIsSetup)
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

        auto err = openFile(ret);
        if(!err)
            return typeof(return)(err.getError);

        return typeof(return)(ret);
    }
}
