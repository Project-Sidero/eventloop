module sidero.eventloop.tasks.future_completion;
import sidero.eventloop.coroutine.future;
import sidero.eventloop.coroutine.generic;
import sidero.eventloop.coroutine.instanceable;
import sidero.eventloop.coroutine.condition;
import sidero.base.errors;
import sidero.base.allocators;

export @safe nothrow @nogc:

struct FutureTrigger;

/// The storage for a future trigger, matches internals of a coroutine return value.
alias FutureTriggerStorage(ResultType) = Result!ResultType;

InstanceableCoroutine!(ResultType, FutureTriggerStorage!ResultType**) acquireInstantiableFuture(ResultType)() @trusted {
    __gshared typeof(return) storage = () {
        import sidero.eventloop.coroutine.internal.state : ctfeConstructExternalTriggerState;

        auto pair = ctfeConstructExternalTriggerState!ResultType;

        InstanceableCoroutine!(ResultType, FutureTriggerStorage!ResultType**) ret;
        ret.pair = pair;
        return ret;
    }();

    return storage;
}

ErrorResult waitOnTrigger(ResultType, TriggerStorage = FutureTriggerStorage!ResultType*)(Future!ResultType coroutine,
        TriggerStorage triggerStorage) @trusted {
    if(triggerStorage is null)
        return ErrorResult(NullPointerException("Trigger argument is null"));

    return waitOnTrigger(coroutine.asGeneric(), cast(FutureTrigger*)triggerStorage);
}

ErrorResult waitOnTrigger(GenericCoroutine coroutine, FutureTrigger* trigger) @trusted {
    if(trigger is null)
        return ErrorResult(NullPointerException("Trigger argument is null"));
    else if(coroutine.isNull)
        return ErrorResult(NullPointerException("Coroutine argument is null"));

    checkInit;

    // does not need locking at this level, already handled by the map

    if(triggerableCoroutines.insert(trigger, coroutine))
        return ErrorResult.init;

    return ErrorResult(DuplicateValueException("Future trigger has already been registered"));
}

ErrorResult trigger(ResultType, TriggerStorage = FutureTriggerStorage!ResultType*)(scope TriggerStorage triggerStorage,
        scope return ErrorMessage errorMessage, string moduleName = __MODULE__, int line = __LINE__) @trusted {
    if(triggerStorage is null)
        return ErrorResult(NullPointerException("Trigger argument is null"));

    *triggerStorage = Result!ResultType(result, moduleName, line);
    return trigger(cast(FutureTrigger*)triggerStorage);
}

ErrorResult trigger(ResultType, TriggerStorage = FutureTriggerStorage!ResultType*)(scope TriggerStorage triggerStorage,
        scope return ResultType result) @trusted {
    if(triggerStorage is null)
        return ErrorResult(NullPointerException("Trigger argument is null"));

    *triggerStorage = result;
    return trigger(cast(FutureTrigger*)triggerStorage);
}

ErrorResult trigger(ResultType, TriggerStorage = FutureTriggerStorage!ResultType*)(scope TriggerStorage triggerStorage,
        scope return Result!ResultType result) @trusted {
    if(triggerStorage is null)
        return ErrorResult(NullPointerException("Trigger argument is null"));

    *triggerStorage = result;
    return trigger(cast(FutureTrigger*)triggerStorage);
}

ErrorResult trigger(scope FutureTrigger* trigger) @trusted {
    import sidero.eventloop.internal.workers : addCoroutineTask;

    if(trigger is null)
        return ErrorResult(NullPointerException("Trigger argument is null"));

    // We only need to lock at this level to prevent multiple threads trying to trigger the same coroutine simultaneously
    //  and hitting a mixed state.

    mutex.pureLock;
    GenericCoroutine coroutine;

    {
        auto got = triggerableCoroutines[trigger];
        if(!got) {
            mutex.unlock;
            return ErrorResult(got.getError());
        }

        coroutine = got.get;
    }

    triggerableCoroutines.remove(trigger);
    mutex.unlock;

    ErrorResult errorResult = coroutine.unsafeResume();
    if(!errorResult)
        return errorResult;

    addCoroutineTask(coroutine);
    return ErrorResult.init;
}

unittest {
    InstanceableCoroutine!(int, FutureTriggerStorage!int**) instantiable = acquireInstantiableFuture!int();

    FutureTriggerStorage!int* triggerStorage;

    Future!int future = instantiable.makeInstance(RCAllocator.init, &triggerStorage).asFuture;
    assert(!future.isNull);
    assert(!future.isComplete);
    assert(triggerStorage !is null);
    assert(future.condition.waitingOn == CoroutineCondition.WaitingOn.ExternalTrigger);

    auto errorResult = waitOnTrigger(future, triggerStorage);
    assert(errorResult);

    errorResult = trigger(triggerStorage, 3);
    assert(errorResult);
    assert(future.isComplete());

    auto got = future.result();
    assert(got);
    assert(got == 3);
}

private:
import sidero.base.containers.map.concurrenthashmap;
import sidero.base.synchronization.mutualexclusion;

void checkInit() @trusted {
    mutex.pureLock;

    if(triggerableCoroutines.isNull)
        triggerableCoroutines = ConcurrentHashMap!(FutureTrigger*, GenericCoroutine)();

    mutex.unlock;
}

__gshared {
    TestTestSetLockInline mutex;
    ConcurrentHashMap!(FutureTrigger*, GenericCoroutine) triggerableCoroutines;
}
