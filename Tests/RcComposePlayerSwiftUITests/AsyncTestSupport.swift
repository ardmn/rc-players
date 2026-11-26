import Foundation
import Testing

/// Returns once `condition` holds, yielding the main actor to the tasks it waits on; fails the test
/// after `seconds` rather than hanging. Tests wait on observable state this way (a waiter count, a
/// recorded call), never on a number of turns or a sleep.
@MainActor
func waitUntil(
  _ what: @autoclosure () -> String, within seconds: TimeInterval = 30, _ condition: () -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(seconds)
  while !condition() {
    try #require(Date() < deadline, "timed out waiting until \(what())")
    await Task.yield()
  }
}
