import Testing
@testable import MeetingCore

/// `withTimeout`: a regression that waits for the timer (or for an operation that ignores
/// cancellation) hangs until the suite's time limit instead of passing.
@Suite(.timeLimit(.minutes(1)))
struct TimeoutTests {
    @Test func earlyFinishReturnsTheResultWithoutWaitingForTheTimer() async {
        // An hour-long timer: the task group only returns once its timer child has ended, so
        // returning at all proves the timer was cancelled rather than left running.
        let result = await withTimeout(.seconds(3600)) { 42 }
        #expect(result == 42)
    }

    @Test func operationFinishingLaterStillWins() async {
        let gate = Gate()
        let started = Gate()
        let opener = Task {
            await started.wait()
            gate.open()
        }
        let result = await withTimeout(.seconds(3600)) {
            started.open()
            await gate.wait()
            return "done"
        }
        #expect(result == "done")
        await opener.value
    }

    /// The operation ignores cancellation (a `Gate` nobody opens): the timeout is reported
    /// without waiting for it.
    @Test func neverFinishingOperationTimesOut() async {
        let never = Gate()
        let result = await withTimeout(.milliseconds(20)) {
            await never.wait()
            return 1
        }
        #expect(result == nil)
        never.open()                             // let the abandoned operation end
    }

    @Test func timeoutCancelsTheOperation() async {
        let cancelled = Gate(), never = Gate()
        let result: Int? = await withTimeout(.milliseconds(20)) {
            await withTaskCancellationHandler {
                await never.wait()               // ignores cancellation
                return 1
            } onCancel: {
                cancelled.open()
            }
        }
        #expect(result == nil)
        await cancelled.wait()                   // hangs if the operation was not cancelled
        never.open()
    }

    @Test func parentCancellationReturnsAtOnceAndCancelsTheOperation() async {
        let cancelled = Gate(), started = Gate(), never = Gate()
        let parent = Task {
            await withTimeout(.seconds(3600)) {
                await withTaskCancellationHandler {
                    started.open()
                    await never.wait()
                    return 1
                } onCancel: {
                    cancelled.open()
                }
            }
        }
        await started.wait()
        parent.cancel()
        #expect(await parent.value == nil)       // neither the hour nor the operation awaited
        await cancelled.wait()
        never.open()
    }

    @Test func alreadyCancelledParentReportsNoResult() async {
        let never = Gate()
        let parent = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await withTimeout(.seconds(3600)) { () async -> Int in
                await never.wait()
                return 1
            }
        }
        #expect(await parent.value == nil)
        never.open()
    }
}
