#if canImport(AppKit) && !targetEnvironment(macCatalyst)
  import AppKit
  import Foundation
  import RcNativePlayerTestDocuments
  import Testing

  @testable import RcNativePlayerCore
  @testable import RcNativePlayerUIKit

  /// A conformance capture reports the values of the frame it painted. The store is live, so a
  /// value that reads its own previous one moves on with every resolution; a capture that resolved
  /// its instant once more after painting would report a later pass than its PNG shows.
  @MainActor @Suite struct NativeAppKitCaptureValuesTests {
    /// The integer of the cycle: I60 = [70] + 1.
    private static let cycleIntegerID = 60
    /// The float of the cycle: F70 = [60] + 1.
    private static let cycleFloatID = 70
    /// A float over `ANIMATION_TIME`, so the document asks for continuous frames and every
    /// snapshot resolves again rather than reusing a static one.
    private static let clockFloatID = 71

    /// `RcValueOrderReferenceTest.aCycleThroughBothViewsAdvancesOncePerPass`'s cycle, with a box
    /// to paint and a float over the animation clock.
    private static func liveCycleDocument() -> Data {
      typealias Op = NativeSwiftWireOpcode
      let integerAdd = NativeSwiftIntegerOperator.offset + NativeSwiftIntegerOperator.add
      let floatAdd = Int(
        Int32(bitPattern: NativeSwiftFloatExpression.operatorWord(NativeSwiftFloatOperator.add)))
      func reference(_ id: Int) -> Int {
        Int(Int32(bitPattern: NativeSwiftFloatExpression.referenceWord(UInt32(id))))
      }
      let wire = NativeTestWire()
      wire.header(width: 100, height: 100)
      // Words 70, 1, add: the mask marks word 0 a variable and word 2 an operator.
      wire.u8(Op.integerExpression).int(cycleIntegerID).int(0b101).int(3)
        .int(cycleFloatID).int(1).int(integerAdd)
      wire.u8(Op.animatedFloat).int(cycleFloatID).int(3).int(reference(cycleIntegerID)).float(1)
        .int(floatAdd)
      wire.u8(Op.animatedFloat).int(clockFloatID).int(1)
        .int(reference(NativeSwiftSystemVariables.animationTime))
      wire.u8(Op.layoutRoot).int(1)
      wire.box(id: 10, size: 50)
      wire.u8(Op.containerEnd)
      return wire.data
    }

    /// One Kotlin frame is one pass: I60 = 1, F70 = 2 (the reference test above). The capture
    /// paints that frame, so it reports those values, at the first instant and at a later one.
    @Test(arguments: [0.0, 0.5])
    func aCaptureReportsTheValuesOfTheFrameItPainted(timeSeconds: TimeInterval) throws {
      let data = Self.liveCycleDocument()
      let session = try NativeSwiftDocumentSession.open(data: data)
      #expect(try session.snapshot(timeSeconds: 0).needsContinuousFrames)
      let frame = try NativeAppKitWindowController.renderFrame(
        data: data, timeSeconds: timeSeconds,
        values: NativeMacValueRequest(
          floats: [String(Self.cycleFloatID)], integers: [String(Self.cycleIntegerID)]))
      let floats = frame.values?["floats"] as? [String: Double]
      let integers = frame.values?["integers"] as? [String: Int]
      let seen = [
        integers?[String(Self.cycleIntegerID)] ?? -1,
        Int(floats?[String(Self.cycleFloatID)] ?? -1),
      ]
      #expect(seen == [1, 2], "Kotlin I60 = 1, F70 = 2; Swift \(seen)")
    }
  }
#endif
