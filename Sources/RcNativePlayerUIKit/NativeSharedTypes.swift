import Foundation

/// The host surface behind an opaque or transparent player. It has no UIKit dependency so AppKit
/// hosts and shared adapters can use the same public configuration vocabulary.
public enum RemoteComposeNativePlayerBackground: Equatable, Sendable {
  case opaque
  case transparent
}

/// A value a host sets on a document's named variable before it renders: the four kinds a `.rc`
/// document declares a `USER:` name with. A boolean travels as `.integer` 0 or 1, as on the wire.
public enum RemoteComposeNativeNamedValue: Equatable, Sendable {
  case text(String)
  case float(Float)
  case integer(Int)
  /// ARGB, as the document stores a color.
  case color(UInt32)
}

/// How a native player answered a named-variable write.
@_spi(RemoteComposeController)
public enum RemoteComposeNativeInputAdmission: Equatable, Sendable {
  /// The document applied it.
  case accepted
  /// This session's final answer: the document is failed and has no session, the document
  /// declines the name or value (nothing is reported), or applying it failed (reported through
  /// `onError`). Offering it again to the same session gets the same answer; a later session —
  /// see `onSessionReopened` — judges it afresh.
  case refused
  /// The player could not take it yet — its document is still opening, its scene is in the
  /// background, its input queue is full, or the session it reached was discarded for a reopen. It
  /// may be accepted once ``RemoteComposeNativeInputAvailability`` signals.
  case deferred
}

/// Tells a caller holding a deferred write when to offer it again: the player signals each time it
/// may take input it could not before — its scene became active, its queue gave up an input, or a
/// session opened or failed — and opens for good when it goes away, so no waiter outlives it.
///
/// Thread-safe, and holds no reference to the player, so a waiter does not keep it alive.
@_spi(RemoteComposeController)
public final class RemoteComposeNativeInputAvailability: @unchecked Sendable {
  private let lock = NSLock()
  private var epoch: UInt64 = 0
  private var isClosed = false
  private var nextWaiter: UInt64 = 0
  private var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]

  public init() {}

  /// The point to wait from. Read it before offering a write, so a signal that arrives while the
  /// write is being answered is not missed.
  public var mark: UInt64 { locked { epoch } }

  /// Returns once the player has signalled since `mark`, has gone away, or the task is cancelled.
  public func wait(after mark: UInt64) async {
    let id = locked { () -> UInt64 in
      nextWaiter &+= 1
      return nextWaiter
    }
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let resumeNow = locked { () -> Bool in
          if epoch != mark || isClosed || Task.isCancelled { return true }
          waiters[id] = continuation
          return false
        }
        if resumeNow { continuation.resume() }
      }
    } onCancel: {
      locked { waiters.removeValue(forKey: id) }?.resume()
    }
  }

  /// Releases every waiter: input may be accepted now that was not before.
  func signal() {
    for waiter in locked({ () -> [CheckedContinuation<Void, Never>] in
      epoch &+= 1
      defer { waiters.removeAll() }
      return Array(waiters.values)
    }) {
      waiter.resume()
    }
  }

  /// Releases every waiter, present and future: the player is gone.
  func close() {
    locked { isClosed = true }
    signal()
  }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }
}
