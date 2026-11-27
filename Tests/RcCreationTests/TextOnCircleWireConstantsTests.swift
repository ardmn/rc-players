import RcNativePlayerCore
import RcWireOperations
import Testing

/// The native player's `DrawTextOnCircle` byte values are the ones the Swift writer puts on the
/// wire; `NativeSwiftTextOnCircleTests` checks the same values against the Kotlin player.
@Suite struct TextOnCircleWireConstantsTests {
  @Test func alignmentAndPlacementMatchTheWriter() {
    #expect(Int(DrawTextOnCircle.start) == NativeSwiftTextOnCircleAlignment.start)
    #expect(Int(DrawTextOnCircle.center) == NativeSwiftTextOnCircleAlignment.center)
    #expect(Int(DrawTextOnCircle.end) == NativeSwiftTextOnCircleAlignment.end)
    #expect(Int(DrawTextOnCircle.outside) == NativeSwiftTextOnCirclePlacement.outside)
    #expect(Int(DrawTextOnCircle.inside) == NativeSwiftTextOnCirclePlacement.inside)
  }
}
