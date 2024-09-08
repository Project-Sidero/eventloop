module app;
import sidero.base.console;
import sidero.base.text.format;
import sidero.base.internal.all_generated;

@safe nothrow @nogc:

void main() {
    writeln(add(3, 4));
    writeln(formattedWrite("{:10d}", add(3, 7)));
}

int add(int x, int y) {
    return x + y;
}
