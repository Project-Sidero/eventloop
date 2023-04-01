module sidero.eventloop.rtinfoimplstub;

version (DigitalMars) version = NeedStubs;

version (NeedStubs) {
    static foreach (Stub; [
        "_D6object__T10RTInfoImplVAmA2i96i1063ZQBayG2m",
        "_D6object__T10RTInfoImplVAmA2i136i87079ZQBcyG2m",
        "_D6object__T10RTInfoImplVAmA2i208i3560789ZQBeyG2m",
        "_D6object__T10RTInfoImplVAmA2i56i66ZQyyG2m",
        "_D6object__T10RTInfoImplVAmA2i264i6098517954ZQBhyG2m",
        "_D6object__T10RTInfoImplVAmA2i168i349524ZQBdyG2m",
        "_D6object__T10RTInfoImplVAmA2i152i305834ZQBdyG2m",
    ]) {
        mixin(() { return "extern(C) void " ~ Stub ~ "() { asm { naked; dl 0; dl 0;}\n}\n"; }());
    }
}
