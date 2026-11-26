import Foundation
import Testing

/// Returns once `condition` holds, yielding the main actor to the tasks it waits on; fails the test
/// after `seconds` rather than hanging, and stops when the test is cancelled (a `.timeLimit`).
/// Tests wait on observable state this way (a waiter count, a recorded call), never on a number of
/// turns or a sleep. The deadline is on the monotonic uptime clock, so a wall-clock change cannot
/// end it early.
@MainActor
func waitUntil(
  _ what: @autoclosure () -> String, within seconds: TimeInterval = 30, _ condition: () -> Bool
) async throws {
  let deadline = ProcessInfo.processInfo.systemUptime + seconds
  while !condition() {
    try Task.checkCancellation()
    try #require(
      ProcessInfo.processInfo.systemUptime < deadline, "timed out waiting until \(what())")
    await Task.yield()
  }
}
