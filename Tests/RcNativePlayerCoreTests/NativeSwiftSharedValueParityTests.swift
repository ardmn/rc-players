import Foundation
import Testing

@testable import RcNativePlayerCore

/// Values the Swift core shares with the Kotlin player but keeps its own copy of, since it links no
/// Kotlin: each test reads the Kotlin declaration from source and fails when the two drift, as
/// `NativeSwiftFloatListLimitParityTests` does for the float-list limit.
@Suite struct NativeSwiftSharedValueParityTests {
  private static let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  private static let kotlinPlayer =
    "rc-player/compose/src/commonMain/kotlin/ee/schimke/composeai/rcplayer/compose/"
    + "RcComposePlayer.kt"
  private static let kotlinState =
    "rc-player/runtime/src/commonMain/kotlin/ee/schimke/composeai/rcplayer/runtime/"
    + "RcPlayerState.kt"

  /// The number literal of the Kotlin `const val name` declared in the file at `path`, read from
  /// that exact declaration (an `f` suffix and `_` separators dropped).
  private static func kotlinConstant(_ name: String, in path: String) throws -> Double? {
    let source = try String(
      contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8)
    let regex = try NSRegularExpression(
      pattern: #"^(?:private |internal |public )?const val "# + name
        + #"(?:: \w+)? = ([\d_.]+)f?$"#,
      options: .anchorsMatchLines)
    let range = NSRange(source.startIndex..., in: source)
    let matches = regex.matches(in: source, range: range)
    guard matches.count == 1, let literal = Range(matches[0].range(at: 1), in: source) else {
      return nil
    }
    return Double(source[literal].replacingOccurrences(of: "_", with: ""))
  }

  /// The same number; Kotlin spends it per paint and Swift per document, a known divergence.
  @Test func theLoopBudgetMatchesTheKotlinPlayer() throws {
    let kotlin = try Self.kotlinConstant("MAX_LOOP_OPERATIONS_PER_FRAME", in: Self.kotlinState)
    #expect(kotlin == Double(NativeSwiftDocumentDecoder.maximumLoopOperationsPerDocument))
  }

  @Test func theTextSizeBoundsMatchTheKotlinPlayer() throws {
    let unset = try Self.kotlinConstant("RC_DEFAULT_TEXT_SIZE_PX", in: Self.kotlinPlayer)
    #expect(unset == Double(NativeSwiftTextSnapshot.androidDefaultSize))
    let largest = try Self.kotlinConstant("RC_MAX_TEXT_SIZE_PX", in: Self.kotlinPlayer)
    #expect(largest == Double(NativeSwiftTextSnapshot.maximumSize))
  }

  @Test func theAutosizeDefaultsMatchTheKotlinPlayer() throws {
    let minimum = try Self.kotlinConstant("RC_AUTOSIZE_DEFAULT_MIN_PX", in: Self.kotlinPlayer)
    #expect(minimum == Double(NativeSwiftTextAutosize.defaultMinimumFontSize))
    let maximum = try Self.kotlinConstant("RC_AUTOSIZE_DEFAULT_MAX_PX", in: Self.kotlinPlayer)
    #expect(maximum == Double(NativeSwiftTextAutosize.defaultMaximumFontSize))
  }

  @Test func theNormalWeightMatchesTheKotlinPlayer() throws {
    let kotlin = try Self.kotlinConstant("RC_NORMAL_TEXT_WEIGHT", in: Self.kotlinPlayer)
    #expect(kotlin == Double(NativeSwiftTextSnapshot.normalWeight))
  }
}
