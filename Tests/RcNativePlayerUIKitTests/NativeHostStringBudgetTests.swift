import Foundation
import RcNativePlayerTestDocuments
import Testing

@_spi(Conformance) @_spi(RemoteComposeController) @testable import RcNativePlayerCore
@_spi(RemoteComposeController) @testable import RcNativePlayerUIKit

#if canImport(UIKit)
  import UIKit
#endif

/// A host's string renders at any length, as AndroidX lays it out
/// (`AndroidRemoteContext.setNamedStringOverride`): it counts once against the frame's text, and
/// each text showing it costs bounded work; a document's text counts its bytes each time.
@MainActor @Suite(.serialized) struct NativeHostStringBudgetTests {
  static let hostName = "USER:s"

  /// A document whose `count` texts all show the host string ``hostName``.
  static func document(texts count: Int) -> Data {
    typealias Op = NativeSwiftWireOpcode
    let wire = NativeTestWire()
    wire.header(width: 100, height: 100)
    wire.u8(Op.dataText).int(700).utf8("short")
      .named(700, NativeTestWire.NamedType.string, hostName)
    wire.u8(Op.layoutRoot).int(1)
    for index in 0..<count { wire.text(id: 3000 + index, reading: 700) }
    wire.u8(Op.containerEnd)
    return wire.data
  }

  /// 100 KB, over what a document can make itself, and 40 KB, under it.
  static let hostStrings = [
    String(repeating: "x", count: 100_000), String(repeating: "y", count: 40_000),
  ]

  @Test(arguments: [1, 2, 3, 4])
  func aHostStringShownByManyTextsRenders(_ count: Int) async throws {
    for text in Self.hostStrings {
      let label = "\(count) texts of \(text.utf8.count) bytes"
      #if canImport(AppKit) && !canImport(UIKit)
        let session = try NativeSwiftDocumentSession.open(data: Self.document(texts: count))
        #expect(session.setString(text, for: Self.hostName))
        let snapshot = try session.snapshot(timeSeconds: 0)
        #expect(throws: Never.self, "\(label)") {
          _ = try NativeMacPolicy.evaluate(snapshot, compatibility: .compatible)
        }
      #elseif canImport(UIKit)
        var errors: [RemoteComposeNativePlayerError] = []
        let view = RemoteComposeNativePlayerView(
          data: Self.document(texts: count), resourceResolver: nil,
          onError: { errors.append($0) })
        view.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        try await waitUntil("\(label) opens", within: 60) {
          !view.isOpeningDocument && !view.isBusy
        }
        let result = await view.submit(.text(text), for: Self.hostName)
        #expect(result == .accepted, "\(label)")
        try await waitUntil("\(label) settles", within: 60) { !view.isBusy }
        view.setNeedsLayout()
        view.layoutIfNeeded()
        #expect(errors.isEmpty, "\(label): \(errors)")
      #endif
    }
  }

  /// The snapshot names the strings a host wrote, and only while the host's value stands.
  @Test func theSnapshotNamesTheHostsStrings() throws {
    let session = try NativeSwiftDocumentSession.open(data: Self.document(texts: 1))
    #expect(try session.snapshot(timeSeconds: 0).hostStrings.isEmpty)
    #expect(session.setString("from the host", for: Self.hostName))
    #expect(try session.snapshot(timeSeconds: 0).hostStrings == ["from the host"])
    #expect(session.clearNamedValue(Self.hostName))
    #expect(try session.snapshot(timeSeconds: 0).hostStrings.isEmpty)
  }

  /// A host's string counts once against the frame's text, at most the longest text a document can
  /// make, and every place it is shown costs up to `hostStringPlacementWork`; a node's text and its
  /// accessibility copy of it are one place. A document's string counts its bytes each time in
  /// both.
  @Test func aHostStringCostsWorkEachTimeAndADocumentStringItsBytes() throws {
    let longest = RemoteComposeNativeExecutionLimits.longestDocumentTextBytes
    let placement = RemoteComposeNativeExecutionLimits.hostStringPlacementWork
    let hostBytes = 40_000
    let host = String(repeating: "h", count: hostBytes)
    var budget = NativeFrameBudget(hostStrings: [host])
    for _ in 0..<2 { try budget.recordStrings([host, host], limits: .default) }
    #expect(budget.textBytes == hostBytes && budget.work == 2 * placement)
    let short = "short"
    var shortBudget = NativeFrameBudget(hostStrings: [short])
    try shortBudget.recordStrings([short], limits: .default)
    #expect(shortBudget.work == short.utf8.count)
    // Longer than any document text, so it is a host's whatever the snapshot names.
    let long = String(repeating: "l", count: longest + 1)
    try budget.recordStrings([long], limits: .default)
    #expect(budget.textBytes == hostBytes + longest && budget.work == 3 * placement)
    var document = NativeFrameBudget(hostStrings: [host])
    let documentText = String(repeating: "d", count: hostBytes)
    #expect(throws: RemoteComposeNativeLimitError.self) {
      for _ in 0..<10 { try document.recordStrings([documentText], limits: .default) }
    }
  }

  /// A megabyte host string shown by many texts is refused by the frame's work budget rather than
  /// laid out once per text: 60 texts would be 60 MB of layout on the main thread.
  @Test func manyTextsShowingAMegabyteHostStringExceedTheFrameWork() throws {
    let host = String(repeating: "m", count: 1_000_000)
    let places =
      RemoteComposeNativeExecutionLimits.default.maximumFrameWork
      / RemoteComposeNativeExecutionLimits.hostStringPlacementWork + 1
    var budget = NativeFrameBudget(hostStrings: [host])
    #expect(throws: RemoteComposeNativeLimitError.self) {
      for _ in 0..<places { try budget.recordStrings([host], limits: .default) }
    }
    #if canImport(AppKit) && !canImport(UIKit)
      let session = try NativeSwiftDocumentSession.open(data: Self.document(texts: places))
      #expect(session.setString(host, for: Self.hostName))
      let snapshot = try session.snapshot(timeSeconds: 0)
      #expect(throws: RemoteComposeNativeLimitError.self) {
        _ = try NativeMacPolicy.evaluate(snapshot, compatibility: .compatible)
      }
    #endif
  }

  /// The corpus's headphone card shows its megabyte title and detail in several places, which
  /// render, as on Kotlin.
  @Test func theHeadphoneCardRendersAMegabyteTitleAndDetail() throws {
    let card = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("rc-player/edit/src/jvmTest/fixtures/cadence-headphone-fixed.rc")
    for names in [["USER:title"], ["USER:detail"], ["USER:title", "USER:detail"]] {
      let session = try NativeSwiftDocumentSession.open(data: try Data(contentsOf: card))
      for name in names {
        let text = String(repeating: name == "USER:title" ? "t" : "d", count: 1_000_000)
        #expect(session.setString(text, for: name), "\(name)")
      }
      let snapshot = try session.snapshot(timeSeconds: 0)
      #if canImport(AppKit) && !canImport(UIKit)
        #expect(throws: Never.self, "\(names)") {
          _ = try NativeMacPolicy.evaluate(snapshot, compatibility: .compatible)
        }
      #endif
    }
  }

  /// The corpus's banner shows three host strings; at a megabyte each it renders, as on Kotlin.
  @Test func theBannerRendersThreeMegabyteHostStrings() throws {
    let banner = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("renders/ts-empty-font-height/banner.rc")
    let session = try NativeSwiftDocumentSession.open(data: try Data(contentsOf: banner))
    var hostStrings: Set<String> = []
    for (index, name) in ["USER:headline", "USER:body", "USER:cta"].enumerated() {
      let text = String(repeating: Character(UnicodeScalar(UInt8(97 + index))), count: 1_000_000)
      #expect(session.setString(text, for: name), "\(name)")
      hostStrings.insert(text)
    }
    let snapshot = try session.snapshot(timeSeconds: 0)
    #expect(snapshot.hostStrings == hostStrings)
    #if canImport(AppKit) && !canImport(UIKit)
      #expect(throws: Never.self) {
        _ = try NativeMacPolicy.evaluate(snapshot, compatibility: .compatible)
      }
    #endif
    var budget = NativeFrameBudget(hostStrings: snapshot.hostStrings)
    #expect(throws: Never.self) {
      for text in hostStrings { try budget.recordStrings([text], limits: .default) }
    }
  }
}
