import RcNativePlayerTestDocuments
import Testing

@testable import RcNativePlayerCore

/// `NativeTestWire.NamedType` copies the core's internal `NativeSwiftNamedVariableType` so the
/// test documents can be written without `@testable`; this keeps the copy equal to the core.
@Suite struct NativeTestWireNamedTypeTests {
  @Test func everyNamedTypeIsTheCoresValue() {
    typealias Copy = NativeTestWire.NamedType
    typealias Core = NativeSwiftNamedVariableType
    #expect(Copy.string == Core.string)
    #expect(Copy.float == Core.float)
    #expect(Copy.color == Core.color)
    #expect(Copy.image == Core.image)
    #expect(Copy.int == Core.int)
    #expect(Copy.long == Core.long)
    #expect(Copy.floatArray == Core.floatArray)
  }

  @Test func everyPaintKeyAndStyleIsTheCoresValue() {
    typealias Key = NativeTestWire.PaintKey
    #expect(Key.textSize == NativeSwiftPaintCommand.textSize)
    #expect(Key.color == NativeSwiftPaintCommand.color)
    #expect(Key.strokeWidth == NativeSwiftPaintCommand.strokeWidth)
    #expect(Key.style == NativeSwiftPaintCommand.style)
    #expect(NativeTestWire.PaintStyle.fill == NativeSwiftPaintStyle.fill)
    #expect(NativeTestWire.PaintStyle.stroke == NativeSwiftPaintStyle.stroke)
  }

  /// A variable word the test documents write is one the core reads back as that variable.
  @Test func aVariableWordIsTheCoresReference() {
    for id in [1, 50, 1000] {
      let word = UInt32(truncatingIfNeeded: NativeTestDocuments.FloatWord.variable(id).bits)
      #expect(NativeSwiftFloatExpression.referenceID(word) == id)
    }
  }
}
