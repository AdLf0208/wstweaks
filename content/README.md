# Wither Skeleton Tweaks — carried content (`.hmod`)

The data and asset half of the port: `wstweaks:fragment` and
`wstweaks:immolation_blade`, their models/textures/lang, the two shaped
recipes, the swords tag and a creative tab. Behaviour (conversion, drop
cleanup, the fragment roll and the blade's hit) belongs to the native bundle
in `../`.

**LOCAL-ONLY.** MIT (upstream), derivatives allowed, but never published
without the maintainer's approval (ARCHITECTURE.md §8).

## Provenance

| | |
|---|---|
| Upstream repository | <https://github.com/Shadows-of-Fire/Wither-Skeleton-Tweaks> |
| Branch / version | `1.21`, mod **10.1.1** (the 1.21.1 release) |
| Commit | `1962c69bd63c2c51496c3e57a8cb9b7b9ae5dca2` |
| Licence | MIT (`LICENSE`) |
| Assets read | `src/main/resources/assets/wstweaks/{lang,models/item,textures/items}`, `data/wstweaks/recipe/*`, `data/minecraft/tags/item/swords.json` |
| Analysis | `../_shared/upstream/wstweaks/FINDINGS.md`; the clone is analysis-only, never shipped |

No ATM10 jar was available under `ports/_shared/carry-work/wstweaks/`, so the
upstream MIT assets were used and upgraded to 26.3 by hand. Nothing was
decompiled.

## What is included

```
content/
├── horizon-mod.toml
├── assets/wstweaks/
│   ├── items/{fragment,immolation_blade}.json     26.3 item definitions
│   ├── models/item/{fragment,immolation_blade}.json
│   ├── textures/item/{fragment,immolation_blade}.png(+ .mcmeta)
│   └── lang/*.json                                10 upstream languages
└── data/
    ├── wstweaks/horizon/item/{fragment,immolation_blade}.json
    ├── wstweaks/horizon/creative_tab/tab.json
    ├── wstweaks/recipe/{immolation_blade,wither_skeleton_skull}.json
    └── minecraft/tags/item/swords.json
```

Item declarations:

- `fragment`: template `minecraft:stick`, `!minecraft:cooking_fuel` removed
  (a plain stack-64 item).
- `immolation_blade`: template `minecraft:iron_sword` with `max_damage` 4096,
  `attack_damage` 11 (12 with the player's base 1), `attack_speed` -2,
  `enchantable` 30 and repair with a nether star — the upstream tier values
  (`WSTConfig.java:22-25`, `WitherSkeletonTweaks.java:29`).

Recipes were converted from 1.21.1 `{"item": …}` ingredients to 26.3 strings
(`"minecraft:blaze_rod"`, `"wstweaks:fragment"`, …). The upstream sword recipe
is a 3×3 blaze-rod/nether-star/stick shape; the fragment recipe is nine
fragments → one wither skeleton skull.

## Build / check

```sh
cd ports/wstweaks/content
cargo run --locked --offline --quiet \
  --manifest-path ../../../horizon/crates/cargo-horizon-mod/Cargo.toml -- horizon-mod build
cargo run --locked --offline --quiet \
  --manifest-path ../../../horizon/crates/cargo-horizon-mod/Cargo.toml -- horizon-mod check \
  target/horizon-mod/wstweaks.hmod
```

The e2e loads this folder directly with `--dev-mod "$PORT/content"`; the
built `.hmod` is copied to `content/wstweaks.hmod` and its size/SHA-256 are in
`../notes.md`.

## Gaps

- The upstream alias ids `wstweaks:blaze_blade` and `wstweaks:lava_blade`
  cannot be carried (the content format has no item aliases).
- The upstream creative tabs add the blade to Combat and the fragment to
  Ingredients; the content format only adds a mod tab, so both are in
  `wstweaks:tab` instead.
- The blade's 10-frame animated texture uses 26.3's `textures/item/` path; the
  `.mcmeta` is carried verbatim.
