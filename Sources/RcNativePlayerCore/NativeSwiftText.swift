import Foundation

struct ParsedTextFromFloat {
  let outputID: Int
  let value: UInt32
  let digitsBefore: Int
  let digitsAfter: Int
  let flags: Int
}

struct ParsedTextMerge {
  let outputID: Int
  let leftID: Int
  let rightID: Int
}

struct ParsedTextLookupInt {
  let outputID: Int
  let listID: Int
  let indexID: Int
}

struct ParsedTextLookup {
  let outputID: Int
  let listID: Int
  let index: UInt32
}

struct ParsedTextTransform {
  let outputID: Int
  let textID: Int
  let start: UInt32
  let length: UInt32
  let operation: Int
}

enum ParsedTextOperation {
  case fromFloat(ParsedTextFromFloat)
  case merge(ParsedTextMerge)
  case lookupInt(ParsedTextLookupInt)
  case lookup(ParsedTextLookup)
  case transform(ParsedTextTransform)
  /// `TEXT_SUBTEXT`: a slice by UTF-16 offset, where a length of -1 means "to the end".
  case subtext(ParsedTextTransform)

  /// The text the operation writes.
  var outputID: Int {
    switch self {
    case .fromFloat(let conversion): conversion.outputID
    case .merge(let merge): merge.outputID
    case .lookupInt(let lookup): lookup.outputID
    case .lookup(let lookup): lookup.outputID
    case .transform(let transform), .subtext(let transform): transform.outputID
    }
  }

  /// The text operations an action can run again (`RcPlayerState.textProducers`): a text written
  /// by exactly one operation, which does not read its own output, from texts that are constant or
  /// qualify themselves. Any other text is sent as the last frame left it. Settled once per
  /// document in O(text operations + their inputs), with an explicit stack rather than recursion,
  /// as a document can chain texts as deep as its length allows.
  static func producers(
    of operations: [ParsedTextOperation], idLists: [Int: [Int]]
  ) -> [Int: ParsedTextOperation] {
    var producers: [Int: [ParsedTextOperation]] = [:]
    for operation in operations { producers[operation.outputID, default: []].append(operation) }
    var qualifies: [Int: Bool] = [:]
    for root in producers.keys where qualifies[root] == nil {
      // Each frame is an id and whether its inputs have been pushed; a grey id on the path is a
      // cycle, which disqualifies every id on it.
      var stack: [(id: Int, expanded: Bool)] = [(root, false)]
      var onPath: Set<Int> = []
      while let (id, expanded) = stack.popLast() {
        guard let written = producers[id] else {
          qualifies[id] = true
          continue
        }
        if qualifies[id] != nil { continue }
        guard written.count == 1, let operation = written.first else {
          qualifies[id] = false
          continue
        }
        let inputs = operation.textInputs(idLists: idLists)
        if expanded {
          onPath.remove(id)
          qualifies[id] = inputs.allSatisfy { $0 != id && qualifies[$0] == true }
          continue
        }
        if onPath.contains(id) || inputs.contains(id) {
          qualifies[id] = false
          continue
        }
        onPath.insert(id)
        stack.append((id, true))
        for input in inputs where qualifies[input] == nil {
          if onPath.contains(input) {
            qualifies[input] = false
          } else {
            stack.append((input, false))
          }
        }
      }
    }
    var result: [Int: ParsedTextOperation] = [:]
    for (id, written) in producers where qualifies[id] == true { result[id] = written.first }
    return result
  }

  /// The texts the operation reads (`RcPlayerState.textInputs`): a lookup reads every text its
  /// list names, as any of them may be the one picked.
  func textInputs(idLists: [Int: [Int]]) -> [Int] {
    switch self {
    case .fromFloat: []
    case .merge(let merge): [merge.leftID, merge.rightID]
    case .lookupInt(let lookup): idLists[lookup.listID] ?? []
    case .lookup(let lookup): idLists[lookup.listID] ?? []
    case .transform(let transform), .subtext(let transform): [transform.textID]
    }
  }
}

/// `ID_LOOKUP`: the id at a (computed) index of an id list, published as an integer.
struct ParsedIdLookup {
  let outputID: Int
  let listID: Int
  let index: UInt32
}

/// A float the host-independent text attributes publish: `TEXT_LENGTH`, and `ATTRIBUTE_TEXT`'s
/// length selector. The bounds selectors need the host's text metrics and are not in this list.
struct ParsedTextLength {
  let outputID: Int
  let textID: Int
}

/// `TEXT_STYLE` and `CoreText`'s shared sparse property vocabulary, as decoded.
struct ParsedTextProperties {
  var integers: [Int: Int] = [:]
  var floats: [Int: UInt32] = [:]
  /// The font-axis arrays, by property: tag text ids for `fontAxis`, float words for
  /// `fontAxisValues`. A style's array replaces its parent's whole, as AndroidX's does.
  var arrays: [Int: [Int]] = [:]
}

struct ParsedText {
  let textID: Int
  let colorARGB: UInt32
  let colorID: Int?
  let sizeWord: UInt32
  let style: Int
  let weightWord: UInt32
  let familyID: Int
  let alignment: NativeSwiftTextAlignment
  let overflow: Int
  let maximumLines: Int
  /// `CoreText`'s autosize flag and the font-size range it searches, as float words so a variable
  /// resolves with the frame's values. Nil when the component does not autosize.
  var autosize: (minimumWord: UInt32?, maximumWord: UInt32?)? = nil
  /// `CoreText`'s font settings: the text ids of the tags and, index for index, the float words of
  /// their values. Remote Compose writes variation axes and layout features into this one list;
  /// `NativeSwiftFontSettings` tells them apart.
  var fontSettingTagIDs: [Int] = []
  var fontSettingValueWords: [UInt32] = []
}
