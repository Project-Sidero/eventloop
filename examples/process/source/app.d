import sidero.eventloop.processes.defs;
import sidero.eventloop.threads;
import sidero.base.text;
import sidero.base.containers.readonlyslice;
import sidero.base.datetime;
import sidero.base.console;

void main() {
    auto process = Process.execute(String_UTF8("torun"), Slice!String_UTF8([String_UTF8("test\"aaa")]));
    assert(process);

    auto result = process.result;
    assert(!result.isNull);

    while(!result.isComplete) {
        cast(void)Thread.sleep(1.second);
    }

    assert(result.isComplete);
    auto resultCode = result.result;
    assert(resultCode);

    writeln(resultCode);
}
