# Wasm `namedValues` six-digit colours

`Tests/RcNativePlayerCoreTests/Fixtures/CircularProgressRemote-384x384.rc` in the Wasm player
(`:rc-player-wasm:wasmPlayerDist`, headless Chromium at 420×420), with the progress colour
`WearM3.primary` overridden through `?namedValues=`.

| File | `value` | Result |
| --- | --- | --- |
| `rrggbb-before.png` | `#FF8800` | read with a zero alpha: the progress arc is not drawn |
| `rrggbb-after.png` | `#FF8800` | opaque orange |
| `aarrggbb-reference.png` | `#FFFF8800` | the eight-digit form, unchanged by the fix |

`rrggbb-after.png` is byte-identical to `aarrggbb-reference.png`. The `named-colour-spellings`
case of `scripts/wasm-smoke/smoke.mjs` (after `:rc-player-wasm:wasmPlayerTestDist`, which stages
this fixture) checks the same thing on every CI run.
