import Foundation
import Testing

@testable import RcComposePlayerSwiftUI
@_spi(RemoteComposeController) @testable import RcNativePlayerUIKit

/// `deliverNamedUpdate` loops until the player answers finally, and the loop must never spin: a
/// deferred write is offered once per signal, plus once for a signal that arrived during the offer,
/// and the loop ends on a final answer, cancellation, a gone player, a closed availability or a
/// delivery that is no longer current. Each test counts the offers exactly.
///
/// The tests assert state, not timing. A delivery is parked when its availability has one waiter:
/// it is then suspended on a continuation that only `signal()`, `signalOne()`, `close()` or
/// cancellation resumes, so while it stays parked its offer count cannot move. No test sleeps or
/// counts turns; each waits for a state under a deadline. The target refuses after `cap` offers,
/// and a wait for a parked delivery fails as soon as it has offered more than expected, so a loop
/// that spins fails at once instead of hanging. The suite's time limit cancels a test that still
/// hangs; `finish` passes that cancellation on to the delivery it awaits. This follows Apple's
/// "Testing asynchronous code" (Swift Testing) and Point-Free's "Reliably testing async code":
/// wait for observable state, not for time. Point-Free's `withMainSerialExecutor` would make the
/// scheduling itself serial, but it needs a new dependency (swift-concurrency-extras) in an
/// upstream package, and the waiter count already gives a deterministic state to wait on.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct NativeDeliveryLoopTests {
  /// Waits until the delivery is parked after exactly `offers` offers; fails at once when it has
  /// offered more or has already returned, so a broken loop fails instead of timing out.
  private static func parked(_ holder: Holder, after offers: Int) async throws {
    let target = try #require(holder.target)
    try await waitUntil("parked after \(offers) offers, at \(target.submits)") {
      target.availability.waiterCount == 1 || target.submits > offers || holder.isFinished
    }
    try #require(!holder.isFinished, "the delivery returned instead of parking")
    try #require(target.availability.waiterCount == 1)
    try #require(target.submits == offers)
  }

  /// The delivery's answer. Cancelling the awaiting test (its time limit) cancels the delivery, so
  /// a delivery that never returns fails the test instead of hanging the run.
  private static func finish(
    _ delivery: Task<RemoteComposeNativeInputAdmission?, Never>
  ) async -> RemoteComposeNativeInputAdmission? {
    await withTaskCancellationHandler {
      await delivery.value
    } onCancel: {
      delivery.cancel()
    }
  }

  private static func deliver(
    _ value: ControllerNamedValue?, to holder: Holder, isCurrent: @escaping () -> Bool = { true }
  ) -> Task<RemoteComposeNativeInputAdmission?, Never> {
    Task { @MainActor in
      defer { holder.isFinished = true }
      return await deliverNamedUpdate(
        value, for: "USER:count", to: { holder.target }, isCurrent: isCurrent)
    }
  }

  /// 1. Without a signal a deferred write is offered exactly once and the delivery parks; a signal
  /// gives exactly one more offer and it parks again.
  @Test(arguments: [ControllerNamedValue.integer(5), nil])
  func aDeferredWriteIsOfferedOnceWithoutASignal(_ value: ControllerNamedValue?) async throws {
    let target = ScriptedTarget(answers: { _ in .deferred })
    let holder = Holder(target)
    let delivery = Self.deliver(value, to: holder)
    defer { delivery.cancel() }
    try await Self.parked(holder, after: 1)

    target.availability.signal()
    try await waitUntil("the signal wakes the delivery") { target.submits >= 2 }
    try await Self.parked(holder, after: 2)

    delivery.cancel()
    #expect(await Self.finish(delivery) == nil)
    #expect(target.submits == 2)
    #expect(target.availability.waiterCount == 0)
  }

  /// 2. N signals give exactly N + 1 offers; the loop returns on `.accepted`.
  @Test(arguments: [ControllerNamedValue.integer(5), nil])
  func eachSignalGivesExactlyOneMoreOffer(_ value: ControllerNamedValue?) async throws {
    let signals = 5
    let target = ScriptedTarget(answers: { $0 <= signals ? .deferred : .accepted })
    let holder = Holder(target)
    let delivery = Self.deliver(value, to: holder)
    defer { delivery.cancel() }
    for offered in 1...signals {
      try await Self.parked(holder, after: offered)
      target.availability.signal()
      try await waitUntil("signal \(offered) wakes the delivery") { target.submits >= offered + 1 }
    }
    #expect(await Self.finish(delivery) == .accepted)
    #expect(target.submits == signals + 1)
    #expect(target.availability.waiterCount == 0)
  }

  /// 3. A signal sent while the offer is in flight — after the loop read its mark, before it waits
  /// — is not lost: the write is offered again at once, and then the loop waits.
  @Test(arguments: [ControllerNamedValue.integer(5), nil])
  func aSignalDuringTheOfferGivesOneImmediateReOffer(_ value: ControllerNamedValue?) async throws {
    let target = ScriptedTarget(answers: { _ in .deferred })
    let availability = target.availability
    target.onSubmit = { if $0 == 1 { availability.signal() } }
    let holder = Holder(target)
    let delivery = Self.deliver(value, to: holder)
    defer { delivery.cancel() }
    // One re-offer for the in-flight signal, then parked: no more.
    try await Self.parked(holder, after: 2)
    delivery.cancel()
    #expect(await Self.finish(delivery) == nil)
    #expect(target.submits == 2)
  }

  /// 4. A cancelled delivery returns nil with no further offer: before it starts, while it waits,
  /// and while its offer is in flight.
  @Test(arguments: [ControllerNamedValue.integer(5), nil])
  func aCancelledDeliveryReturnsNilWithoutAnotherOffer(_ value: ControllerNamedValue?) async throws
  {
    let early = ScriptedTarget(answers: { _ in .deferred })
    // The task is cancelled before it runs its first job.
    let beforeStart = Self.deliver(value, to: Holder(early))
    beforeStart.cancel()
    #expect(await Self.finish(beforeStart) == nil)
    #expect(early.submits == 0)

    let waiting = ScriptedTarget(answers: { _ in .deferred })
    let holder = Holder(waiting)
    let delivery = Self.deliver(value, to: holder)
    defer { delivery.cancel() }
    try await Self.parked(holder, after: 1)
    delivery.cancel()
    #expect(await Self.finish(delivery) == nil)
    #expect(waiting.submits == 1)
    #expect(waiting.availability.waiterCount == 0)

    let inFlight = ScriptedTarget(answers: { _ in .deferred })
    // The offer runs in the delivery's task, so cancelling the current task cancels the delivery.
    inFlight.onSubmit = { _ in withUnsafeCurrentTask { $0?.cancel() } }
    #expect(await Self.finish(Self.deliver(value, to: Holder(inFlight))) == nil)
    #expect(inFlight.submits == 1)
    #expect(inFlight.availability.waiterCount == 0)
  }

  /// 5a. Once the player is gone (`target()` is nil), the waiting delivery wakes on the next signal
  /// and returns nil after its one offer. It is woken by a signal, not `close()`, so the gone
  /// target is what ends the loop; 5b covers the closed availability.
  @Test(arguments: [ControllerNamedValue.integer(5), nil])
  func aDeliveryEndsOnceThePlayerIsGone(_ value: ControllerNamedValue?) async throws {
    let target = ScriptedTarget(answers: { _ in .deferred })
    let availability = target.availability
    let holder = Holder(target)
    let delivery = Self.deliver(value, to: holder)
    defer { delivery.cancel() }
    try await Self.parked(holder, after: 1)
    holder.target = nil
    availability.signal()
    #expect(await Self.finish(delivery) == nil)
    #expect(target.submits == 1)
  }

  /// 5b. A closed availability means its player is gone. Should a target still hand it out and
  /// defer, the delivery returns rather than offering again in a hot loop: a closed availability
  /// returns from every wait at once. Closed while the delivery waits, it ends after its one offer;
  /// closed before it starts, it never offers.
  @Test(arguments: [ControllerNamedValue.integer(5), nil])
  func aClosedAvailabilityEndsTheDeliveryEvenWhileTheTargetDefers(_ value: ControllerNamedValue?)
    async throws
  {
    let target = ScriptedTarget(answers: { _ in .deferred })
    let holder = Holder(target)
    let delivery = Self.deliver(value, to: holder)
    defer { delivery.cancel() }
    try await Self.parked(holder, after: 1)
    target.availability.close()
    #expect(await Self.finish(delivery) == nil)
    #expect(target.submits == 1, "no offer after close")

    let closed = ScriptedTarget(answers: { _ in .deferred })
    closed.availability.close()
    #expect(await Self.finish(Self.deliver(value, to: Holder(closed))) == nil)
    #expect(closed.submits == 0)

    // Closed while the offer is in flight. The real player cannot do this (the delivery holds the
    // target, which owns the availability), so this case is defensive: no wait is left behind.
    let inFlight = ScriptedTarget(answers: { _ in .deferred })
    let inFlightAvailability = inFlight.availability
    inFlight.onSubmit = { _ in inFlightAvailability.close() }
    #expect(await Self.finish(Self.deliver(value, to: Holder(inFlight))) == nil)
    #expect(inFlight.submits == 1)
    #expect(inFlightAvailability.waiterCount == 0)
  }

  /// 5c. A delivery that is no longer current (a newer value for the name started, or the player
  /// was rebuilt) returns nil on its next wake without offering again.
  @Test(arguments: [ControllerNamedValue.integer(5), nil])
  func aDeliveryThatIsNoLongerCurrentStopsOffering(_ value: ControllerNamedValue?) async throws {
    let target = ScriptedTarget(answers: { _ in .deferred })
    let holder = Holder(target)
    let delivery = Self.deliver(value, to: holder, isCurrent: { target.submits == 0 })
    defer { delivery.cancel() }
    try await Self.parked(holder, after: 1)
    target.availability.signal()
    #expect(await Self.finish(delivery) == nil)
    #expect(target.submits == 1)
  }

  /// 6. A refusal returns at once: one offer, and no wait.
  @Test(arguments: [ControllerNamedValue.integer(5), nil])
  func aRefusalReturnsAtOnce(_ value: ControllerNamedValue?) async throws {
    let target = ScriptedTarget(answers: { _ in .refused })
    #expect(await Self.finish(Self.deliver(value, to: Holder(target))) == .refused)
    #expect(target.submits == 1)
    #expect(target.availability.waiterCount == 0)
  }
}

/// The delivery's view of the player: `target` is nil once the player is gone.
@MainActor
private final class Holder {
  var target: ScriptedTarget?
  /// Whether the delivery task has returned.
  var isFinished = false
  init(_ target: ScriptedTarget) { self.target = target }
}

/// A native player that counts every offer — write or clear — and answers each by its 1-based
/// number. After `cap` offers it refuses, so a spinning loop ends with a count the tests reject.
@MainActor
private final class ScriptedTarget: NativeNamedValueTarget {
  static let cap = 50
  private(set) var submits = 0
  var onSubmit: (Int) -> Void = { _ in }
  let availability = RemoteComposeNativeInputAvailability()
  private let answers: (Int) -> RemoteComposeNativeInputAdmission

  init(answers: @escaping (Int) -> RemoteComposeNativeInputAdmission) {
    self.answers = answers
  }

  var inputAvailability: RemoteComposeNativeInputAvailability { availability }

  func submit(_ value: RemoteComposeNativeNamedValue, for name: String) async
    -> RemoteComposeNativeInputAdmission
  {
    offer()
  }

  func submitClear(for name: String) async -> RemoteComposeNativeInputAdmission {
    offer()
  }

  private func offer() -> RemoteComposeNativeInputAdmission {
    submits += 1
    onSubmit(submits)
    return submits > Self.cap ? .refused : answers(submits)
  }
}
