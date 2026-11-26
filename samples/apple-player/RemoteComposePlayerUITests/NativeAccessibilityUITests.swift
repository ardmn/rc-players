import XCTest

/// The one deadline every wait in these UI tests uses.
///
/// Each wait is condition-based and returns as soon as its condition holds, so this is only the
/// point at which a test gives up. It is sized for the hosted macOS runner, where a single
/// accessibility query takes 0.5–6 s and a whole test 6× longer than on a developer machine; at
/// 5 s a predicate was evaluated only once or twice before the test failed.
let uiWaitTimeout: TimeInterval = 30

/// One unmeasured launch of the app before the first UI test of the process, whichever class runs
/// first, so first-launch work on a freshly booted or erased simulator does not run inside a test's
/// own waits. `launch()` returns once the app has gone idle, which includes its first scene.
@MainActor
enum AppWarmUp {
  /// Whether this test process has already launched the app once.
  private static var done = false

  static func once() {
    guard !done else { return }
    done = true
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(
      app.wait(for: .runningForeground, timeout: uiWaitTimeout),
      "The warm-up launch before the first UI test did not reach the foreground")
    app.terminate()
  }
}

@MainActor
final class NativeAccessibilityUITests: XCTestCase {
  override func setUp() async throws {
    try await super.setUp()
    AppWarmUp.once()
  }

  func testSwiftControlsWriteTextBackToTheDocument() throws {
    let app = XCUIApplication()
    app.launchArguments = ["--native-player", "--fixture=Swift controls"]
    app.launch()

    let name = app.textFields["swift-demo-name"]
    XCTAssertTrue(name.waitForExistence(timeout: uiWaitTimeout), app.debugDescription)
    name.tap()
    name.typeText(" Lovelace")

    XCTAssertTrue(
      app.staticTexts["Ada Lovelace"].waitForExistence(timeout: uiWaitTimeout),
      "The ordinary document text node did not receive the SwiftUI field edit")

    let level = app.sliders["swift-demo-level"]
    XCTAssertTrue(level.exists)
    let levelValue = app.staticTexts["swift-demo-level-value"]
    XCTAssertTrue(levelValue.exists)
    let originalValue = levelValue.label
    level.adjust(toNormalizedSliderPosition: 0.25)
    let valueChanged = expectation(
      for: NSPredicate(format: "label != %@", originalValue), evaluatedWith: levelValue)
    wait(for: [valueChanged], timeout: uiWaitTimeout)
  }

  /// Long enough that several keystrokes land before the first one's snapshot comes back.
  private let returnLatencyMs = 400
  /// How long a control is watched for a late echo after its edit: every return arrives
  /// `returnLatencyMs` after it was sent, so several latencies cover them all.
  private var echoWindow: TimeInterval { Double(returnLatencyMs) * 8 / 1_000 }

  /// The document applies a return value after the control has moved on. A snapshot echoing an
  /// older edit must not overwrite the newer one: with the echo adopted, " Lovelace" typed after
  /// "Ada" ended as "Ada ace" on a loaded runner, and the slider jumped back to an earlier value.
  func testSwiftControlsKeepNewerEditsWhileTheDocumentLagsBehind() throws {
    let app = XCUIApplication()
    app.launchArguments = [
      "--native-player", "--fixture=Swift controls", "--return-latency-ms=\(returnLatencyMs)",
    ]
    app.launch()

    let name = app.textFields["swift-demo-name"]
    XCTAssertTrue(name.waitForExistence(timeout: uiWaitTimeout), app.debugDescription)
    name.tap()
    name.typeText(" Lovelace")

    XCTAssertTrue(
      app.staticTexts["Ada Lovelace"].waitForExistence(timeout: uiWaitTimeout),
      "The document lost part of the edit: \(name.value ?? "nil")")
    XCTAssertEqual(name.value as? String, "Ada Lovelace", "An older echo overwrote the field")
    // The last keystrokes' echoes may still be on their way; none of them may rewind the field.
    let echoRewoundName = expectation(
      for: NSPredicate(format: "value != %@", "Ada Lovelace"), evaluatedWith: name)
    echoRewoundName.isInverted = true
    wait(for: [echoRewoundName], timeout: echoWindow)

    let level = app.sliders["swift-demo-level"]
    let levelValue = app.staticTexts["swift-demo-level-value"]
    level.adjust(toNormalizedSliderPosition: 0.25)
    // The label shows the control's own value, so it reads where the drag ended (20–30%, with
    // whatever spacing the locale puts before "%") at once. The values the drag passed through come
    // back from the document one latency later; none of them may move the label out of that range.
    let draggedTo = NSPredicate(format: "label MATCHES %@", "^(2[0-9]|30)\\D*%$")
    wait(for: [expectation(for: draggedTo, evaluatedWith: levelValue)], timeout: uiWaitTimeout)
    let echoMovedIt = expectation(
      for: NSCompoundPredicate(notPredicateWithSubpredicate: draggedTo), evaluatedWith: levelValue)
    echoMovedIt.isInverted = true
    wait(for: [echoMovedIt], timeout: echoWindow)
  }

  func testSwiftChartWritesItsSelectionBackToTheDocument() throws {
    let app = XCUIApplication()
    app.launchArguments = ["--native-player", "--fixture=Swift chart"]
    app.launch()

    let chart = app.otherElements.matching(identifier: "swift-demo-chart").firstMatch
    XCTAssertTrue(chart.waitForExistence(timeout: uiWaitTimeout), app.debugDescription)
    chart.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).press(
      forDuration: 0.1,
      thenDragTo: chart.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))

    let returnedSelection = app.staticTexts.matching(
      NSPredicate(format: "label CONTAINS %@ AND label ENDSWITH %@", " · ", " momentum")
    ).firstMatch
    XCTAssertTrue(
      returnedSelection.waitForExistence(timeout: uiWaitTimeout),
      "The ordinary document text node did not receive the Swift Charts selection")
  }

  func testTitleCardExposesNativeAssistiveTechnologyTargets() throws {
    let app = XCUIApplication()
    app.launchArguments = ["--native-accessibility-ui-test"]
    app.launch()

    let nativeButton = app.buttons.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "rc-native-button-")
    ).firstMatch
    XCTAssertTrue(nativeButton.waitForExistence(timeout: uiWaitTimeout), app.debugDescription)
    XCTAssertEqual(nativeButton.label, "Morning run, 5.2 km · 28 min")
    XCTAssertTrue(nativeButton.isEnabled)
    XCTAssertTrue(nativeButton.isHittable)

    let labels = app.staticTexts.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "rc-native-text-")
    )
    XCTAssertEqual(labels.count, 0, "The conceptual button must own its descendant text labels")

    try app.performAccessibilityAudit(
      for: [.elementDetection, .hitRegion, .sufficientElementDescription, .trait])
  }
}
