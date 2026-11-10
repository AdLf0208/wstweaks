# wstweaks (Horizon port)

A Horizon port of [wstweaks](Shadows-of-Fire/Wither-Skeleton-Tweaks) — MIT.

**Status: first slices.** What is below is what the port actually does today.

## Implemented so far

- Wither Skull Fragments** — a wither skeleton that does not drop a Wither
- Skeleton Skull drops a `wstweaks:fragment`. Upstream gates the drop on
- `Shard Drop Chance` (default 1.0, i.e. always) with a `nextFloat() <=`
- roll (`WSTLootModifier.java:44-48`, `WSTConfig.java:18`); the port reads the
- same key from `config/wstweaks.toml`.
- Skeleton Conversion** — any skeleton **or stray** that spawns in the
- Nether becomes a wither skeleton. Upstream also replaces the main hand with
- a fresh bow (`Give Bows`, default true); the replacement spawned by this

## Not yet ported

- Converted-mob equipment:** upstream converts in place and, with
- `Give Bows` (default true), puts a fresh undamaged bow in the converted
- mob's main hand (`WSTEvents.java:39-42`). `NativeSpawn` has no equipment
- field at the pin (`native_mobs.rs`), so the port's replacement spawns bare;
- keeping the original's weapon instead would need a mob-equipment write API
- (none exists; `native_on_equip` only listens). The previous note claim that
- the converted mob "keeps its weapon" was wrong.
- Blade damage source:** upstream's beheading deals a 150-damage

## Install

Build the bundle with a native-mod capable launcher, or add the file from the
registry once it is listed. Pinned to Horizon `1d63e0a` and horizon-mixins
`5a64af93` for game 26.3.

## Build from source

```sh
cargo test
python3 tools/horizon.py check --horizon <horizon checkout>
python3 tools/horizon.py build --horizon <horizon checkout>
python3 tools/package.py
```

## Credits and licence

Original mod: Shadows-of-Fire/Wither-Skeleton-Tweaks. Port: AdLf0208. Licence: MIT — see [LICENSE](LICENSE);
the original notices are preserved.
