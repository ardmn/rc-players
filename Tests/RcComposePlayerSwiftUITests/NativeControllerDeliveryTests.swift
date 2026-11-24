#if canImport(UIKit)
  import Foundation
  import RcNativePlayerCore
  import Testing
  import RcNativePlayerTestDocuments
  import UIKit

  @testable import RcComposePlayerSwiftUI
  @_spi(RemoteComposeController) @testable import RcNativePlayerUIKit

  /// A controller write that returned `true` reaches the screen of the real native player, whatever
  /// the scene and the session do in between: the background, a write queued as the scene leaves,
  /// a session reopened for a new density, and a first open that failed.
  @MainActor @Suite struct NativeControllerDeliveryTests {
    private static let visible = NativeSwiftVisibility.visible

    private struct Player {
      let controller: RemoteComposePlayerController
      let host: RemoteComposePlayerViewController
      let view: RemoteComposeNativePlayerView
    }

    private func player() async throws -> Player {
      let controller = RemoteComposePlayerController()
      let host = RemoteComposePlayerViewController(
        data: NativeTestDocuments.shownBox(), controller: controller, resourceResolver: nil)
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
          let box = component.descendant(withID: NativeTestDocuments.boxID)
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

    /// The scene leaves while the write is queued behind other input the session is applying, so
    /// the queue is abandoned and the session is reopened from the bytes on activation; the write
    /// still lands. (A write that is itself in flight as the scene leaves is answered `.deferred`
    /// in the same way — `NativeInputDeferralTests` covers that answer.)
    @Test func aWriteQueuedAsTheSceneLeavesIsShownAfterIt() async throws {
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

    /// The player's first open fails, so a write the controller accepted is refused by the
    /// player; once a later open succeeds, the write is shown.
    @Test func aWriteRefusedByAFailedFirstOpenIsShownOnceAnOpenSucceeds() async throws {
      let controller = RemoteComposePlayerController()
      let host = RemoteComposePlayerViewController(
        data: NativeTestDocuments.shownBox(), controller: controller, resourceResolver: nil)
      host.loadViewIfNeeded()
      let native = try #require(host.children.first as? RemoteComposeNativePlayerViewController)
      // Invalid limits fail the open before it starts; the declarations are still read.
      var invalid = RemoteComposeNativeExecutionLimits.default
      invalid.maximumFrameWork = 0
      native.playerView.configureExecutionLimits(invalid)
      #expect(!native.isOpeningDocument)
      #expect(await eventually { !controller.names.isEmpty })
      #expect(controller.setInteger(Self.visible, for: "shown"))
      try await Task.sleep(nanoseconds: 200_000_000)
      #expect(isBoxShown(in: native.playerView) == nil)

      native.playerView.configureExecutionLimits(.default)
      #expect(await eventually { !native.isOpeningDocument })
      #expect(await eventually { isBoxShown(in: native.playerView) == true })
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
