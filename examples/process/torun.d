int main(string[] args) {
    int ret;

    foreach(arg; args[1 .. $]) {
        ret += arg.length;
    }

    return ret;
}
