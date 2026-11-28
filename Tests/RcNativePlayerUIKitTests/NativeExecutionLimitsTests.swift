import Foundation
import Testing

@testable import RcNativePlayerCore
@testable import RcNativePlayerUIKit

@Suite struct NativeExecutionLimitsTests {
  @Test func executionLimits() throws {
    try NativeFrameBudget.validate(.default)
    expect(.invalidLimits) {
      try NativeFrameBudget.validate(
        RemoteComposeNativeExecutionLimits(maximumNodeCount: 0))
    }

    var nodes = NativeFrameBudget()
    let oneNode = RemoteComposeNativeExecutionLimits(maximumNodeCount: 1)
    try nodes.recordNode(depth: 1, limits: oneNode)
    expect(.tooManyNodes(actual: 2, maximum: 1)) {
      try nodes.recordNode(depth: 1, limits: oneNode)
    }

    var nesting = NativeFrameBudget()
    expect(.nestingTooDeep(actual: 3, maximum: 2)) {
      try nesting.recordNode(
        depth: 3, limits: RemoteComposeNativeExecutionLimits(maximumNestingDepth: 2))
    }

    var commands = NativeFrameBudget()
    let commandLimit = RemoteComposeNativeExecutionLimits(
      maximumDrawCommandCount: 1, maximumPathElementCount: 1)
    try commands.recordCommand(pathElementCount: 1, strings: ["ok"], limits: commandLimit)
    expect(.tooManyDrawCommands(actual: 2, maximum: 1)) {
      try commands.recordCommand(pathElementCount: 0, limits: commandLimit)
    }

    var paths = NativeFrameBudget()
    expect(.tooManyPathElements(actual: 2, maximum: 1)) {
      try paths.recordCommand(
        pathElementCount: 2,
        limits: RemoteComposeNativeExecutionLimits(maximumPathElementCount: 1))
    }

    var text = NativeFrameBudget()
    expect(.textTooLong(actual: 4, maximum: 3)) {
      try text.recordCommand(
        pathElementCount: 0, strings: ["éé"],
        limits: RemoteComposeNativeExecutionLimits(maximumTextBytes: 3))
    }
    var repeatedText = NativeFrameBudget()
    try repeatedText.recordStrings(
      ["abc"], limits: RemoteComposeNativeExecutionLimits(maximumTextBytes: 5))
    expect(.textTooLong(actual: 6, maximum: 5)) {
      try repeatedText.recordStrings(
        ["abc"], limits: RemoteComposeNativeExecutionLimits(maximumTextBytes: 5))
    }
    var aggregateText = NativeFrameBudget()
    expect(.frameWorkExceeded(actual: 5, maximum: 4)) {
      try aggregateText.recordCommand(
        pathElementCount: 0, strings: ["text"],
        limits: RemoteComposeNativeExecutionLimits(maximumFrameWork: 4))
    }

    // A resolved coordinate is never refused: layout reads NaN as 0, a draw keeps it for
    // `isDrawable`, and both hold the rest to the coordinate limit.
    let coordinates = RemoteComposeNativeExecutionLimits(maximumCoordinateMagnitude: 10)
    #expect(coordinates.layoutCoordinate(.nan) == 0 && coordinates.layoutCoordinate(-11) == -10)
    #expect(coordinates.drawCoordinate(.nan).isNaN && coordinates.drawCoordinate(.infinity) == 10)
    let numbers = NativeFrameBudget()
    expect(.canvasTooLarge(actual: 101, maximum: 100)) {
      try numbers.validateCanvasDimensions(
        [101], limits: RemoteComposeNativeExecutionLimits(maximumCanvasDimension: 100))
    }
    expect(.invalidCanvasDimension(actual: 0)) {
      try numbers.validateDocumentDimensions([0, 100], limits: .default)
    }
    var work = NativeFrameBudget()
    expect(.frameWorkExceeded(actual: 3, maximum: 2)) {
      try work.recordCommand(
        pathElementCount: 2,
        limits: RemoteComposeNativeExecutionLimits(maximumFrameWork: 2))
    }
    var gradients = NativeFrameBudget()
    expect(.frameWorkExceeded(actual: 6, maximum: 5)) {
      try gradients.recordCommand(
        pathElementCount: 0, additionalWork: 5,
        limits: RemoteComposeNativeExecutionLimits(maximumFrameWork: 5))
    }
    var events = NativeFrameBudget()
    try events.recordEvent(strings: ["name"], limits: .default)
    expect(.textTooLong(actual: 8, maximum: 7)) {
      try events.recordEvent(strings: ["text"], limits: RemoteComposeNativeExecutionLimits(
        maximumTextBytes: 7))
    }
    var eventWork = NativeFrameBudget()
    expect(.frameWorkExceeded(actual: 4, maximum: 3)) {
      try eventWork.recordEvent(
        additionalWork: 3, limits: RemoteComposeNativeExecutionLimits(maximumFrameWork: 3))
    }
    var actionWork = NativeFrameBudget()
    try actionWork.recordWork(2, limits: RemoteComposeNativeExecutionLimits(maximumFrameWork: 2))
    expect(.frameWorkExceeded(actual: 3, maximum: 2)) {
      try actionWork.recordWork(
        1, limits: RemoteComposeNativeExecutionLimits(maximumFrameWork: 2))
    }
  }

  private func expect(
    _ expected: RemoteComposeNativeLimitError,
    sourceLocation: SourceLocation = #_sourceLocation,
    operation: () throws -> Void
  ) {
    do {
      try operation()
      Issue.record("expected \(expected)", sourceLocation: sourceLocation)
    } catch let error as RemoteComposeNativeLimitError {
      #expect(
        error == expected, "expected \(expected), got \(error)", sourceLocation: sourceLocation)
    } catch {
      Issue.record("unexpected error: \(error)", sourceLocation: sourceLocation)
    }
  }
}
