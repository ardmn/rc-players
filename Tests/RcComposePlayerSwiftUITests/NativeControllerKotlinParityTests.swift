import Foundation
import RcNativePlayerTestDocuments
import Testing

@testable import RcComposePlayerSwiftUI
@testable @_spi(Conformance) @_spi(RemoteComposeController) import RcNativePlayerCore
@_spi(RemoteComposeController) @testable import RcNativePlayerUIKit

/// The iOS Kotlin controller's tests (`RcComposeViewControllerTest`), replayed against the native
/// fallback's controller: the same document, names and expected outcome.
@MainActor
@Suite struct NativeControllerKotlinParityTests {
  private typealias Named = NativeTestWire.NamedType

  private static func document() -> Data {
    let wire = NativeTestWire()
    wire.header(width: 10, height: 10)
    for (id, name) in declaredNames.sorted(by: { $0.key < $1.key }) {
      wire.u8(NativeSwiftWireOpcode.dataInt).int(id).int(Self.documentValue)
      wire.named(id, Named.int, name)
    }
    wire.u8(NativeSwiftWireOpcode.layoutRoot).int(1).u8(NativeSwiftWireOpcode.containerEnd)
    return wire.data
  }

  private static let declaredNames = [
    60: "USER:both", 61: "both", 62: "light.is_on", 63: "USER:count",
  ]
  /// What the document declares each variable as: neither 0 nor 1, so a boolean write of either
  /// shows.
  private static let documentValue = 7

  /// The id holding `sentinel`, if exactly one does.
  private static func landedOn(_ session: NativeSwiftDocumentSession, _ sentinel: Int) throws
    -> Int?
  {
    let integers = try session.probeValues(timeSeconds: 0).integers
    let hits = declaredNames.keys.filter { integers[$0] == sentinel }
    return hits.count == 1 ? hits[0] : nil
  }

  /// `RcComposeViewControllerTest.appleControllerResolvesNamesAsTheRuntimeDoes`: each name is
  /// written once through the controller and once straight into a session; both must land on the
  /// same variable (or none), and the controller must store the value under that variable's
  /// declared name.
  @Test func theControllerResolvesNamesAsTheSessionDoes() throws {
    let data = Self.document()
    let declarations = try NativeSwiftNamedVariableDeclarations.declared(in: data)
    let sentinel = 42
    let names = [
      "both", "USER:both", "light.is_on", "USER:light.is_on", "count", "USER:count", "missing",
      "theme:missing",
    ]
    for name in names {
      let runtime = try NativeSwiftDocumentSession.open(data: data, toleratingRootlessData: true)
      _ = runtime.setInteger(sentinel, for: name)
      let expected = try Self.landedOn(runtime, sentinel)

      let controller = RemoteComposePlayerController()
      controller.backend.attach(declarations)
      let accepted = controller.setInteger(sentinel, for: name)
      var stored: [String: ControllerNamedValue] = [:]
      controller.backend.installUpdateHandler { stored[$0] = $1 }
      let replayed = try NativeSwiftDocumentSession.open(data: data, toleratingRootlessData: true)
      for (key, value) in stored {
        replayed.restoreNamedValue(value.nativeValue.coreValue, forDeclaredName: key)
      }
      let actual = try Self.landedOn(replayed, sentinel)

      #expect(accepted == (expected != nil), "accepted '\(name)'")
      #expect(actual == expected, "variable '\(name)' addresses")
      #expect(
        Set(stored.keys) == Set(expected.map { [Self.declaredNames[$0]!] } ?? []),
        "key '\(name)' is stored under")
    }
    // The cases the comparison relies on, spelled out.
    let both = try NativeSwiftDocumentSession.open(data: data, toleratingRootlessData: true)
    _ = both.setInteger(sentinel, for: "both")
    #expect(try Self.landedOn(both, sentinel) == 60)
    let bare = try NativeSwiftDocumentSession.open(data: data, toleratingRootlessData: true)
    _ = bare.setInteger(sentinel, for: "light.is_on")
    #expect(try Self.landedOn(bare, sentinel) == 62)
  }

  /// `RcComposeViewControllerTest.appleControllerDrivesIntegerAndBooleanVariablesIntoTheDocument`
  /// (the part the existing controller tests do not cover): a boolean written to a name declared
  /// without a namespace is stored under that bare name and reaches the document as 1, then 0.
  @Test func aBooleanReachesABareDeclaredIntegerAsOneOrZero() throws {
    let data = Self.document()
    let controller = RemoteComposePlayerController()
    controller.backend.attach(try NativeSwiftNamedVariableDeclarations.declared(in: data))
    var stored: [String: ControllerNamedValue] = [:]
    controller.backend.installUpdateHandler { stored[$0] = $1 }

    for (value, expected) in [(true, 1), (false, 0)] {
      #expect(controller.setBoolean(value, for: "light.is_on"))
      #expect(Array(stored.keys) == ["light.is_on"])
      let session = try NativeSwiftDocumentSession.open(data: data, toleratingRootlessData: true)
      for (key, value) in stored {
        #expect(session.restoreNamedValue(value.nativeValue.coreValue, forDeclaredName: key))
      }
      #expect(try session.probeValues(timeSeconds: 0).integers[62] == expected)
    }
  }
}
