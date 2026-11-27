import Foundation
import RcNativePlayerCore

/// `.rc` documents the native player's suites build from wire opcodes.
public enum NativeTestDocuments {
  /// The id of the box in ``shownBox()``.
  public static let boxID = 10

  /// The integer named ``shownName`` in ``shownBox()`` and the controller suites' document.
  public static let shownVariableID = 550
  /// The integer named ``localName`` in the controller suites' document.
  public static let localVariableID = 551
  /// The name of the integer ``shownVariableID``.
  public static let shownName = "shown"
  /// The name of the integer ``localVariableID``.
  public static let localName = "local"

  /// The string variable ``labelName`` in ``manyIntegers(count:withLabel:)`` and the controller
  /// suites' document.
  public static let labelVariableID = 560
  /// The name of the string the label documents' text reads.
  public static let labelName = "label"
  /// That string's value until a host sets it.
  public static let labelInitial = "Idle"
  /// The name of the second string in ``label()``.
  public static let titleName = "title"
  /// That string's value until a host sets it.
  public static let titleInitial = "Title"
  /// The string variable ``label()`` declares as ``labelName`` (``labelVariableID`` is the one
  /// the other documents declare under that name).
  public static let labelDocumentLabelStringID = 60
  /// The string variable ``label()`` declares as ``titleName``.
  public static let labelDocumentTitleStringID = 61

  /// The text colour of every test document: opaque black, as the signed integer the wire holds.
  public static let opaqueBlack = Int(Int32(bitPattern: 0xFF00_0000))

  /// The text limit the suites set (`maximumTextBytes`).
  public static let textLimitBytes = 64

  /// A string twice ``textLimitBytes`` long, of the one-byte `character` repeated: over the limit.
  public static func overLimitText(repeating character: Character = "x") -> String {
    String(repeating: character, count: 2 * textLimitBytes)
  }

  /// A `size`×`size` document whose 50×50 box (``boxID``) is gone until the integer named
  /// `variableName` (``shownName`` by default) says otherwise.
  public static func shownBox(size: Int = 200, variableName: String = shownName) -> Data {
    typealias Op = NativeSwiftWireOpcode
    let wire = NativeTestWire()
    wire.header(width: size, height: size)
    wire.u8(Op.dataInt).int(shownVariableID).int(NativeSwiftVisibility.gone)
      .named(shownVariableID, NativeTestWire.NamedType.int, variableName)
    wire.u8(Op.layoutRoot).int(1)
    wire.box(id: boxID, size: 50, visibility: shownVariableID, content: -1)
    wire.u8(Op.containerEnd)
    return wire.data
  }

  /// The id of the text in ``label()``.
  public static let labelID = 20

  /// A 200×100 document showing two texts: ``labelID`` reads the string named ``labelName``,
  /// ``labelInitial`` until it is set, and the other reads ``titleName``, ``titleInitial`` until it
  /// is set.
  public static func label() -> Data {
    typealias Op = NativeSwiftWireOpcode
    typealias Kind = NativeTestWire.NamedType
    let wire = NativeTestWire()
    wire.header(width: 200, height: 100)
    wire.u8(Op.dataText).int(labelDocumentLabelStringID).utf8(labelInitial)
      .named(labelDocumentLabelStringID, Kind.string, labelName)
    wire.u8(Op.dataText).int(labelDocumentTitleStringID).utf8(titleInitial)
      .named(labelDocumentTitleStringID, Kind.string, titleName)
    wire.u8(Op.layoutRoot).int(1)
    wire.text(id: labelID, reading: labelDocumentLabelStringID)
    wire.text(id: labelID + 1, reading: labelDocumentTitleStringID)
    wire.u8(Op.containerEnd)
    return wire.data
  }

  /// float "f" = 1.5, colour "c" = opaque black, integer "b" (a boolean) = 0, string "s" = "a",
  /// integer "i" = 3, and string "computed", the text of the float 2 (TextFromFloat): a value the
  /// document computes and nobody writes. One 10×10 box.
  public static func everyHostType() -> Data {
    typealias Op = NativeSwiftWireOpcode
    typealias Kind = NativeTestWire.NamedType
    let wire = NativeTestWire()
    wire.header(width: 100, height: 100)
    wire.u8(Op.dataFloat).int(700).float(1.5).named(700, Kind.float, "f")
    wire.u8(Op.colorConstant).int(701).int(opaqueBlack)
      .named(701, Kind.color, "c")
    wire.u8(Op.dataInt).int(702).int(0).named(702, Kind.int, "b")
    wire.u8(Op.dataText).int(703).utf8("a").named(703, Kind.string, "s")
    wire.u8(Op.dataInt).int(705).int(3).named(705, Kind.int, "i")
    // TextFromFloat: output id, value, digits before << 16 | digits after, flags.
    wire.u8(Op.textFromFloat).int(704).float(2).int((2 << 16) | 1).int(0)
      .named(704, Kind.string, "computed")
    wire.u8(Op.layoutRoot).int(1)
    wire.box(id: 10, size: 10)
    wire.u8(Op.containerEnd)
    return wire.data
  }

  /// long "when" (id 710, 2023-11-14T22:13:20Z in epoch milliseconds), float array "series" (id
  /// 711, a static list of 1 and 2) and float "scalar" (id 712, 1), and one 10×10 box.
  public static func longAndFloatArray() -> Data {
    typealias Op = NativeSwiftWireOpcode
    typealias Kind = NativeTestWire.NamedType
    let wire = NativeTestWire()
    wire.header(width: 100, height: 100)
    wire.u8(Op.dataLong).int(710).int(0x18B).int(Int(Int32(bitPattern: 0xCFE5_6800)))
      .named(710, Kind.long, "when")
    wire.u8(Op.floatList).int(711).int(2).float(1).float(2).named(711, Kind.floatArray, "series")
    wire.u8(Op.dataFloat).int(712).float(1).named(712, Kind.float, "scalar")
    wire.u8(Op.layoutRoot).int(1)
    wire.box(id: 10, size: 10)
    wire.u8(Op.containerEnd)
    return wire.data
  }

  /// float "foo" (id 600) and float "USER:foo" (id 601), both 1, and one 10×10 box: a host's
  /// "foo" addresses "USER:foo", the bare variable only the document writes.
  public static func bareAndUserFoo() -> Data {
    typealias Op = NativeSwiftWireOpcode
    let wire = NativeTestWire()
    wire.header(width: 100, height: 100)
    for (id, name) in [(600, "foo"), (601, "USER:foo")] {
      wire.u8(Op.dataFloat).int(id).float(1).named(id, NativeTestWire.NamedType.float, name)
    }
    wire.u8(Op.layoutRoot).int(1)
    wire.box(id: 10, size: 10)
    wire.u8(Op.containerEnd)
    return wire.data
  }

  /// ``label()`` with a haptic as a frame effect, so every frame, the first included, raises an
  /// event.
  public static func labelWithAFrameHaptic() -> Data {
    var data = label()
    // Before the root's closing CONTAINER_END, outside any action container.
    let end = data.removeLast()
    data.append(contentsOf: NativeTestWire().u8(NativeSwiftWireOpcode.hapticFeedback).int(1).data)
    data.append(end)
    return data
  }

  /// `count` 1×1 boxes, box `i` (id 1000+i) gone until the integer named "n<i>" says otherwise,
  /// and, `withLabel`, a text (``labelID``) reading the string named ``labelName``,
  /// ``labelInitial`` until set.
  public static func manyIntegers(count: Int, withLabel: Bool = false) -> Data {
    typealias Op = NativeSwiftWireOpcode
    let wire = NativeTestWire()
    wire.header(width: 200, height: 200)
    for index in 0..<count {
      wire.u8(Op.dataInt).int(5000 + index).int(NativeSwiftVisibility.gone)
        .named(5000 + index, NativeTestWire.NamedType.int, "n\(index)")
    }
    if withLabel {
      wire.u8(Op.dataText).int(labelVariableID).utf8(labelInitial)
        .named(labelVariableID, NativeTestWire.NamedType.string, labelName)
    }
    wire.u8(Op.layoutRoot).int(1)
    for index in 0..<count {
      wire.box(id: 1000 + index, size: 1, visibility: 5000 + index, content: 20000 + index)
    }
    if withLabel { wire.text(id: labelID, reading: labelVariableID) }
    wire.u8(Op.containerEnd)
    return wire.data
  }

  /// The side of ``textOnCircle(_:text:draws:alignment:placement:radius:warp:center:startAngle:definitions:names:)``.
  public static let textOnCircleSize = 240
  /// The centre of that document's circle, on both axes.
  public static let textOnCircleCenter: Float = 120
  /// The radius its glyphs sit on: the operation's radius plus its warp offset.
  public static let textOnCircleRadius: Float = 90
  /// Its warp offset: non-zero, so a renderer that ignored it would draw on the wrong ring.
  public static let textOnCircleWarp: Float = 10
  /// The angle its string is pinned at, in degrees: the top of the circle.
  public static let textOnCircleStartAngle: Float = -90
  /// Its string, its text id and its size.
  public static let textOnCircleText = "REMOTE COMPOSE"
  public static let textOnCircleTextID = 7
  public static let textOnCircleTextSize: Float = 18

  /// A float word: a literal, or a reference to float `id` in the form the Kotlin codec writes.
  public enum FloatWord {
    case literal(Float)
    case variable(Int)

    public var bits: Int {
      switch self {
      case .literal(let value): Int(Int32(bitPattern: value.bitPattern))
      case .variable(let id):
        Int(Int32(bitPattern: NativeTestWire.floatReferencePrefix | UInt32(id)))
      }
    }
  }

  /// What ``textOnCircle(_:text:draws:alignment:placement:radius:warp:center:startAngle:definitions:names:)``
  /// draws.
  public enum TextOnCircleScene {
    /// `RcTextOnCircleRenderTest.document(...)`: the string alone, opaque black.
    case label
    /// `RcTextOnCircleRenderTest.dial(withCurvedText = false)`: a grey stroked circle and no text.
    case dial
    /// `dial(withCurvedText = true)`: the dial with the string in blue on it.
    case labelledDial
  }

  /// The documents of the Kotlin player's `RcTextOnCircleRenderTest`, byte for byte: one
  /// `DrawTextOnCircle` of `text` (``textOnCircleText`` by default) at ``textOnCircleTextSize`` pt in a
  /// ``textOnCircleSize`` square canvas, as `scene` says; the plain label is drawn `draws` times. Every float field may be a variable;
  /// `definitions` are float constants `(id, value)` written first, and `names` declares some of
  /// them as named floats a host can write.
  public static func textOnCircle(
    _ scene: TextOnCircleScene = .label,
    text: String = textOnCircleText,
    draws: Int = 1,
    alignment: Int = NativeSwiftTextOnCircleAlignment.center,
    placement: Int = NativeSwiftTextOnCirclePlacement.outside,
    radius: FloatWord = .literal(textOnCircleRadius - textOnCircleWarp),
    warp: FloatWord = .literal(textOnCircleWarp),
    center: FloatWord = .literal(textOnCircleCenter),
    startAngle: FloatWord = .literal(textOnCircleStartAngle),
    definitions: [(id: Int, value: Float)] = [],
    names: [(id: Int, name: String)] = []
  ) -> Data {
    typealias Op = NativeSwiftWireOpcode
    typealias Key = NativeTestWire.PaintKey
    let wire = NativeTestWire()
    wire.header(width: textOnCircleSize, height: textOnCircleSize)
    for definition in definitions {
      wire.u8(Op.dataFloat).int(definition.id).float(definition.value)
    }
    for (id, name) in names { wire.named(id, NativeTestWire.NamedType.float, name) }
    wire.u8(Op.dataText).int(textOnCircleTextID).utf8(text)
    wire.u8(Op.layoutRoot).int(1)
    wire.u8(Op.layoutContent).int(2)
    wire.u8(Op.layoutCanvas).int(3).int(30)
    for opcode in [Op.modifierWidth, Op.modifierHeight] {
      wire.u8(opcode).int(NativeSwiftDimensionType.exact).float(Float(textOnCircleSize))
    }
    wire.u8(Op.canvasOperations)
    func paint(_ words: [Int]) {
      wire.u8(Op.paintValues).int(words.count)
      for word in words { wire.int(word) }
    }
    func drawTextOnCircle() {
      wire.u8(Op.drawTextOnCircle).int(textOnCircleTextID)
      for word in [center, center, radius, startAngle, warp] { wire.int(word.bits) }
      wire.u8(alignment).u8(placement)
    }
    let textSize = FloatWord.literal(textOnCircleTextSize).bits
    switch scene {
    case .label:
      paint([Key.textSize, textSize, Key.color, opaqueBlack])
      for _ in 0..<draws { drawTextOnCircle() }
    case .dial, .labelledDial:
      paint([
        NativeTestWire.styleWord(NativeTestWire.PaintStyle.stroke), Key.strokeWidth,
        FloatWord.literal(2).bits, Key.color, Int(Int32(bitPattern: 0xff9a_a0a6)),
      ])
      wire.u8(Op.drawCircle)
      for value in [textOnCircleCenter, textOnCircleCenter, textOnCircleRadius] {
        wire.float(value)
      }
      if scene == .labelledDial {
        paint([
          NativeTestWire.styleWord(NativeTestWire.PaintStyle.fill), Key.textSize, textSize,
          Key.color, Int(Int32(bitPattern: 0xff1a_73e8)),
        ])
        drawTextOnCircle()
      }
    }
    // Four opens above (root, content, the canvas layout and its operation block), so four ends.
    for _ in 0..<4 { wire.u8(Op.containerEnd) }
    return wire.data
  }
}

/// Writes `.rc` wire operations, big-endian, for the test documents.
public final class NativeTestWire {
  /// `PAINT_DATA` command keys the test documents write: values of the core's internal
  /// `NativeSwiftPaintCommand`. `NativeTestWireNamedTypeTests` keeps the copy equal to the core.
  public enum PaintKey {
    public static let textSize = 1
    public static let color = 4
    public static let strokeWidth = 5
    public static let style = 8
  }

  /// Paint styles: values of the core's internal `NativeSwiftPaintStyle`.
  public enum PaintStyle {
    public static let fill = 0
    public static let stroke = 1
  }

  /// A style command word: the key in the low half, the style in the high half.
  public static func styleWord(_ style: Int) -> Int { PaintKey.style | (style << 16) }

  /// The high bits of a NaN-boxed reference to a float variable, as the Kotlin codec writes it;
  /// the id goes in the low bits.
  public static let floatReferencePrefix: UInt32 = 0x7fc0_0000

  /// A named variable's wire type: every value of the core's `NativeSwiftNamedVariableType`,
  /// which is internal. `NativeTestWireNamedTypeTests` keeps the two equal.
  public enum NamedType {
    public static let string = 0
    public static let float = 1
    public static let color = 2
    public static let image = 3
    public static let int = 4
    public static let long = 5
    public static let floatArray = 6
  }

  public private(set) var data = Data()

  public init() {}

  @discardableResult
  public func u8(_ value: Int) -> Self {
    data.append(UInt8(truncatingIfNeeded: value))
    return self
  }

  @discardableResult
  public func int(_ value: Int) -> Self {
    let raw = UInt32(bitPattern: Int32(truncatingIfNeeded: value))
    for shift in [24, 16, 8, 0] { data.append(UInt8(truncatingIfNeeded: raw >> shift)) }
    return self
  }

  @discardableResult
  public func float(_ value: Float) -> Self { int(Int(Int32(bitPattern: value.bitPattern))) }

  /// A length-prefixed UTF-8 string.
  @discardableResult
  public func utf8(_ value: String) -> Self {
    let bytes = Array(value.utf8)
    int(bytes.count)
    data.append(contentsOf: bytes)
    return self
  }

  /// The version-1 header for a `width`×`height` document.
  public func header(width: Int, height: Int) {
    u8(NativeSwiftWireOpcode.header)
    for value in [1, 0, 0, width, height, 0, 0] { int(value) }
  }

  /// Declares the variable `id` as the named variable `name` of wire type `type`.
  @discardableResult
  public func named(_ id: Int, _ type: Int, _ name: String) -> Self {
    u8(NativeSwiftWireOpcode.namedVariable).int(id).int(type).utf8(name)
  }

  /// A text component `id` reading the string variable `textID`, 16 pt, opaque black, then its
  /// container end. TextLayout: component, animation, text, colour, size, style, weight, family,
  /// alignment, overflow, maximum lines.
  public func text(id: Int, reading textID: Int) {
    u8(NativeSwiftWireOpcode.layoutText).int(id).int(0).int(textID)
      .int(NativeTestDocuments.opaqueBlack)
    float(16).int(0).float(400).int(-1).int(1).int(1).int(1)
    u8(NativeSwiftWireOpcode.containerEnd)
  }

  /// A `size`×`size` box with empty content (component `content`, `id + 100` by default), its
  /// visibility read from the integer `visibility` when given.
  public func box(id: Int, size: Float, visibility: Int? = nil, content: Int? = nil) {
    typealias Op = NativeSwiftWireOpcode
    u8(Op.layoutBox).int(id).int(-1).int(1).int(1)
    for opcode in [Op.modifierWidth, Op.modifierHeight] {
      u8(opcode).int(NativeSwiftDimensionType.exact).float(size)
    }
    if let visibility { u8(Op.modifierVisibility).int(visibility) }
    u8(Op.layoutContent).int(content ?? id + 100)
    u8(Op.containerEnd)
    u8(Op.containerEnd)
  }
}
