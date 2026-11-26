import XCTest

/// The one deadline every wait in these UI tests uses.
///
/// Each wait is condition-based and returns as soon as its condition holds, so this is only the
/// point at which a test gives up. It is sized for the hosted macOS runner, where a single
/// accessibility query takes 0.5–6 s and a whole test 6× longer than on a developer machine; at
/// 5 s a predicate was evaluated only once or twice before the test failed.
let uiWaitTimeout: TimeInterval = 30

@MainActor
final class NativeAccessibilityUITests: XCTestCase {
  /// Whether this test process has launched the app once before its first test.
  private static var appWarmedUp = false

  /// Launch the app once, unmeasured, before the first test, so first-launch work on a freshly
  /// booted or erased simulator (dyld and font caches, the first scene) does not run inside a
  /// test's own waits.
  override func setUp() async throws {
    try await super.setUp()
    guard !Self.appWarmedUp else { return }
    Self.appWarmedUp = true
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(app.wait(for: .runningForeground, timeout: uiWaitTimeout), "warm-up launch")
    app.terminate()
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
