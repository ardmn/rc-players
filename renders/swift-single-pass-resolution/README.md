# Single-pass value resolution in the native Swift player

Before/after evidence for the native Swift player's single-pass value resolution
(`ardmn/swift-single-pass-resolution`). Base is `1bebc248`, head is `8a60dd39`.

## How these were chosen

The native core's snapshots (`NativeSwiftDocumentSession.snapshot` at 0, 0.5, 1 and 2 s) were dumped
for all 760 `.rc` documents in the repository at base and head. 341 dumps differ, but 312 of those
differ only in the print order of two `Set`s (`boundComponents`, `conformancePathIDs`). The other 29
have a real change, and each one has an image here:

- **1 Float-to-integer visibility** (`renders/float-integer-state/ordinary.rc`). An integer
  expression that reads a Float expression's result now sees the converted value, as AndroidX
  `RemoteComposeState.updateFloat` publishes it, so the state layout picks its first case.
- **23 catalog buttons**: a path built from a measured component value. Its pre-measurement
  estimate is now the same value as the measurement probe. The settled frame does not change.
- **5 level indicators**: a fully transparent colour is now `0x00000000` rather than `0x00332E3C`.
  Nothing is drawn either way.

## Images

Each image shows, left to right:

| column | what it is |
| --- | --- |
| base | `rc-swift-render` (the AppKit renderer, `Sources/RcSwiftRender`) built at `1bebc248` |
| head | the same tool built at `8a60dd39` |
| reference | AndroidX embedded, `RcEmbeddedRenderHarness` in `third_party/rc-embedded-player` |

Every document is drawn at its corpus manifest size and density. The float-integer-state fixture is
drawn at 200 × 200 px, density 2. Transparent areas are shown as a checkerboard. The percentage is
pixelmatch mismatch against the reference (`scripts/design-artifacts/rc-lane-ab-score.mjs`, the
same scorer `scripts/rc-lane-ab/render-ab.sh` uses).

## Result

- **1 document changes pixels, and it now matches the reference**: `float-integer-state__ordinary`
  goes from 100% to 0% mismatch. Base drew the blue fallback, while head and AndroidX draw red.
- **28 documents are byte-identical between base and head** in the AppKit renderer. Renders at
  t = 0, 0.5 and 2 s agree. The button estimate does not reach the drawn frame, and a transparent
  colour draws nothing.
- **No document moved farther from the reference.**
- A full pass over all 760 documents with `rc-swift-render` at base and head gave the same answer:
  only `float-integer-state/ordinary.rc` differs.

The remaining mismatch on the buttons, which is up to 46% for `button-customshape`, is in both base
and head. It comes from AppKit layout and text, and from fonts: the AppKit renderer uses platform faces, and the reference
lane ran without the compose-ai Google Fonts cache, so it used fallback faces. It is not part of this
change.

| document | snapshot change | base vs reference | head vs reference | head pixels | closer to reference? |
| --- | --- | --- | --- | --- | --- |
| [`float-integer-state__ordinary`](float-integer-state__ordinary.png) | Float-to-integer visibility | 100.00% | 0.00% | changed | yes |
| [`levelindicator__ideal__full__192dp`](levelindicator__ideal__full__192dp.png) | transparent colour | 2.58% | 2.58% | identical to base | unchanged |
| [`levelindicator__ideal__full__204dp`](levelindicator__ideal__full__204dp.png) | transparent colour | 2.45% | 2.45% | identical to base | unchanged |
| [`levelindicator__ideal__full__216dp`](levelindicator__ideal__full__216dp.png) | transparent colour | 2.33% | 2.33% | identical to base | unchanged |
| [`levelindicator__ideal__full__225dp`](levelindicator__ideal__full__225dp.png) | transparent colour | 2.24% | 2.24% | identical to base | unchanged |
| [`levelindicator__ideal__full__240dp`](levelindicator__ideal__full__240dp.png) | transparent colour | 2.11% | 2.11% | identical to base | unchanged |
| [`button-compact__ideal__child-disabled__compact`](button-compact__ideal__child-disabled__compact.png) | path estimate | 3.41% | 3.41% | identical to base | unchanged |
| [`button-compact__ideal__child-text-only-disabled__compact`](button-compact__ideal__child-text-only-disabled__compact.png) | path estimate | 2.76% | 2.76% | identical to base | unchanged |
| [`button-compact__ideal__child-text-only__compact`](button-compact__ideal__child-text-only__compact.png) | path estimate | 1.71% | 1.71% | identical to base | unchanged |
| [`button-compact__ideal__child__compact`](button-compact__ideal__child__compact.png) | path estimate | 2.29% | 2.29% | identical to base | unchanged |
| [`button-compact__ideal__default__compact`](button-compact__ideal__default__compact.png) | path estimate | 13.84% | 13.84% | identical to base | unchanged |
| [`button-compact__ideal__disabled__compact`](button-compact__ideal__disabled__compact.png) | path estimate | 3.41% | 3.41% | identical to base | unchanged |
| [`button-compact__ideal__filled-variant-disabled__compact`](button-compact__ideal__filled-variant-disabled__compact.png) | path estimate | 3.41% | 3.41% | identical to base | unchanged |
| [`button-compact__ideal__filled-variant-text-only-disabled__compact`](button-compact__ideal__filled-variant-text-only-disabled__compact.png) | path estimate | 2.76% | 2.76% | identical to base | unchanged |
| [`button-compact__ideal__filled-variant-text-only__compact`](button-compact__ideal__filled-variant-text-only__compact.png) | path estimate | 11.75% | 11.75% | identical to base | unchanged |
| [`button-compact__ideal__filled-variant__compact`](button-compact__ideal__filled-variant__compact.png) | path estimate | 13.76% | 13.76% | identical to base | unchanged |
| [`button-compact__ideal__outlined-disabled__compact`](button-compact__ideal__outlined-disabled__compact.png) | path estimate | 4.74% | 4.74% | identical to base | unchanged |
| [`button-compact__ideal__outlined-text-only-disabled__compact`](button-compact__ideal__outlined-text-only-disabled__compact.png) | path estimate | 3.78% | 3.78% | identical to base | unchanged |
| [`button-compact__ideal__outlined-text-only__compact`](button-compact__ideal__outlined-text-only__compact.png) | path estimate | 3.83% | 3.83% | identical to base | unchanged |
| [`button-compact__ideal__outlined__compact`](button-compact__ideal__outlined__compact.png) | path estimate | 4.89% | 4.89% | identical to base | unchanged |
| [`button-compact__ideal__text-only-disabled__compact`](button-compact__ideal__text-only-disabled__compact.png) | path estimate | 2.76% | 2.76% | identical to base | unchanged |
| [`button-compact__ideal__text-only__compact`](button-compact__ideal__text-only__compact.png) | path estimate | 11.81% | 11.81% | identical to base | unchanged |
| [`button-compact__ideal__tonal-disabled__compact`](button-compact__ideal__tonal-disabled__compact.png) | path estimate | 3.41% | 3.41% | identical to base | unchanged |
| [`button-compact__ideal__tonal-text-only-disabled__compact`](button-compact__ideal__tonal-text-only-disabled__compact.png) | path estimate | 2.76% | 2.76% | identical to base | unchanged |
| [`button-compact__ideal__tonal-text-only__compact`](button-compact__ideal__tonal-text-only__compact.png) | path estimate | 10.48% | 10.48% | identical to base | unchanged |
| [`button-compact__ideal__tonal__compact`](button-compact__ideal__tonal__compact.png) | path estimate | 12.30% | 12.30% | identical to base | unchanged |
| [`button-customshape__ideal__default__compact`](button-customshape__ideal__default__compact.png) | path estimate | 46.24% | 46.24% | identical to base | unchanged |
| [`button-namedlabel__ideal__default__compact`](button-namedlabel__ideal__default__compact.png) | path estimate | 37.99% | 37.99% | identical to base | unchanged |
| [`buttongroup__ideal__default__compact`](buttongroup__ideal__default__compact.png) | path estimate | 6.45% | 6.45% | identical to base | unchanged |
