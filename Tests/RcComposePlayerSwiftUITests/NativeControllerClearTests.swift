#if canImport(UIKit)
  import Foundation
  import RcNativePlayerCore
  import Testing
  import RcNativePlayerTestDocuments
  import UIKit

  @testable import RcComposePlayerSwiftUI
  @_spi(RemoteComposeController) @testable import RcNativePlayerUIKit

  /// `RemoteComposePlayerController.clear(_:)`, `setLong` and `setFloatArray` through the SwiftUI
  /// native fallback to what the player shows, across the transitions the controller suites
  /// drive. The Kotlin reference is `RcNamedValueRenderTest` :89 (removing a named value drives the
  /// live document back) with `RcComposePlayerController.clear`.
  @MainActor @Suite(.serialized)
  struct NativeControllerClearTests: NativeControllerSuite {
    /// Set, then clear: the view shows the host's value, then the document's again.
    @Test func aClearDrivesTheViewBackToTheDocumentsValue() async throws {
      let player = try await player()
      #expect(player.controller.setInteger(Self.visible, for: "shown"))
      #expect(player.controller.setString("Host", for: "label"))
      try await settle(player)
      try #require(isShown(Self.shownBox, in: player.view) == true)
      try #require(text(NativeTestDocuments.labelID, in: player.view) == "Host")

      #expect(player.controller.clear("shown"))
      #expect(player.controller.clear("label"))
      try await settle(player)

      #expect(isShown(Self.shownBox, in: player.view) == false)
      #expect(text(NativeTestDocuments.labelID, in: player.view) == "Idle")
    }

    /// The Kotlin player diffs the host's values, so the value written before the clear is a change
    /// again after it — even though the controller had answered it before.
    @Test func theSameValueWrittenAfterAClearIsShownAgain() async throws {
      let player = try await player()
      #expect(player.controller.setInteger(Self.visible, for: "shown"))
      try await settle(player)
      #expect(player.controller.clear("shown"))
      try await settle(player)
      try #require(isShown(Self.shownBox, in: player.view) == false)

      #expect(player.controller.setInteger(Self.visible, for: "shown"))
      try await settle(player)

      #expect(isShown(Self.shownBox, in: player.view) == true)
    }

    /// Undeclared names are refused; a declared name nobody set is accepted and changes nothing,
    /// including a value the document changed itself.
    @Test func aClearOfAnUndeclaredOrUnsetName() async throws {
      let detached = RemoteComposePlayerController()
      #expect(!detached.clear("shown"), "before a document is attached")
      let player = try await player()
      #expect(!player.controller.clear("missing"))
      try await setLocally(player, Self.visible, for: "local")

      #expect(player.controller.clear("local"))
      #expect(player.host.nativeUpdateTasks.isEmpty, "a clear with nothing to clear was delivered")
      try await settle(player)
      #expect(isShown(Self.localBox, in: player.view) == true, "the document's own value was reset")
    }

    /// A clear the session took is not undone by a reopen: the reopened session does not carry the
    /// cleared value, and the seed does not bring it back.
    @Test func aClearedValueStaysClearedAcrossAReopen() async throws {
      let player = try await player()
      #expect(player.controller.setInteger(Self.visible, for: "shown"))
      try await settle(player)
      #expect(player.controller.clear("shown"))
      try await settle(player)
      try #require(isShown(Self.shownBox, in: player.view) == false)

      try await backgroundWithInputQueued(player)
      activate(player)
      try await settle(player)

      #expect(isShown(Self.shownBox, in: player.view) == false, "the cleared value came back")
    }

    /// A clear made while the scene is in the background cannot reach the session yet; the reopen
    /// on the foreground starts from the document's value, so even its first frame does not show
    /// the cleared value.
    @Test func aClearInTheBackgroundIsShownFromTheReopensFirstFrame() async throws {
      let player = try await player()
      #expect(player.controller.setInteger(Self.visible, for: "shown"))
      try await settle(player)
      try #require(isShown(Self.shownBox, in: player.view) == true)

      background(player)
      #expect(player.controller.clear("shown"))
      // Configured while in the background, the reopen waits for the foreground.
      player.view.configureHostDensity(2)
      var firstFrames: [Bool?] = []
      let view = player.view
      view.onSessionOpened = { [unowned view] in
        firstFrames.append(isShown(Self.shownBox, in: view))
      }
      activate(player)
      try await settle(player)

      #expect(firstFrames == [false], "first frame after the reopen: \(firstFrames)")
      #expect(isShown(Self.shownBox, in: player.view) == false)
    }

    /// Pre-existing (see `aControllerSharedByTwoPlayersStillReachesOnlyTheLastOne`): the backend
    /// holds one update handler, so a clear, like a write, reaches only the last player attached.
    @Test func aClearOnASharedControllerReachesTheLastPlayer() async throws {
      let controller = RemoteComposePlayerController()
      let a = try await player(controller: controller)
      let b = try await player(controller: controller)
      #expect(controller.setInteger(Self.visible, for: "shown"))
      try await settle(b)
      try #require(isShown(Self.shownBox, in: b.view) == true)

      #expect(controller.clear("shown"))
      try await settle(a)
      try await settle(b)

      #expect(isShown(Self.shownBox, in: b.view) == false)
      #expect(isShown(Self.shownBox, in: a.view) == false, "the first player never had the value")
    }

    /// Long and float-array writes reach the session as the controller typed them.
    @Test func longAndFloatArrayWritesReachTheSession() async throws {
      let player = try await player(data: NativeTestDocuments.longAndFloatArray())
      var applied: [String] = []
      player.view.onInputApplied = { input in
        switch input {
        case .setNamed(let name, .long(1_700_000_001_000)): applied.append(name)
        case .setNamed(let name, .floatArray([3, 4])): applied.append(name)
        case .clearNamed(let name): applied.append("clear \(name)")
        default: break
        }
      }
      #expect(player.controller.setLong(1_700_000_001_000, for: "when"))
      #expect(player.controller.setFloatArray([3, 4], for: "series"))
      #expect(!player.controller.setLong(1, for: "series"))
      #expect(!player.controller.setFloatArray([1], for: "scalar"))
      try await settle(player)
      #expect(player.controller.clear("series"))
      try await settle(player)

      #expect(applied == ["when", "series", "clear series"])
    }
  }
#endif
