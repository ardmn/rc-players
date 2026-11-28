import Foundation
import RcNativePlayerTestDocuments
import Testing

@_spi(Conformance) @_spi(RemoteComposeController) @testable import RcNativePlayerCore
@_spi(RemoteComposeController) @testable import RcNativePlayerUIKit

#if canImport(UIKit)
  import UIKit
#endif

/// A host's string counts against the frame's text once however many texts show it, as AndroidX
/// lays it out (`AndroidRemoteContext.setNamedStringOverride`); a document's text counts each time.
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

  /// 100 KB, over what a document can make itself, and 40 KB, under it: four texts of either are
  /// over the 128 KiB a frame's own text may take if each text counted it.
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

  /// A host's string counts once, at most the longest text a document can make; a document's
  /// string of the same length still counts each time it is shown.
  @Test func aHostStringCountsOnceAndADocumentStringEveryTime() throws {
    let longest = RemoteComposeNativeExecutionLimits.longestDocumentTextBytes
    let hostBytes = 40_000
    let host = String(repeating: "h", count: hostBytes)
    var budget = NativeFrameBudget(hostStrings: [host])
    for _ in 0..<10 { try budget.recordStrings([host], limits: .default) }
    #expect(budget.textBytes == hostBytes && budget.work == hostBytes)
    // Longer than any document text, so it counts once as a host's, whatever the snapshot names.
    let long = String(repeating: "l", count: longest + 1)
    for _ in 0..<10 { try budget.recordStrings([long], limits: .default) }
    #expect(budget.textBytes == hostBytes + longest)
    var document = NativeFrameBudget(hostStrings: [host])
    let documentText = String(repeating: "d", count: hostBytes)
    #expect(throws: RemoteComposeNativeLimitError.self) {
      for _ in 0..<10 { try document.recordStrings([documentText], limits: .default) }
    }
  }
}
