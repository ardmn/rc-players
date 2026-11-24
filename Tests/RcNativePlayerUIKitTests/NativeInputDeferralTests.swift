#if canImport(UIKit)
  import Foundation
  import Testing
  import UIKit

  @testable import RcNativePlayerUIKit

  @MainActor @Suite struct NativeInputDeferralTests {
    /// A session in the background refuses a write only for now, and says so, so a caller that has
    /// already promised the write — the SwiftUI controller — keeps retrying it rather than giving
    /// up and never showing it. Back in the foreground, a refusal is the session's answer again.
    @Test func aBackgroundSceneDefersInputUntilItIsActiveAgain() async throws {
      var errors: [RemoteComposeNativePlayerError] = []
      let view = RemoteComposeNativePlayerView(
        data: try NativeTestFixtures.data("TitleCardRemote-640x480.rc"),
        resourceResolver: nil, onError: { errors.append($0) })
      for _ in 0..<1_000 where view.isOpeningDocument {
        try await Task.sleep(nanoseconds: 10_000_000)
      }
      try #require(!view.isOpeningDocument && errors.isEmpty)
      #expect(!view.isInputDeferred)

      // SwiftPM runs without a window scene, so the scene notifications are delivered directly.
      view.perform(NSSelectorFromString("sceneDidEnterBackground"))
      #expect(view.isInputDeferred)
      #expect(!(await view.setInteger(1, for: "USER:missing")))
      #expect(view.isInputDeferred)

      view.perform(NSSelectorFromString("sceneDidActivate"))
      #expect(!view.isInputDeferred)
      #expect(!(await view.setInteger(1, for: "USER:missing")))
      #expect(!view.isInputDeferred)
    }
  }
#endif
