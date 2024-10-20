import sidero.eventloop.processes;
import sidero.eventloop.threads;
import sidero.base.text;
import sidero.base.containers.readonlyslice;
import sidero.base.containers.map.hashmap;
import sidero.base.datetime;
import sidero.base.console;
import sidero.base.system;

void main() {
    auto process = Process.execute(String_UTF8("torun"), Slice!String_UTF8([String_UTF8("test\"aaa")]),
            String_UTF8.init, HashMap!(String_UTF8, String_UTF8).init, false);
    assert(process);

    auto result = process.result;
    assert(!result.isNull);

    auto pstdout = process.outputPipe;
    assert(!pstdout.isNull);
    auto textToRead = pstdout.readUntil(String_ASCII("\n"));
    assert(!textToRead.isNull);

    String_UTF8 un = userName();
    process.inputPipe.write(Slice!ubyte(cast(ubyte[])un.unsafeGetLiteral));
    process.inputPipe.write(String_ASCII("!\n"));

    while(!result.isComplete || !textToRead.isComplete) {
        cast(void)Thread.sleep(10.microSecond);
    }

    assert(result.isComplete);
    assert(textToRead.isComplete);

    auto resultCode = result.result;
    auto resultText = textToRead.result;
    assert(resultCode);
    assert(resultText);

    writeln("Hello ", String_UTF8(cast(string)resultText.unsafeGetLiteral).strip, " ", resultCode);

    import sidero.eventloop.control;
    shutdownWorkerThreads;
    shutdownNetworking;
}
