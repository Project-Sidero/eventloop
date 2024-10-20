import sidero.eventloop.control;
import sidero.eventloop.filesystem;
import sidero.eventloop.coroutine;
import sidero.base.allocators;
import sidero.base.internal.atomic;
import sidero.base.path.file;
import sidero.base.text;
import sidero.base.console;
import sidero.base.containers.readonlyslice;

version = UseAsync;

int main() {
    auto filePath = FilePath.from("sometestfile.txt");
    if(!filePath) {
        writeln("Could not describe file given text");
        return 1;
    }

    if(exists(filePath)) {
        auto error = remove(filePath);

        if(!error) {
            writeln("Failed to remove the test file ", filePath, " due to ", error);
            return 2;
        }
    }

    auto theFile = File.from(filePath, true, true, true  /*FileRights(read: true, write: true, create: true)*/ );
    if(!theFile) {
        writeln("Failed to acquire file ", theFile);
        return 3;
    } else {
        writeln("Opened ", theFile.path, " with rights ", theFile.rights);
    }

    {
        version(UseAsync) {
            registerAsTask(createCo().makeInstance(globalAllocator(), theFile));
        } else {
            handleSyncFile(theFile);
        }

        acceptLoop;
    }

    {
        Future!StringBuilder_UTF8 fileText = readAllUTF8(filePath);
        fileText.blockUntilCompleteOrHaveValue();

        auto result = fileText.result;
        if (!result) {
            writeln("Failed to read file using utility function ", result);
            return 4;
        }

        writeln("\\/\\/ File contents \\/\\/");
        writeln(result.get);
        writeln("/\\/\\ File contents /\\/\\");

        acceptLoop;
    }

    shutdownWorkerThreads;
    shutdownNetworking;
    return 0;
}

shared(bool) allowedToShutdown, haveACo;

void acceptLoop() {
    import sidero.base.datetime;
    import sidero.eventloop.threads;

    if(!atomicLoad(haveACo))
        return;

    atomicStore(allowedToShutdown, false);

    writeln("Hit enter to stop:");
    bool wantClose;

    for(;;) {
        auto got = readLine(2.seconds);
        if(got && got.length > 0)
            wantClose = true;

        if((atomicLoad(allowedToShutdown) || !atomicLoad(haveACo)) && wantClose)
            break;

        //cast(void)Thread.sleep(1.seconds);
    }

    atomicStore(haveACo, false);
}

@safe nothrow @nogc:

InstanceableCoroutine!(void, File) createCo() {
    static struct State {
        File file;
        Future!(Slice!ubyte) nextLine;
        int readLineNumber;

    @safe nothrow @nogc:

        this(File file) {
            this.file = file;
            atomicStore(haveACo, true);
        }

        ~this() {
            if(file.isNull)
                return;

            writeln("File handler CO has ended");
            atomicStore(allowedToShutdown, true);
        }
    }

    enum Stages {
        OnStart,
        StartRead,
        OnLine,
    }

    alias Builder = CoroutineBuilder!(State, Stages, void, File);
    Builder builder;

    builder[Stages.OnStart] = (scope ref state) @trusted {
        writeln("File handler CO has started");

        // this should be written immediately, but you cannot assume it
        GenericCoroutine theWrite = state.file.write(Slice!ubyte(
                x"4869207468657265210D0A576861747320796F7572206E616D653F0D0A476F6F64206279652120576F6D7020776F6D702E"));

        // workaround for: https://issues.dlang.org/show_bug.cgi?id=23835
        auto ret = Builder.nextStage(Stages.StartRead).after(theWrite);
        return ret;
    };

    builder[Stages.StartRead] = (scope ref state) @trusted {
        auto tempSlice = Slice!ubyte(cast(ubyte[])"\n");
        state.nextLine = state.file.readUntil(tempSlice, true);
        assert(!state.nextLine.isNull);

        // workaround for: https://issues.dlang.org/show_bug.cgi?id=23835
        auto ret = Builder.nextStage(Stages.OnLine).after(state.nextLine);
        return ret;
    };

    builder[Stages.OnLine] = (scope ref state) @trusted {
        assert(state.nextLine.isComplete);
        auto result = state.nextLine.result;

        if(!result) {
            if(state.file.isReadEOF()) {
                writeln("Failed to complete read possibly EOF: ", result);
            } else {
                writeln("Did not get a result: ", result);
            }

            return Builder.complete(result.getError());
        }

        state.readLineNumber++;

        {
            String_UTF8 text = String_UTF8(cast(string)result.unsafeGetLiteral());
            if(text.endsWith("\r\n"))
                text = text[0 .. $ - 2];
            else if(text.endsWith("\n"))
                text = text[0 .. $ - 1];

            writeln("READ ", text.length, ":\t", text);
        }

        if(state.readLineNumber == 3)
            return Builder.complete(); // ok thats everything
        else {
            auto tempSlice = Slice!ubyte(cast(ubyte[])"\n");
            state.nextLine = state.file.readUntil(tempSlice, true);
            assert(!state.nextLine.isNull);

            // workaround for: https://issues.dlang.org/show_bug.cgi?id=23835
            auto ret = Builder.nextStage(Stages.OnLine).after(state.nextLine);
            return ret;
        }
    };

    auto got = builder.build();
    assert(got);
    return got.get;
}

void handleSyncFile(File file) @trusted {
    scope(exit) {
        atomicStore(allowedToShutdown, true);
    }

    // this should be written immediately, but you cannot assume it
    GenericCoroutine theWrite = file.write(
            Slice!ubyte(x"4869207468657265210D0A576861747320796F7572206E616D653F0D0A476F6F64206279652120576F6D7020776F6D702E"));
    theWrite.blockUntilCompleteOrHaveValue;

    Future!(Slice!ubyte) nextLine;
    int readLineNumber;

    for(;;) {
        {
            auto tempSlice = Slice!ubyte(cast(ubyte[])"\n");
            nextLine = file.readUntil(tempSlice, true);
            assert(!nextLine.isNull);
        }

        nextLine.blockUntilCompleteOrHaveValue;
        auto result = nextLine.result;

        if(!result) {
            if(file.isReadEOF()) {
                writeln("Failed to complete read possibly EOF: ", result);
            } else {
                writeln("Did not get a result: ", result);
            }

            return;
        }

        readLineNumber++;

        {
            String_UTF8 text = String_UTF8(cast(string)result.unsafeGetLiteral());
            if(text.endsWith("\r\n"))
                text = text[0 .. $ - 2];
            else if(text.endsWith("\n"))
                text = text[0 .. $ - 1];

            writeln("READ ", text.length, ":\t", text);

            if(readLineNumber == 3)
                return; // ok thats everything
        }
    }
}
