import Foundation
import Testing

/// Returns once `condition` holds, yielding the main actor to the tasks it waits on; fails the test
/// after `seconds` rather than hanging, and stops when the test is cancelled (a `.timeLimit`).
/// Tests wait on observable state this way (a waiter count, a recorded call), never on a number of
/// turns or a fixed sleep. After a few immediate yields, polling backs off by a millisecond so a
/// waiting test does not starve other `@MainActor` work under simulator load. The deadline is on
/// the monotonic uptime clock, so a wall-clock change cannot end it early. A timeout is reported at
/// the caller's `sourceLocation`.
@MainActor
func waitUntil(
  _ what: @autoclosure () -> String, within seconds: TimeInterval = 30,
  sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool
) async throws {
  let deadline = ProcessInfo.processInfo.systemUptime + seconds
  var spins = 0
  while !condition() {
    try Task.checkCancellation()
    try #require(
      ProcessInfo.processInfo.systemUptime < deadline, "timed out waiting until \(what())",
      sourceLocation: sourceLocation)
    if spins < 4 {
      spins += 1
      await Task.yield()
    } else {
      try await Task.sleep(nanoseconds: 1_000_000)
    }
  }
}
