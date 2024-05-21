module sidero.eventloop.internal.event_waiting.linux;
import sidero.eventloop.internal.event_waiting;

export @safe nothrow @nogc:

void initializeLinuxEventWaiting() {
}

void addEventWaiterHandleStrategy(void* handleToWaitOn, UserEventProc proc, void* user) {
}

void removeEventWaiterHandleStrategy(scope void* handleToNotWaitOn) {
}

void shutdownEventWaiterThreadsStrategy() {
}
