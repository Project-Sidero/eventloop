import std.stdio;

int main(string[] args) {
    int ret;

    foreach(arg; args[1 .. $]) {
        ret += arg.length;
    }

    string name = readln;
    writeln(name);
    return ret;
}
