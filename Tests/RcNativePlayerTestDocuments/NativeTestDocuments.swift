import Foundation
import RcNativePlayerCore

/// `.rc` documents the native player's suites build from wire opcodes.
public enum NativeTestDocuments {
  /// The id of the box in ``shownBox()``.
  public static let boxID = 10

  /// A `size`×`size` document whose 50×50 box (``boxID``) is gone until the integer named "shown"
  /// says otherwise.
  public static func shownBox(size: Int = 200) -> Data {
    typealias Op = NativeSwiftWireOpcode
    let shownID = 550
    var data = Data()
    func u8(_ value: Int) { data.append(UInt8(truncatingIfNeeded: value)) }
    func int(_ value: Int) {
      let raw = UInt32(bitPattern: Int32(truncatingIfNeeded: value))
      for shift in [24, 16, 8, 0] { data.append(UInt8(truncatingIfNeeded: raw >> shift)) }
    }
    func float(_ value: Float) { int(Int(Int32(bitPattern: value.bitPattern))) }
    u8(Op.header)
    for value in [1, 0, 0, size, size, 0, 0] { int(value) }
    u8(Op.dataInt)
    int(shownID)
    int(NativeSwiftVisibility.gone)
    let name = Array("shown".utf8)
    u8(Op.namedVariable)
    int(shownID)
    int(4)  // The wire type of an integer named variable.
    int(name.count)
    for byte in name { u8(Int(byte)) }
    u8(Op.layoutRoot)
    int(1)
    u8(Op.layoutBox)
    for value in [boxID, -1, 1, 1] { int(value) }
    for opcode in [Op.modifierWidth, Op.modifierHeight] {
      u8(opcode)
      int(NativeSwiftDimensionType.exact)
      float(50)
    }
    u8(Op.modifierVisibility)
    int(shownID)
    u8(Op.layoutContent)
    int(-1)
    u8(Op.containerEnd)
    u8(Op.containerEnd)
    u8(Op.containerEnd)
    return data
  }

  /// The id of the text in ``label()``.
  public static let labelID = 20

  /// A 200×100 document showing two texts: ``labelID`` reads the string named "label", "Idle"
  /// until it is set, and the other reads "title", "Title" until it is set.
  public static func label() -> Data {
    typealias Op = NativeSwiftWireOpcode
    let textID = 60
    let titleID = 61
    var data = Data()
    func u8(_ value: Int) { data.append(UInt8(truncatingIfNeeded: value)) }
    func int(_ value: Int) {
      let raw = UInt32(bitPattern: Int32(truncatingIfNeeded: value))
      for shift in [24, 16, 8, 0] { data.append(UInt8(truncatingIfNeeded: raw >> shift)) }
    }
    func float(_ value: Float) { int(Int(Int32(bitPattern: value.bitPattern))) }
    func utf8(_ value: String) {
      let bytes = Array(value.utf8)
      int(bytes.count)
      data.append(contentsOf: bytes)
    }
    u8(Op.header)
    for value in [1, 0, 0, 200, 100, 0, 0] { int(value) }
    u8(Op.dataText)
    int(textID)
    utf8("Idle")
    u8(Op.namedVariable)
    int(textID)
    int(0)  // The wire type of a string named variable.
    utf8("label")
    u8(Op.dataText)
    int(titleID)
    utf8("Title")
    u8(Op.namedVariable)
    int(titleID)
    int(0)
    utf8("title")
    u8(Op.layoutRoot)
    int(1)
    // TextLayout: component, animation, text, colour, size, style, weight, family, alignment,
    // overflow, maximum lines.
    for (componentID, text) in [(labelID, textID), (labelID + 1, titleID)] {
      u8(Op.layoutText)
      for value in [componentID, 0, text, Int(Int32(bitPattern: 0xFF00_0000))] { int(value) }
      float(16)
      int(0)
      float(400)
      for value in [-1, 1, 1, 1] { int(value) }
      u8(Op.containerEnd)
    }
    u8(Op.containerEnd)
    return data
  }
}
