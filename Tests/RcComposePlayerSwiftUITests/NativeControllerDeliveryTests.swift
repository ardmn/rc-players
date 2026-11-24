#if canImport(UIKit)
  import Foundation
  import RcNativePlayerCore
  import Testing
  import UIKit

  @testable import RcComposePlayerSwiftUI
  @_spi(RemoteComposeController) @testable import RcNativePlayerUIKit

  /// A controller write that returned `true` reaches the screen of the real native player, whatever
  /// the scene and the session do in between: the background, a write in flight as the scene leaves,
  /// and a session reopened for a new density.
  @MainActor @Suite struct NativeControllerDeliveryTests {
    private typealias Op = NativeSwiftWireOpcode
    private static let boxID = 10
    private static let shownID = 550
    private static let visible = NativeSwiftVisibility.visible

    /// A 200×200 document whose 50×50 box is gone until the integer named "shown" says otherwise.
    private static func document() -> Data {
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
      int(4)  // NativeSwiftNamedVariableType.int
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

    private struct Player {
      let controller: RemoteComposePlayerController
      let host: RemoteComposePlayerViewController
      let view: RemoteComposeNativePlayerView
    }

    private func player() async throws -> Player {
      let controller = RemoteComposePlayerController()
      let host = RemoteComposePlayerViewController(
        data: Self.document(), controller: controller, resourceResolver: nil)
      host.loadViewIfNeeded()
      let native = try #require(host.children.first as? RemoteComposeNativePlayerViewController)
      let opened = await eventually { !controller.names.isEmpty && !native.isOpeningDocument }
      try #require(opened)
      return Player(controller: controller, host: host, view: native.playerView)
    }

    /// Whether the document's box is on screen, or nil before the document has a view.
    private func isBoxShown(in view: UIView) -> Bool? {
      var pending: [UIView] = [view]
      while !pending.isEmpty {
        let next = pending.removeFirst()
        if let component = next as? NativeComponentView,
          let box = component.descendant(withID: Self.boxID)
        {
          return !box.isHidden
        }
        pending.append(contentsOf: next.subviews)
      }
      return nil
    }

    private func eventually(
      within seconds: TimeInterval = 5, _ condition: () -> Bool
    ) async -> Bool {
      let deadline = Date().addingTimeInterval(seconds)
      while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
      }
      return condition()
    }

    private func moveToBackground(_ view: RemoteComposeNativePlayerView) {
      view.perform(NSSelectorFromString("sceneDidEnterBackground"))
    }

    private func activate(_ view: RemoteComposeNativePlayerView) {
      view.perform(NSSelectorFromString("sceneDidActivate"))
    }

    /// Longer in the background than the 2.5 s the controller used to retry for.
    @Test func aWriteInTheBackgroundIsShownOnceTheSceneIsActive() async throws {
      let player = try await player()
      #expect(isBoxShown(in: player.view) == false)
      moveToBackground(player.view)
      #expect(player.controller.setInteger(Self.visible, for: "shown"))
      try await Task.sleep(nanoseconds: 3_000_000_000)
      #expect(isBoxShown(in: player.view) == false)

      activate(player.view)
      #expect(await eventually { isBoxShown(in: player.view) == true })
    }

    /// The scene leaves while the session is working through input — the write in flight or
    /// queued behind other input — so the session is reopened from the bytes on activation, and
    /// the write still lands.
    @Test func aWriteTheSessionIsWorkingOnAsTheSceneLeavesIsShownAfterIt() async throws {
      let player = try await player()
      for _ in 0..<50 {
        Task { @MainActor in
          _ = await player.view.submit(.integer(NativeSwiftVisibility.gone), for: "shown")
        }
      }
      #expect(player.controller.setInteger(Self.visible, for: "shown"))
      for _ in 0..<10_000 where !player.view.isApplyingInput { await Task.yield() }
      try #require(player.view.isApplyingInput)
      moveToBackground(player.view)
      #expect(player.view.isOpeningDocument, "the bytes are reopened on activation")
      activate(player.view)
      #expect(await eventually { !player.view.isOpeningDocument })
      #expect(await eventually { isBoxShown(in: player.view) == true })
    }

    /// A value already on screen survives the reopen that follows the scene leaving while the
    /// session is busy with other input.
    @Test func aShownValueSurvivesTheReopenAfterTheBackground() async throws {
      let player = try await player()
      #expect(player.controller.setInteger(Self.visible, for: "shown"))
      #expect(await eventually { isBoxShown(in: player.view) == true })

      for _ in 0..<50 {
        Task { @MainActor in _ = await player.view.submit(.integer(1), for: "missing") }
      }
      for _ in 0..<10_000 where !player.view.isApplyingInput { await Task.yield() }
      try #require(player.view.isApplyingInput)
      moveToBackground(player.view)
      #expect(player.view.isOpeningDocument, "the bytes are reopened on activation")
      activate(player.view)
      #expect(await eventually { !player.view.isOpeningDocument })
      #expect(await eventually { isBoxShown(in: player.view) == true })
      try await Task.sleep(nanoseconds: 200_000_000)
      #expect(isBoxShown(in: player.view) == true)
    }

    /// A new density reopens the session from the bytes; the values written before survive it.
    @Test func aReopenForANewDensityKeepsTheValues() async throws {
      let player = try await player()
      #expect(player.controller.setInteger(Self.visible, for: "shown"))
      #expect(await eventually { isBoxShown(in: player.view) == true })

      player.view.configureHostDensity(2)
      #expect(player.view.isOpeningDocument)
      #expect(await eventually { !player.view.isOpeningDocument })
      #expect(await eventually { isBoxShown(in: player.view) == true })
      // Settled, not a frame that happened to land before the reopened session's own.
      try await Task.sleep(nanoseconds: 200_000_000)
      #expect(isBoxShown(in: player.view) == true)
    }
  }
#endif
