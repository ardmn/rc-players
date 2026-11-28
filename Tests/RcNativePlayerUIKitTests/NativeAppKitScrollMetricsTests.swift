#if canImport(AppKit) && !targetEnvironment(macCatalyst)
  import AppKit
  import Foundation
  import RcNativePlayerCore
  import Testing

  @testable import RcNativePlayerUIKit

  /// A scroll's layout publishes its maximum offset and content length, as the Kotlin player and
  /// AndroidX do.
  ///
  /// The expected readouts are the Kotlin player's (`scroll-metrics.expected.json`, recorded by
  /// `RcScrollMetricsReferenceTest`), in points: the slots hold pixels, `scale` per point.
  @MainActor @Suite struct NativeAppKitScrollMetricsTests {
    private struct Readout: Decodable, Equatable {
      let offset: Float
      let maximumOffset: Float
      let contentLength: Float
    }

    private struct Expected: Decodable {
      struct Paged: Decodable {
        let rest: Readout
      }
      struct List: Decodable { let rest: Readout }
      let paged: Paged
      let list: List
    }

    /// The scroll's three slots, read from the document as the player opens it.
    private struct Slots {
      let position: Int
      let maximum: Int
      let contentLength: Int
      let scale: Float
    }

    private static let paged = "scroll-metrics-paged.rc"
    private static let list = "scroll-metrics-list.rc"
    /// The fixtures are written at `displayScale: 2`; their readouts divide the slots by it.
    private static let pixelsPerPoint: Float = 2
    private func expected() throws -> Expected {
      try JSONDecoder().decode(
        Expected.self, from: NativeTestFixtures.data("scroll-metrics.expected.json"))
    }

    private func slots(_ name: String) throws -> Slots {
      let session = try NativeSwiftDocumentSession.open(data: NativeTestFixtures.data(name))
      func scrolled(_ node: NativeSwiftNodeSnapshot) -> NativeSwiftNodeSnapshot? {
        node.scrollDirection != nil ? node : node.children.lazy.compactMap(scrolled).first
      }
      let node = try #require(scrolled(try session.snapshot().root))
      return Slots(
        position: try #require(node.scrollPositionID),
        maximum: try #require(node.scrollMaximumID),
        contentLength: try #require(node.scrollContentLengthID),
        scale: Self.pixelsPerPoint)
    }

    private func step(
      _ kind: String, x: CGFloat, y: CGFloat, at: Double,
      viewport: CGSize? = nil
    ) -> [String: Any] {
      var step: [String: Any] = ["kind": kind, "x": x, "y": y, "at": at]
      if let viewport {
        step["width"] = viewport.width
        step["height"] = viewport.height
      }
      return step
    }

    /// The readout after replaying `steps`, `timeSeconds` into the frame.
    private func readout(
      _ name: String, steps: [[String: Any]] = [], timeSeconds: TimeInterval = 0,
      viewport: CGSize? = nil
    ) throws -> Readout {
      let slots = try slots(name)
      let decoded = try JSONDecoder().decode(
        [NativeMacInputStep].self, from: JSONSerialization.data(withJSONObject: steps))
      let frame = try NativeAppKitWindowController.renderFrame(
        data: NativeTestFixtures.data(name), timeSeconds: timeSeconds, viewport: viewport,
        values: NativeMacValueRequest(
          floats: [slots.position, slots.maximum, slots.contentLength].map(String.init)),
        steps: decoded)
      let floats = try #require(frame.values?["floats"] as? [String: Any])
      // A slot nothing wrote reports a plain zero, as the corpus's probes expect.
      func points(_ id: Int) throws -> Float {
        try #require((floats[String(id)] as? NSNumber)?.floatValue) / slots.scale
      }
      return Readout(
        offset: try points(slots.position), maximumOffset: try points(slots.maximum),
        contentLength: try points(slots.contentLength))
    }

    @Test func aPagedScrollPublishesItsTravelAndContentLengthAfterLayout() throws {
      #expect(try readout(Self.paged) == expected().paged.rest)
    }

    @Test func aListPublishesItsTravelAndContentLengthAfterLayout() throws {
      let reference = try expected().list.rest
      let measured = try readout(Self.list)
      #expect(measured.offset == reference.offset)
      #expect(measured.contentLength == reference.contentLength)
      withKnownIssue(
        "The native column gives a scroll below a sibling the column's whole height, not what the sibling leaves, so its viewport is longer than the Kotlin player's"
      ) {
        #expect(measured.maximumOffset == reference.maximumOffset)
      }
    }

    /// The paged fixture laid out at the size it declares, then relaid out in the same session
    /// `change` pixels wider or narrower.
    private func pagedReadout(widenedBy change: CGFloat) throws -> Readout {
      let declared = try NativeSwiftDocumentSession.open(
        data: NativeTestFixtures.data(Self.paged)
      ).snapshot()
      let declaredSize = CGSize(width: CGFloat(declared.width), height: CGFloat(declared.height))
      let changed = CGSize(width: declaredSize.width + change, height: declaredSize.height)
      // Taps below the scroll, which only carry the viewport each is dispatched in.
      let outside = CGPoint(x: 100, y: 300)
      return try readout(
        Self.paged,
        steps: [
          step("touch_up", x: outside.x, y: outside.y, at: 0, viewport: declaredSize),
          step("touch_up", x: outside.x, y: outside.y, at: 0.1, viewport: changed),
        ],
        timeSeconds: 0.1, viewport: changed)
    }

    /// A wider viewport is a new layout, and the travel it publishes shrinks by what the scroll
    /// gained (AndroidX `setHorizontalScrollDimension`: content less host); the content is unchanged.
    @Test func aWiderScrollRepublishesAShorterTravel() throws {
      let rest = try expected().paged.rest
      let widening: CGFloat = 80
      let wider = try pagedReadout(widenedBy: widening)
      #expect(wider.contentLength == rest.contentLength)
      #expect(wider.maximumOffset == rest.maximumOffset - Float(widening) / Self.pixelsPerPoint)
    }

    /// AndroidX `ScrollModifierOperation.layout` caps the travel where the last child starts, so a
    /// narrower viewport scrolls no further than the last page's start.
    @Test func aNarrowerScrollStopsWhereTheLastPageStarts() throws {
      let rest = try expected().paged.rest
      let narrower = try pagedReadout(widenedBy: -80)
      #expect(narrower.contentLength == rest.contentLength)
      #expect(narrower.maximumOffset == rest.maximumOffset)
    }
  }
#endif
