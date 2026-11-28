#if canImport(UIKit)
  import Foundation
  import RcNativePlayerCore
  import RcNativePlayerTestDocuments
  import Testing
  import UIKit

  @testable import RcNativePlayerUIKit

  /// The UIKit player refines a frame on a copy of its session, so the scroll extents its layout
  /// measures reach the live session as an input of their own.
  @MainActor @Suite(.serialized) struct NativeUIKitScrollLayoutTests {
    /// The Kotlin player's readouts (`scroll-metrics.expected.json`), in points.
    private struct Expected: Decodable {
      struct Paged: Decodable {
        struct Rest: Decodable {
          let maximumOffset: Float
          let contentLength: Float
        }
        let rest: Rest
      }
      let paged: Paged
    }

    /// The fixture's slots hold pixels at `displayScale: 2`.
    private static let pixelsPerPoint: Float = 2

    @Test func theLiveSessionIsHandedTheScrollLayoutOnce() async throws {
      let expected = try JSONDecoder().decode(
        Expected.self, from: NativeTestFixtures.data("scroll-metrics.expected.json")
      ).paged.rest
      var errors: [RemoteComposeNativePlayerError] = []
      let view = RemoteComposeNativePlayerView(
        data: try NativeTestFixtures.data("scroll-metrics-paged.rc"), resourceResolver: nil,
        onError: { errors.append($0) })
      var handed: [[Int: NativeSwiftScrollMeasurement]] = []
      view.onInputApplied = { input in
        if case .scrollLayout(let measured) = input { handed.append(measured) }
      }
      view.frame = CGRect(x: 0, y: 0, width: 240, height: 180)
      try await waitUntil("the document opens", within: 60) { !view.isOpeningDocument }
      view.layoutIfNeeded()
      try await waitUntil("the layout reaches the session", within: 60) { !handed.isEmpty }
      try await waitUntil("the player settles", within: 60) { !view.isBusy }
      view.layoutIfNeeded()
      try await waitUntil("the player settles again", within: 60) { !view.isBusy }
      try #require(errors.isEmpty, "\(errors)")
      // The frame the input produced lays out to the same extents, which are not sent again.
      #expect(handed.count == 1)
      let scroll = try #require(handed.first?.values.first)
      #expect(scroll.maximumOffset / Self.pixelsPerPoint == expected.maximumOffset)
      #expect(scroll.content / Self.pixelsPerPoint == expected.contentLength)
    }

    /// A scroll layout the player refused (a background scene, a full input queue) is not counted
    /// as handed over: the next layout pass offers it again, and once taken it is not resent.
    @Test func aRefusedScrollLayoutIsOfferedAgain() async throws {
      let (_, frame) = try await NativePlayerEngine.open(
        data: NativeTestFixtures.data("scroll-metrics-paged.rc"), maximumDocumentBytes: 1 << 20)
      let model = try NativeDocument(frame: frame, timeSeconds: 0, limits: .default)
      let resources = try NativeResourceStore(
        resources: model.images, fonts: model.fonts, limits: .default,
        cache: NativeImageCache(countLimit: 1, totalCostLimit: 1))
      var admissions = [false, true]
      var offered = 0
      let view = NativeDocumentView(
        document: model, resources: resources, customComponents: .init(),
        onGesture: { _, _, _ in }, onClickArea: { _, _ in }, onCustomReturn: { _, _, _ in },
        onScrollLayout: { _ in
          offered += 1
          return admissions.isEmpty ? true : admissions.removeFirst()
        })
      view.frame = CGRect(x: 0, y: 0, width: 240, height: 180)
      for _ in 0..<3 {
        view.setNeedsLayout()
        view.layoutIfNeeded()
      }
      #expect(offered == 2)
    }
  }
#endif
