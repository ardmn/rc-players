import CoreGraphics
import Foundation
#if canImport(RcNativePlayerCore)
  import RcNativePlayerCore
#endif

/// Work limits applied before a native frame reaches UIKit or Core Graphics.
public struct RemoteComposeNativeExecutionLimits: Equatable, Sendable {
  public var maximumDocumentBytes: Int
  public var maximumNodeCount: Int
  public var maximumNestingDepth: Int
  public var maximumDrawCommandCount: Int
  public var maximumPathElementCount: Int
  /// The UTF-8 bytes of text one frame may lay out. A document's string counts at each place it is
  /// shown; a host's counts once, at most `longestDocumentTextBytes`, so it renders at any length.
  /// Every place a document string is shown costs its bytes of `maximumFrameWork`, and a host's up
  /// to `hostStringPlacementWork`, which bounds the layout work. The default holds four host
  /// strings of any length.
  public var maximumTextBytes: Int
  /// The largest view or canvas side. The document's own size over it is refused; the UIKit
  /// player clamps a resolved exact width or height to it instead (`layoutDimension`).
  public var maximumCanvasDimension: Double
  /// The largest coordinate magnitude: resolved layout values, and on UIKit draw coordinates, are
  /// clamped to it rather than refusing the frame; a transform's operands and angles are not.
  public var maximumCoordinateMagnitude: Double
  public var maximumFrameWork: Int

  public init(
    maximumDocumentBytes: Int = 16 * 1024 * 1024,
    maximumNodeCount: Int = 20_000,
    maximumNestingDepth: Int = 256,
    maximumDrawCommandCount: Int = 50_000,
    maximumPathElementCount: Int = 100_000,
    maximumTextBytes: Int = 4 * longestDocumentTextBytes,
    maximumCanvasDimension: Double = 16_384,
    maximumCoordinateMagnitude: Double = 1_000_000,
    maximumFrameWork: Int = 200_000
  ) {
    self.maximumDocumentBytes = maximumDocumentBytes
    self.maximumNodeCount = maximumNodeCount
    self.maximumNestingDepth = maximumNestingDepth
    self.maximumDrawCommandCount = maximumDrawCommandCount
    self.maximumPathElementCount = maximumPathElementCount
    self.maximumTextBytes = maximumTextBytes
    self.maximumCanvasDimension = maximumCanvasDimension
    self.maximumCoordinateMagnitude = maximumCoordinateMagnitude
    self.maximumFrameWork = maximumFrameWork
  }

  public static let `default` = RemoteComposeNativeExecutionLimits()

  /// The longest UTF-8 text a document can make itself: a `TextMerge` result of at most 16K UTF-16
  /// units (TextMerge.java:41), 3 bytes each. Any longer string is a host's.
  public static let longestDocumentTextBytes = 3 * 16 * 1024

  /// The work one place showing a host's string (or one longer than `longestDocumentTextBytes`)
  /// costs, at most: the default `maximumFrameWork` then lets a document lay such a string out in
  /// about 48 places per frame (the corpus's headphone card shows one in 17). The host chooses the
  /// string's length; the document only chooses how many times it is laid out, and this bounds
  /// that multiplier.
  public static let hostStringPlacementWork = 4 * 1024

  /// A resolved layout float (padding, spacing, offset, constraint, z-index) as UIKit can take it:
  /// NaN reads 0, as in Java's `(int)`; the rest is held to ±`maximumCoordinateMagnitude`.
  func layoutCoordinate(_ value: Float) -> CGFloat {
    value.isNaN ? 0 : Self.clamped(CGFloat(value), to: maximumCoordinateMagnitude)
  }

  /// An exact width or height held to ±`maximumCanvasDimension`, NaN as 0; a parent clamps it
  /// further, as AndroidX's `BaseModernMeasurePolicy.measure` does. Any other type keeps NaN,
  /// which a fill reads as a bare `fillMaxWidth()`.
  func layoutDimension(_ value: Float, type: Int) -> CGFloat {
    switch type {
    case NativeSwiftDimensionType.exact, NativeSwiftDimensionType.exactDp:
      return value.isNaN ? 0 : Self.clamped(CGFloat(value), to: maximumCanvasDimension)
    default:
      return value.isNaN ? .nan : Self.clamped(CGFloat(value), to: maximumCoordinateMagnitude)
    }
  }

  /// A draw command's float within ±`maximumCoordinateMagnitude`; NaN is kept, as some commands
  /// carry it as a sentinel (`unsetValueIndices`).
  func drawCoordinate(_ value: Float) -> CGFloat {
    value.isNaN ? .nan : Self.clamped(CGFloat(value), to: maximumCoordinateMagnitude)
  }

  /// A draw command's values as UIKit draws them: coordinates through `drawCoordinate`, and a
  /// transform's operands and an arc's angles as they are, since clamping one changes the drawing.
  func drawValues(of command: NativeSwiftDrawCommandSnapshot) -> [CGFloat] {
    switch command.kind {
    case NativeSwiftDrawKind.matrixTranslate, NativeSwiftDrawKind.matrixScale,
      NativeSwiftDrawKind.matrixRotate, NativeSwiftDrawKind.matrixSkew,
      NativeSwiftDrawKind.matrixFromPath:
      return command.values.map { CGFloat($0) }
    case NativeSwiftDrawKind.arc, NativeSwiftDrawKind.sector:
      return command.values.enumerated().map { index, value in
        Self.arcAngleIndices.contains(index) ? CGFloat(value) : drawCoordinate(value)
      }
    default:
      return command.values.map(drawCoordinate)
    }
  }

  /// `DrawArc` and `DrawSector`'s start and sweep angles, in degrees, after the oval's four
  /// edges (`[left, top, right, bottom, startAngle, sweepAngle]`).
  private static let arcAngleIndices = 4...5

  /// Whether a draw command's geometry, paint and path are all finite: Skia draws nothing for a
  /// non-finite shape (`SkCanvas::quickReject`). Only a stroke reads the stroke width.
  func isDrawable(_ command: NativeSwiftDrawCommandSnapshot) -> Bool {
    let geometryIsFinite = command.geometryValues.allSatisfy(\.isFinite)
    let strokeIsFinite = !command.isStroke || command.strokeWidth.isFinite
    let paintIsFinite = strokeIsFinite && command.alpha.isFinite
    return geometryIsFinite && paintIsFinite
      && command.path.allSatisfy { $0.values.allSatisfy(\.isFinite) }
  }

  private static func clamped(_ value: CGFloat, to bound: Double) -> CGFloat {
    min(max(value, -CGFloat(bound)), CGFloat(bound))
  }
}

public enum RemoteComposeNativeLimitError: Error, Equatable, LocalizedError, Sendable {
  case invalidLimits
  case documentTooLarge(actual: Int, maximum: Int)
  case tooManyNodes(actual: Int, maximum: Int)
  case nestingTooDeep(actual: Int, maximum: Int)
  case tooManyDrawCommands(actual: Int, maximum: Int)
  case tooManyPathElements(actual: Int, maximum: Int)
  case textTooLong(actual: Int, maximum: Int)
  case invalidCanvasDimension(actual: Double)
  case canvasTooLarge(actual: Double, maximum: Double)
  /// Thrown only for a non-finite canvas size; a resolved value is normalised or dropped instead.
  case nonFiniteValue(componentID: Int, field: String)
  /// Not thrown: resolved coordinates are clamped to `maximumCoordinateMagnitude`. Kept as public
  /// API.
  case coordinateTooLarge(componentID: Int, field: String, actual: Double, maximum: Double)
  /// Not thrown: every resolved width and height renders. Kept as public API.
  case invalidDimensionValue(componentID: Int, field: String, actual: Double)
  /// Not thrown. Kept as public API.
  case invalidGradientStop(componentID: Int, actual: Double)
  case frameWorkExceeded(actual: Int, maximum: Int)

  public var errorDescription: String? {
    switch self {
    case .invalidLimits: return "Native execution limits must be finite and positive"
    case .documentTooLarge(let actual, let maximum):
      return "Document is \(actual) bytes; the native limit is \(maximum)"
    case .tooManyNodes(let actual, let maximum):
      return "Native frame contains \(actual) nodes; the limit is \(maximum)"
    case .nestingTooDeep(let actual, let maximum):
      return "Native frame nesting is \(actual) levels; the limit is \(maximum)"
    case .tooManyDrawCommands(let actual, let maximum):
      return "Native frame contains \(actual) draw commands; the limit is \(maximum)"
    case .tooManyPathElements(let actual, let maximum):
      return "Native frame contains \(actual) path elements; the limit is \(maximum)"
    case .textTooLong(let actual, let maximum):
      return "Native frame text is \(actual) UTF-8 bytes; the limit is \(maximum)"
    case .invalidCanvasDimension(let actual):
      return "Native canvas dimension must be finite and positive; got \(actual)"
    case .canvasTooLarge(let actual, let maximum):
      return "Native canvas dimension is \(actual); the limit is \(maximum)"
    case .nonFiniteValue(let componentID, let field):
      return "Component \(componentID) has a non-finite \(field) value"
    case .coordinateTooLarge(let componentID, let field, let actual, let maximum):
      return "Component \(componentID) has \(field)=\(actual); the magnitude limit is \(maximum)"
    case .invalidDimensionValue(let componentID, let field, let actual):
      return "Component \(componentID) has invalid \(field)=\(actual)"
    case .invalidGradientStop(let componentID, let actual):
      return "Component \(componentID) has gradient stop \(actual); stops must be between 0 and 1"
    case .frameWorkExceeded(let actual, let maximum):
      return "Native frame requires \(actual) work units; the limit is \(maximum)"
    }
  }
}

struct NativeFrameBudget: Equatable, Sendable {
  private(set) var nodes = 0
  private(set) var drawCommands = 0
  private(set) var pathElements = 0
  private(set) var textBytes = 0
  private(set) var work = 0
  /// The frame's host strings (`NativeSwiftDocumentSnapshot.hostStrings`).
  let hostStrings: Set<String>
  /// The host strings, and strings longer than a document can make, counted in `textBytes` so far.
  private var countedHostStrings: Set<String> = []

  init(hostStrings: Set<String> = []) {
    self.hostStrings = hostStrings
  }

  static func validate(_ limits: RemoteComposeNativeExecutionLimits) throws {
    guard
      limits.maximumDocumentBytes > 0,
      limits.maximumNodeCount > 0,
      limits.maximumNestingDepth > 0,
      limits.maximumDrawCommandCount > 0,
      limits.maximumPathElementCount > 0,
      limits.maximumTextBytes > 0,
      limits.maximumCanvasDimension.isFinite,
      limits.maximumCanvasDimension > 0,
      limits.maximumCoordinateMagnitude.isFinite,
      limits.maximumCoordinateMagnitude > 0,
      limits.maximumFrameWork > 0
    else { throw RemoteComposeNativeLimitError.invalidLimits }
  }

  mutating func recordNode(
    depth: Int, limits: RemoteComposeNativeExecutionLimits
  ) throws {
    nodes += 1
    work += 1
    guard nodes <= limits.maximumNodeCount else {
      throw RemoteComposeNativeLimitError.tooManyNodes(
        actual: nodes, maximum: limits.maximumNodeCount)
    }
    guard depth <= limits.maximumNestingDepth else {
      throw RemoteComposeNativeLimitError.nestingTooDeep(
        actual: depth, maximum: limits.maximumNestingDepth)
    }
    try validateWork(limits)
  }

  mutating func recordCommand(
    pathElementCount: Int, additionalWork: Int = 0, strings: [String?] = [],
    limits: RemoteComposeNativeExecutionLimits
  ) throws {
    drawCommands += 1
    pathElements += pathElementCount
    work += 1 + pathElementCount + additionalWork
    guard drawCommands <= limits.maximumDrawCommandCount else {
      throw RemoteComposeNativeLimitError.tooManyDrawCommands(
        actual: drawCommands, maximum: limits.maximumDrawCommandCount)
    }
    guard pathElements <= limits.maximumPathElementCount else {
      throw RemoteComposeNativeLimitError.tooManyPathElements(
        actual: pathElements, maximum: limits.maximumPathElementCount)
    }
    try recordStrings(strings, limits: limits)
    try validateWork(limits)
  }

  mutating func recordStrings(
    _ strings: [String?], limits: RemoteComposeNativeExecutionLimits
  ) throws {
    let longest = RemoteComposeNativeExecutionLimits.longestDocumentTextBytes
    var addedBytes = 0
    var addedWork = 0
    // The strings of one place (a node's text and the accessibility copies of it) lay out once.
    var chargedHereStrings: Set<String> = []
    for string in strings.compactMap({ $0 }) {
      let bytes = string.utf8.count
      // A host's string counts once in the text, at most `longest`, and each place it is shown
      // costs up to `hostStringPlacementWork`, so a document can lay one out in a few places per
      // frame, not thousands. The lookups hash it, O(length).
      if bytes > longest || hostStrings.contains(string) {
        if countedHostStrings.insert(string).inserted { addedBytes += min(bytes, longest) }
        if chargedHereStrings.insert(string).inserted {
          addedWork += min(bytes, RemoteComposeNativeExecutionLimits.hostStringPlacementWork)
        }
      } else {
        addedBytes += bytes
        addedWork += bytes
      }
    }
    textBytes += addedBytes
    work += addedWork
    guard textBytes <= limits.maximumTextBytes else {
      throw RemoteComposeNativeLimitError.textTooLong(
        actual: textBytes, maximum: limits.maximumTextBytes)
    }
    try validateWork(limits)
  }

  mutating func recordEvent(
    additionalWork: Int = 0, strings: [String?] = [],
    limits: RemoteComposeNativeExecutionLimits
  ) throws {
    work += 1 + additionalWork
    try recordStrings(strings, limits: limits)
    try validateWork(limits)
  }

  mutating func recordWork(
    _ additionalWork: Int, limits: RemoteComposeNativeExecutionLimits
  ) throws {
    work += additionalWork
    try validateWork(limits)
  }

  func validateCanvasDimensions(
    _ values: [Double], limits: RemoteComposeNativeExecutionLimits
  ) throws {
    for value in values {
      guard value.isFinite else {
        throw RemoteComposeNativeLimitError.nonFiniteValue(componentID: 0, field: "canvas")
      }
      guard value >= 0, value <= limits.maximumCanvasDimension else {
        throw RemoteComposeNativeLimitError.canvasTooLarge(
          actual: value, maximum: limits.maximumCanvasDimension)
      }
    }
  }

  func validateDocumentDimensions(
    _ values: [Double], limits: RemoteComposeNativeExecutionLimits
  ) throws {
    for value in values {
      guard value.isFinite, value > 0 else {
        throw RemoteComposeNativeLimitError.invalidCanvasDimension(actual: value)
      }
    }
    try validateCanvasDimensions(values, limits: limits)
  }

  private func validateWork(_ limits: RemoteComposeNativeExecutionLimits) throws {
    guard work <= limits.maximumFrameWork else {
      throw RemoteComposeNativeLimitError.frameWorkExceeded(
        actual: work, maximum: limits.maximumFrameWork)
    }
  }
}
