import Foundation
import Testing

@testable import RcComposePlayerSwiftUI
@_spi(RemoteComposeController) @testable import RcNativePlayerUIKit

/// `deliverNamedUpdate` loops until the player answers finally, and the loop must never spin: a
/// deferred write is offered once per signal, plus once for a signal that arrived during the offer,
/// and the loop ends on a final answer, cancellation, a gone player or a closed availability. Each
/// test counts the offers exactly. The target stops deferring after `cap` offers, so a loop that
/// spins fails the count instead of hanging the run. No test sleeps: each lets the main actor run a
/// bounded number of turns.
@MainActor
@Suite struct NativeDeliveryLoopTests {
  /// Turns given to the delivery task to reach a state; far more than one offer and wait need.
  private static let turns = 1_000
  /// Turns after which a suspended delivery must still not have offered again.
  private static let idleTurns = 200

  /// Lets the main actor run until `condition` holds; false after `turns` turns.
  private static func run(turns: Int = turns, until condition: () -> Bool) async -> Bool {
    for _ in 0..<turns {
      if condition() { return true }
      await Task.yield()
    }
    return condition()
  }

  /// Lets the main actor run `idleTurns` turns, so a spinning loop would offer again.
  private static func idle() async {
    for _ in 0..<idleTurns { await Task.yield() }
  }

  private static func deliver(
    _ value: ControllerNamedValue?, to holder: Holder, isCurrent: @escaping () -> Bool = { true }
  ) -> Task<RemoteComposeNativeInputAdmission?, Never> {
    Task { @MainActor in
      await deliverNamedUpdate(
        value, for: "USER:count", to: { holder.target }, isCurrent: isCurrent)
    }
  }

  /// 1. Without a signal a deferred write is offered exactly once, and the task stays suspended.
  @Test(arguments: [ControllerNamedValue.integer(5), nil])
  func aDeferredWriteIsOfferedOnceWithoutASignal(_ value: ControllerNamedValue?) async {
    let target = CountingTarget(answers: { _ in .deferred })
    let holder = Holder(target)
    let delivery = Self.deliver(value, to: holder)
    #expect(await Self.run { target.availability.waiterCount == 1 }, "the delivery waits")
    await Self.idle()
    #expect(target.submits == 1)
    #expect(target.availability.waiterCount == 1, "still suspended, not spinning")
    delivery.cancel()
    #expect(await delivery.value == nil)
    #expect(target.submits == 1)
  }

  /// 2. N signals give exactly N + 1 offers; the loop returns on `.accepted`.
  @Test(arguments: [ControllerNamedValue.integer(5), nil])
  func eachSignalGivesExactlyOneMoreOffer(_ value: ControllerNamedValue?) async {
    let signals = 5
    let target = CountingTarget(answers: { $0 <= signals ? .deferred : .accepted })
    let holder = Holder(target)
    let delivery = Self.deliver(value, to: holder)
    for offered in 1...signals {
      #expect(await Self.run { target.availability.waiterCount == 1 }, "waits after \(offered)")
      await Self.idle()
      #expect(target.submits == offered)
      target.availability.signal()
    }
    #expect(await delivery.value == .accepted)
    #expect(target.submits == signals + 1)
    #expect(target.availability.waiterCount == 0)
  }

  /// 3. A signal sent while the offer is in flight — after the loop read its mark, before it waits
  /// — is not lost: the write is offered again at once, and then the loop waits.
  @Test func aSignalDuringTheOfferGivesOneImmediateReOffer() async {
    let target = CountingTarget(answers: { _ in .deferred })
    target.onSubmit = { if $0 == 1 { target.availability.signal() } }
    let holder = Holder(target)
    let delivery = Self.deliver(.integer(5), to: holder)
    #expect(await Self.run { target.availability.waiterCount == 1 }, "the delivery waits")
    await Self.idle()
    #expect(target.submits == 2, "one re-offer for the in-flight signal, no more")
    delivery.cancel()
    #expect(await delivery.value == nil)
    #expect(target.submits == 2)
  }

  /// 4. A cancelled delivery returns nil with no further offer: before it starts, while it waits,
  /// and while its offer is in flight.
  @Test func aCancelledDeliveryReturnsNilWithoutAnotherOffer() async {
    let early = CountingTarget(answers: { _ in .deferred })
    let earlyHolder = Holder(early)
    // The task is cancelled before it runs its first job.
    let beforeStart = Task { @MainActor in
      await deliverNamedUpdate(
        .integer(5), for: "USER:count", to: { earlyHolder.target }, isCurrent: { true })
    }
    beforeStart.cancel()
    #expect(await beforeStart.value == nil)
    #expect(early.submits == 0)

    let waiting = CountingTarget(answers: { _ in .deferred })
    let delivery = Self.deliver(.integer(5), to: Holder(waiting))
    #expect(await Self.run { waiting.availability.waiterCount == 1 }, "the delivery waits")
    delivery.cancel()
    #expect(await delivery.value == nil)
    await Self.idle()
    #expect(waiting.submits == 1)
    #expect(waiting.availability.waiterCount == 0)

    let inFlight = CountingTarget(answers: { _ in .deferred })
    let box = TaskBox()
    inFlight.onSubmit = { _ in box.task?.cancel() }
    box.task = Self.deliver(.integer(5), to: Holder(inFlight))
    #expect(await box.task?.value == nil)
    #expect(inFlight.submits == 1)
    #expect(inFlight.availability.waiterCount == 0)
  }

  /// 5a. The player's deinit drops the target and closes its availability: the waiting delivery
  /// returns nil after its one offer.
  @Test func aDeliveryEndsOnceThePlayerIsGone() async {
    let target = CountingTarget(answers: { _ in .deferred })
    let availability = target.availability
    let holder = Holder(target)
    let delivery = Self.deliver(.integer(5), to: holder)
    #expect(await Self.run { availability.waiterCount == 1 }, "the delivery waits")
    holder.target = nil
    availability.close()
    #expect(await delivery.value == nil)
    #expect(target.submits == 1)
  }

  /// 5b. A closed availability means its player is gone. Should a target still hand it out and
  /// defer, the delivery returns rather than offering again in a hot loop: a closed availability
  /// returns from every wait at once. Closed while the delivery waits, it ends after its one offer;
  /// closed before it starts, it never offers.
  @Test func aClosedAvailabilityEndsTheDeliveryEvenWhileTheTargetDefers() async {
    let target = CountingTarget(answers: { _ in .deferred })
    let delivery = Self.deliver(.integer(5), to: Holder(target))
    #expect(await Self.run { target.availability.waiterCount == 1 }, "the delivery waits")
    target.availability.close()
    #expect(await delivery.value == nil)
    #expect(target.submits == 1, "no offer after close")

    let closed = CountingTarget(answers: { _ in .deferred })
    closed.availability.close()
    #expect(await Self.deliver(.integer(5), to: Holder(closed)).value == nil)
    #expect(closed.submits == 0)
  }

  /// 6. A refusal returns at once: one offer, and no wait.
  @Test func aRefusalReturnsAtOnce() async {
    let target = CountingTarget(answers: { _ in .refused })
    #expect(await Self.deliver(.integer(5), to: Holder(target)).value == .refused)
    #expect(target.submits == 1)
    #expect(target.availability.waiterCount == 0)
  }
}

/// The delivery's view of the player: `target` is nil once the player is gone.
@MainActor
private final class Holder {
  var target: CountingTarget?
  init(_ target: CountingTarget) { self.target = target }
}

@MainActor
private final class TaskBox {
  var task: Task<RemoteComposeNativeInputAdmission?, Never>?
}

/// A native player that counts every offer — write or clear — and answers each by its 1-based
/// number. After `cap` offers it refuses, so a spinning loop ends with a count the tests reject.
@MainActor
private final class CountingTarget: NativeNamedValueTarget {
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
