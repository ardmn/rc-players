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
  /// The UTF-8 bytes of text one frame may show, host-written strings included; each byte also
  /// counts one unit of `maximumFrameWork`. AndroidX takes a host string of any length
  /// (`AndroidRemoteContext.setNamedStringOverride`), so the default, 128 KiB, is well over
  /// anything a document shows by itself (a string is at most 4000 bytes on the wire, AndroidX
  /// `Limits.MAX_STRING_SIZE`, and a `TextMerge` 16K UTF-16 units) and still fits the default work
  /// budget; it refuses a document that repeats its text to stall the frame. A longer host string
  /// fails its frame, reported through `onError`, where AndroidX would show it.
  public var maximumTextBytes: Int
  /// The largest view or canvas side. The document's own size over it is refused; the UIKit
  /// player clamps a resolved exact width or height to it instead (`layoutDimension`).
  public var maximumCanvasDimension: Double
  /// The largest coordinate magnitude. The UIKit player clamps resolved layout and draw values to
  /// it rather than refusing the frame (`layoutCoordinate`, `drawCoordinate`); the AppKit policy
  /// still refuses a frame over it.
  public var maximumCoordinateMagnitude: Double
  public var maximumFrameWork: Int

  public init(
    maximumDocumentBytes: Int = 16 * 1024 * 1024,
    maximumNodeCount: Int = 20_000,
    maximumNestingDepth: Int = 256,
    maximumDrawCommandCount: Int = 50_000,
    maximumPathElementCount: Int = 100_000,
    maximumTextBytes: Int = 128 * 1024,
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

  /// A resolved layout float (a padding, spacing, offset, constraint or z-index) as UIKit can take
  /// it, whatever a host wrote: NaN reads 0, as Java's `(int)` and `Math.round` read it where the
  /// Kotlin player rounds a padding or offset, and the rest is held within
  /// ±`maximumCoordinateMagnitude`, so layout arithmetic stays finite and a `CALayer` never sees a
  /// NaN position. AndroidX takes the raw float (`PaddingModifierOperation.updateVariables`,
  /// `OffsetModifierOperation.updateVariables`), so a host's value must not fail the frame.
  func layoutCoordinate(_ value: Float) -> CGFloat {
    value.isNaN ? 0 : Self.clamped(CGFloat(value), to: maximumCoordinateMagnitude)
  }

  /// An exact width or height, held within ±`maximumCanvasDimension` so no view outgrows the
  /// largest canvas the player backs; NaN reads 0. Within a parent it is clamped to the parent's
  /// constraints anyway, as AndroidX's measure clamps it
  /// (`BaseModernMeasurePolicy.measure`: `Math.min(maxWidth, computeModifierDefinedWidth(..))`).
  /// Any other dimension type keeps NaN, which a fill reads as a bare `fillMaxWidth()`.
  func layoutDimension(_ value: Float, type: Int) -> CGFloat {
    switch type {
    case NativeSwiftDimensionType.exact, NativeSwiftDimensionType.exactDp:
      return value.isNaN ? 0 : Self.clamped(CGFloat(value), to: maximumCanvasDimension)
    default:
      return value.isNaN ? .nan : Self.clamped(CGFloat(value), to: maximumCoordinateMagnitude)
    }
  }

  /// A draw command's float within ±`maximumCoordinateMagnitude`. NaN is kept: it is a sentinel
  /// some commands carry (`unsetValueIndices`), and `isDrawable` already dropped a command whose
  /// geometry is non-finite.
  func drawCoordinate(_ value: Float) -> CGFloat {
    value.isNaN ? .nan : Self.clamped(CGFloat(value), to: maximumCoordinateMagnitude)
  }

  /// Whether a draw command's geometry, paint and path are all finite. AndroidX hands the raw
  /// floats to `Canvas` (`DrawRect.paint`: `context.drawRect(mX1, mY1, mX2, mY2)`), which draws
  /// nothing for a non-finite shape; the player drops such a command and draws the rest of the
  /// frame, rather than failing it.
  func isDrawable(_ command: NativeSwiftDrawCommandSnapshot) -> Bool {
    command.geometryValues.allSatisfy(\.isFinite) && command.strokeWidth.isFinite
      && command.alpha.isFinite && command.path.allSatisfy { $0.values.allSatisfy(\.isFinite) }
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
  case nonFiniteValue(componentID: Int, field: String)
  case coordinateTooLarge(componentID: Int, field: String, actual: Double, maximum: Double)
  case invalidDimensionValue(componentID: Int, field: String, actual: Double)
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
    let addedBytes = strings.compactMap { $0 }.reduce(0) { $0 + $1.utf8.count }
    textBytes += addedBytes
    work += addedBytes
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

  func validateNumbers(
    _ values: [Double], componentID: Int, field: String,
    limits: RemoteComposeNativeExecutionLimits
  ) throws {
    for value in values {
      guard value.isFinite else {
        throw RemoteComposeNativeLimitError.nonFiniteValue(
          componentID: componentID, field: field)
      }
      guard abs(value) <= limits.maximumCoordinateMagnitude else {
        throw RemoteComposeNativeLimitError.coordinateTooLarge(
          componentID: componentID, field: field, actual: value,
          maximum: limits.maximumCoordinateMagnitude)
      }
    }
  }

  func validateFinite(_ values: [Double], componentID: Int, field: String) throws {
    for value in values where !value.isFinite {
      throw RemoteComposeNativeLimitError.nonFiniteValue(
        componentID: componentID, field: field)
    }
  }

  func validateGradientStops(_ values: [Double], componentID: Int) throws {
    try validateFinite(values, componentID: componentID, field: "gradient stop")
    for value in values where !(0...1).contains(value) {
      throw RemoteComposeNativeLimitError.invalidGradientStop(
        componentID: componentID, actual: value)
    }
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

  func validateLayoutDimension(
    value: Double, type: Int, componentID: Int, field: String,
    limits: RemoteComposeNativeExecutionLimits
  ) throws {
    switch type {
    case NativeSwiftDimensionType.exact, NativeSwiftDimensionType.exactDp:
      // Any exact size renders: `layoutDimension(_:type:)` holds it within the canvas limit.
      break
    case NativeSwiftDimensionType.fill, NativeSwiftDimensionType.fillParentMaxWidth,
      NativeSwiftDimensionType.fillParentMaxHeight:
      if value.isNaN { return }
      guard value.isFinite, value >= 0 else {
        throw RemoteComposeNativeLimitError.invalidDimensionValue(
          componentID: componentID, field: field, actual: value)
      }
    case NativeSwiftDimensionType.weight:
      guard value.isFinite, value >= 0 else {
        throw RemoteComposeNativeLimitError.invalidDimensionValue(
          componentID: componentID, field: field, actual: value)
      }
    default:
      try validateFinite([value], componentID: componentID, field: field)
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
