#if canImport(UIKit)
  import Foundation
  import RcNativePlayerCore
  import Testing
  import UIKit

  @_spi(RemoteComposeController) @testable import RcNativePlayerUIKit

  /// How the native player answers a named-variable write it cannot take yet. A caller that has
  /// already promised the write — the SwiftUI controller — needs `.deferred` and a signal for when
  /// to offer it again, as distinct from `.refused`, the document's final answer.
  @MainActor @Suite struct NativeInputDeferralTests {
    private typealias Op = NativeSwiftWireOpcode
    private static let shownID = 550
    private static let visible = NativeSwiftVisibility.visible
    private static let gone = NativeSwiftVisibility.gone

    /// A 200×200 document whose 50×50 box is gone until the integer named "shown" says otherwise.
    static func document() -> Data {
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
      int(gone)
      let name = Array("shown".utf8)
      u8(Op.namedVariable)
      int(shownID)
      int(4)  // NativeSwiftNamedVariableType.int
      int(name.count)
      for byte in name { u8(Int(byte)) }
      u8(Op.layoutRoot)
      int(1)
      u8(Op.layoutBox)
      for value in [10, -1, 1, 1] { int(value) }
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

    private func openedView() async throws -> RemoteComposeNativePlayerView {
      var errors: [RemoteComposeNativePlayerError] = []
      let view = RemoteComposeNativePlayerView(
        data: Self.document(), resourceResolver: nil, onError: { errors.append($0) })
      for _ in 0..<1_000 where view.isOpeningDocument {
        try await Task.sleep(nanoseconds: 10_000_000)
      }
      try #require(!view.isOpeningDocument && errors.isEmpty, "\(errors)")
      return view
    }

    /// SwiftPM runs without a window scene, so the scene notifications are delivered directly.
    private func moveToBackground(_ view: RemoteComposeNativePlayerView) {
      view.perform(NSSelectorFromString("sceneDidEnterBackground"))
    }

    private func activate(_ view: RemoteComposeNativePlayerView) {
      view.perform(NSSelectorFromString("sceneDidActivate"))
    }

    @Test func aBackgroundSceneDefersInputAndSignalsWhenItIsActiveAgain() async throws {
      let view = try await openedView()
      moveToBackground(view)
      let mark = view.inputAvailability.mark
      #expect(await view.submit(.integer(Self.visible), for: "shown") == .deferred)
      // The public setter's answer is unchanged: the write was not applied.
      #expect(!(await view.setInteger(Self.visible, for: "shown")))
      #expect(view.inputAvailability.mark == mark)

      activate(view)
      #expect(view.inputAvailability.mark != mark)
      #expect(await view.submit(.integer(Self.visible), for: "shown") == .accepted)
    }

    /// A write beyond the queue's capacity is deferred, and the player signals as the queue drains.
    @Test func aFullQueueDefersInputAndSignalsAsItDrains() async throws {
      let view = try await openedView()
      let mark = view.inputAvailability.mark
      let writes = (0..<300).map { index in
        Task { @MainActor in
          await view.submit(.integer(index % 2 == 0 ? Self.visible : Self.gone), for: "shown")
        }
      }
      var answers: [RemoteComposeNativeInputAdmission] = []
      for write in writes { answers.append(await write.value) }
      #expect(answers.contains(.deferred))
      #expect(answers.contains(.accepted))
      #expect(!answers.contains(.refused))
      #expect(view.inputAvailability.mark != mark)
    }

    /// A write the session is applying as the scene goes to the background is lost with that
    /// session — the bytes are reopened on activation — so it is deferred, not accepted.
    @Test func anInputInFlightWhenTheSceneGoesToTheBackgroundIsDeferred() async throws {
      let view = try await openedView()
      // The write is in flight only while the engine applies it; a write that completes before the
      // test sees it in flight is simply tried again.
      for _ in 0..<50 {
        var answer: RemoteComposeNativeInputAdmission?
        Task { @MainActor in answer = await view.submit(.integer(Self.visible), for: "shown") }
        while answer == nil, !view.isApplyingInput { await Task.yield() }
        guard view.isApplyingInput else { continue }
        moveToBackground(view)
        while answer == nil { await Task.yield() }
        #expect(answer == .deferred)
        #expect(view.isOpeningDocument, "the bytes are reopened on activation")
        return
      }
      Issue.record("never saw the write in flight")
    }

    /// A write the document refuses is answered `.refused` once, even while other input is queued:
    /// it is final, not a reason to offer it again.
    @Test func aRefusalWhileInputIsQueuedIsFinal() async throws {
      let view = try await openedView()
      let busy = (0..<20).map { _ in
        Task { @MainActor in await view.submit(.integer(Self.visible), for: "shown") }
      }
      let refused = Task { @MainActor in await view.submit(.integer(1), for: "missing") }
      #expect(await refused.value == .refused)
      for write in busy { #expect(await write.value == .accepted) }
    }

    /// A waiter is released when the player goes away, so nothing waits for a scene that will
    /// never come back.
    @Test func theSignalOpensWhenThePlayerGoesAway() async throws {
      var view: RemoteComposeNativePlayerView? = try await openedView()
      let availability = try #require(view?.inputAvailability)
      let mark = availability.mark
      moveToBackground(try #require(view))
      view = nil
      // UIKit may hold the view in the current autorelease pool until the main queue turns over.
      for _ in 0..<100 where availability.mark == mark {
        try await Task.sleep(nanoseconds: 10_000_000)
      }
      #expect(availability.mark != mark)
      await availability.wait(after: mark)
    }
  }
#endif
