module sidero.eventloop.filesystem.utils;
import sidero.eventloop.filesystem;
import sidero.eventloop.coroutine;
import sidero.eventloop.coroutine.future_completion;
import sidero.eventloop.control;
import sidero.base.containers.dynamicarray;
import sidero.base.containers.appender;
import sidero.base.containers.readonlyslice;
import sidero.base.text;
import sidero.base.allocators;

export @safe nothrow @nogc:

///
Future!(DynamicArray!ubyte) readAll(FilePath fileName) @trusted {
    static struct State {
        File file;
        Appender!ubyte buffer;
        Future!(Slice!ubyte) nextChunk;

    @safe nothrow @nogc:

        this(File file) {
            this.file = file;
        }

        ~this() {
        }
    }

    enum Stages {
        OnStart,
        NextChunk,
    }

    alias Builder = CoroutineBuilder!(State, Stages, DynamicArray!ubyte, File);
    Builder builder;

    builder[Stages.OnStart] = (scope ref state) @trusted {
        state.nextChunk = state.file.readChunk();
        assert(!state.nextChunk.isNull);

        // workaround for: https://issues.dlang.org/show_bug.cgi?id=23835
        auto ret = Builder.nextStage(Stages.NextChunk).after(state.nextChunk);
        return ret;
    };

    builder[Stages.NextChunk] = (scope ref state) @trusted {
        auto result = state.nextChunk.result;

        if(!result) {
            if(state.file.isReadEOF())
                return Builder.complete(state.buffer.asMutable);

            return Builder.complete(result.getError());
        }

        state.buffer ~= result;

        {
            state.nextChunk = state.file.readChunk();
            assert(!state.nextChunk.isNull);

            // workaround for: https://issues.dlang.org/show_bug.cgi?id=23835
            auto ret = Builder.nextStage(Stages.NextChunk).after(state.nextChunk);
            return ret;
        }
    };

    auto theFile = File.from(fileName, true);
    if(!theFile) {
        InstanceableCoroutine!(DynamicArray!ubyte, FutureTriggerStorage!(DynamicArray!ubyte)**) instantiable = acquireInstantiableFuture!(
                DynamicArray!ubyte)();
        FutureTriggerStorage!(DynamicArray!ubyte)* triggerStorage;
        Future!(DynamicArray!ubyte) future = instantiable.makeInstance(RCAllocator.init, &triggerStorage);

        auto errorResult = completeWithoutATrigger(future, triggerStorage, theFile.getError().info);
        assert(errorResult);

        return future;
    }

    auto got = builder.build();
    assert(got);

    auto ret = got.makeInstance(RCAllocator.init, theFile);
    registerAsTask(ret);
    return ret;
}

///
Future!StringBuilder_UTF8 readAllUTF8(FilePath fileName) @trusted {
    static struct State {
        File file;
        StringBuilder_UTF8 buffer;
        Future!(Slice!ubyte) nextChunk;

    @safe nothrow @nogc:

        this(File file) {
            this.file = file;
        }

        ~this() {
        }
    }

    enum Stages {
        OnStart,
        NextChunk,
    }

    alias Builder = CoroutineBuilder!(State, Stages, StringBuilder_UTF8, File);
    Builder builder;

    builder[Stages.OnStart] = (scope ref state) @trusted {
        state.nextChunk = state.file.readChunk();
        assert(!state.nextChunk.isNull);

        // workaround for: https://issues.dlang.org/show_bug.cgi?id=23835
        auto ret = Builder.nextStage(Stages.NextChunk).after(state.nextChunk);
        return ret;
    };

    builder[Stages.NextChunk] = (scope ref state) @trusted {
        auto result = state.nextChunk.result;

        if(!result) {
            if(state.file.isReadEOF())
                return Builder.complete(state.buffer);

            return Builder.complete(result.getError());
        }

        state.buffer ~= cast(const(char)[])result.unsafeGetLiteral();

        Next:

        {
            state.nextChunk = state.file.readChunk();
            assert(!state.nextChunk.isNull);

            // workaround for: https://issues.dlang.org/show_bug.cgi?id=23835
            auto ret = Builder.nextStage(Stages.NextChunk).after(state.nextChunk);
            return ret;
        }
    };

    auto theFile = File.from(fileName);
    if(!theFile) {
        InstanceableCoroutine!(StringBuilder_UTF8, FutureTriggerStorage!StringBuilder_UTF8**) instantiable = acquireInstantiableFuture!StringBuilder_UTF8();
        FutureTriggerStorage!StringBuilder_UTF8* triggerStorage;
        Future!StringBuilder_UTF8 future = instantiable.makeInstance(RCAllocator.init, &triggerStorage);

        auto errorResult = completeWithoutATrigger(future, triggerStorage, theFile.getError().info);
        assert(errorResult);

        return future;
    }

    auto got = builder.build();
    assert(got);

    auto ret = got.makeInstance(RCAllocator.init, theFile);
    registerAsTask(ret);
    return ret;
}

///
Future!StringBuilder_UTF16 readAllUTF16(FilePath fileName) @trusted {
    static struct State {
        File file;
        StringBuilder_UTF16 buffer;
        Future!(Slice!ubyte) nextChunk;

        @safe nothrow @nogc:

        this(File file) {
            this.file = file;
        }

        ~this() {
        }
    }

    enum Stages {
        OnStart,
        NextChunk,
    }

    alias Builder = CoroutineBuilder!(State, Stages, StringBuilder_UTF16, File);
    Builder builder;

    builder[Stages.OnStart] = (scope ref state) @trusted {
        state.nextChunk = state.file.readChunk();
        assert(!state.nextChunk.isNull);

        // workaround for: https://issues.dlang.org/show_bug.cgi?id=23835
        auto ret = Builder.nextStage(Stages.NextChunk).after(state.nextChunk);
        return ret;
    };

    builder[Stages.NextChunk] = (scope ref state) @trusted {
        auto result = state.nextChunk.result;

        if(!result) {
            if(state.file.isReadEOF())
            return Builder.complete(state.buffer);

            return Builder.complete(result.getError());
        }

        state.buffer ~= cast(const(wchar)[])result.unsafeGetLiteral();

        {
            state.nextChunk = state.file.readChunk();
            assert(!state.nextChunk.isNull);

            // workaround for: https://issues.dlang.org/show_bug.cgi?id=23835
            auto ret = Builder.nextStage(Stages.NextChunk).after(state.nextChunk);
            return ret;
        }
    };

    auto theFile = File.from(fileName, true);
    if(!theFile) {
        InstanceableCoroutine!(StringBuilder_UTF16, FutureTriggerStorage!StringBuilder_UTF16**) instantiable = acquireInstantiableFuture!StringBuilder_UTF16();
        FutureTriggerStorage!StringBuilder_UTF16* triggerStorage;
        Future!StringBuilder_UTF16 future = instantiable.makeInstance(RCAllocator.init, &triggerStorage);

        auto errorResult = completeWithoutATrigger(future, triggerStorage, theFile.getError().info);
        assert(errorResult);

        return future;
    }

    auto got = builder.build();
    assert(got);

    auto ret = got.makeInstance(RCAllocator.init, theFile);
    registerAsTask(ret);
    return ret;
}

///
Future!StringBuilder_UTF32 readAllUTF32(FilePath fileName) @trusted {
    static struct State {
        File file;
        StringBuilder_UTF32 buffer;
        Future!(Slice!ubyte) nextChunk;

        @safe nothrow @nogc:

        this(File file) {
            this.file = file;
        }

        ~this() {
        }
    }

    enum Stages {
        OnStart,
        NextChunk,
    }

    alias Builder = CoroutineBuilder!(State, Stages, StringBuilder_UTF32, File);
    Builder builder;

    builder[Stages.OnStart] = (scope ref state) @trusted {
        state.nextChunk = state.file.readChunk();
        assert(!state.nextChunk.isNull);

        // workaround for: https://issues.dlang.org/show_bug.cgi?id=23835
        auto ret = Builder.nextStage(Stages.NextChunk).after(state.nextChunk);
        return ret;
    };

    builder[Stages.NextChunk] = (scope ref state) @trusted {
        auto result = state.nextChunk.result;

        if(!result) {
            if(state.file.isReadEOF())
            return Builder.complete(state.buffer);

            return Builder.complete(result.getError());
        }

        state.buffer ~= cast(const(dchar)[])result.unsafeGetLiteral();

        {
            state.nextChunk = state.file.readChunk();
            assert(!state.nextChunk.isNull);

            // workaround for: https://issues.dlang.org/show_bug.cgi?id=23835
            auto ret = Builder.nextStage(Stages.NextChunk).after(state.nextChunk);
            return ret;
        }
    };

    auto theFile = File.from(fileName, true);
    if(!theFile) {
        InstanceableCoroutine!(StringBuilder_UTF32, FutureTriggerStorage!StringBuilder_UTF32**) instantiable = acquireInstantiableFuture!StringBuilder_UTF32();
        FutureTriggerStorage!StringBuilder_UTF32* triggerStorage;
        Future!StringBuilder_UTF32 future = instantiable.makeInstance(RCAllocator.init, &triggerStorage);

        auto errorResult = completeWithoutATrigger(future, triggerStorage, theFile.getError().info);
        assert(errorResult);

        return future;
    }

    auto got = builder.build();
    assert(got);

    auto ret = got.makeInstance(RCAllocator.init, theFile);
    registerAsTask(ret);
    return ret;
}

///
GenericCoroutine write(FilePath fileName, String_UTF8 data) {
    return write(fileName, data.asRawSlice);
}

///
GenericCoroutine write(FilePath fileName, String_UTF16 data) {
    return write(fileName, data.asRawSlice);
}

///
GenericCoroutine write(FilePath fileName, String_UTF32 data) {
    return write(fileName, data.asRawSlice);
}

///
GenericCoroutine write(FilePath fileName, DynamicArray!ubyte data) {
    return write(fileName, data.asReadOnly);
}

///
GenericCoroutine write(FilePath fileName, Slice!ubyte data) @trusted {
    const alreadyExists = fileName.exists;

    auto theFile = File.from(fileName, true, !alreadyExists);
    if(!theFile) {
        InstanceableCoroutine!(void, FutureTriggerStorage!void**) instantiable = acquireInstantiableFuture!(void)();
        FutureTriggerStorage!void* triggerStorage;
        Future!void future = instantiable.makeInstance(RCAllocator.init, &triggerStorage);

        auto errorResult = completeWithoutATrigger(future, triggerStorage, theFile.getError().info);
        assert(errorResult);

        return future.asGeneric();
    }

    return theFile.write(data);
}

///
GenericCoroutine append(FilePath fileName, String_UTF8 data) {
    return append(fileName, data.asRawSlice);
}

///
GenericCoroutine append(FilePath fileName, String_UTF16 data) {
    return append(fileName, data.asRawSlice);
}

///
GenericCoroutine append(FilePath fileName, String_UTF32 data) {
    return append(fileName, data.asRawSlice);
}

///
GenericCoroutine append(FilePath fileName, DynamicArray!ubyte data) {
    return append(fileName, data.asReadOnly);
}

///
GenericCoroutine append(FilePath fileName, Slice!ubyte data) @trusted {
    const alreadyExists = fileName.exists;

    auto theFile = File.from(fileName, false, true, !alreadyExists, true);
    if(!theFile) {
        InstanceableCoroutine!(void, FutureTriggerStorage!void**) instantiable = acquireInstantiableFuture!(void)();
        FutureTriggerStorage!void* triggerStorage;
        Future!void future = instantiable.makeInstance(RCAllocator.init, &triggerStorage);

        auto errorResult = completeWithoutATrigger(future, triggerStorage, theFile.getError().info);
        assert(errorResult);

        return future.asGeneric();
    }

    return theFile.write(data);
}
