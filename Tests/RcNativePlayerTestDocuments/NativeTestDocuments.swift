import Foundation
import RcNativePlayerCore

/// `.rc` documents the native player's suites build from wire opcodes.
public enum NativeTestDocuments {
  /// The id of the box in ``shownBox()``.
  public static let boxID = 10

  /// A 200×200 document whose 50×50 box (``boxID``) is gone until the integer named "shown" says
  /// otherwise.
  public static func shownBox() -> Data {
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
    for value in [1, 0, 0, 200, 200, 0, 0] { int(value) }
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
}
