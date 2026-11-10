// Wither Skeleton Tweaks for Horizon — the logic engine (pure, no game access).
//
// Ported from Wither Skeleton Tweaks (mod id `wstweaks`, MIT) for Minecraft
// 1.21.1 NeoForge. Local-only port, never published without approval.
//
// Behaviour, from the mod's public documentation and upstream source:
// 1. A wither skeleton that does not drop a Wither Skeleton Skull drops a
//    Wither Skull Fragment instead (`wstweaks:fragment`), gated by
//    `Shard Drop Chance` (default 1.0).
// 2. Any skeleton or stray that spawns in the Nether becomes a wither
//    skeleton (upstream also gives it a fresh bow; the pin has no mob
//    equipment write, so the replacement spawns bare — see the port notes).
// 3. Stone swords and bows are removed from the drops of all skeleton-based
//    creatures (skeletons, wither skeletons, strays, bogged), damaged or not.
// 4. The Immolation Blade ignites its target for 150 seconds and beheads the
//    skeleton family, guaranteeing a skull.
//
// This file is pure logic so it compiles and unit-tests as the crate's
// standalone library. The game-side glue lives in the bundle's support
// module; hook helpers stay single-function adapters.

pub const SKELETON: &str = "minecraft:skeleton";
pub const WITHER_SKELETON: &str = "minecraft:wither_skeleton";
pub const STRAY: &str = "minecraft:stray";
pub const BOGGED: &str = "minecraft:bogged";

pub const NETHER: &str = "minecraft:the_nether";

pub const STONE_SWORD: &str = "minecraft:stone_sword";
pub const BOW: &str = "minecraft:bow";
pub const WITHER_SKULL: &str = "minecraft:wither_skeleton_skull";

/// The item added by the mod (content carry: registered by the `.hmod`).
pub const SKULL_FRAGMENT: &str = "wstweaks:fragment";

/// One dropped stack, as the engine sees it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Drop {
    pub item: String,
    pub count: u32,
    /// Damage value of the stack (0 = undamaged).
    pub damage: u32,
}

#[cfg(test)]
impl Drop {
    pub fn new(item: &str, count: u32, damage: u32) -> Self {
        Drop {
            item: item.to_owned(),
            count,
            damage,
        }
    }
}

/// The skeleton family whose drops the mod cleans.
pub fn is_skeleton_family(kind: &str) -> bool {
    matches!(kind, SKELETON | WITHER_SKELETON | STRAY | BOGGED)
}

/// The mob a spawn converts to, if any: skeletons and strays spawning in the
/// Nether become wither skeletons. Bogged and wither skeletons are excluded
/// (they are not `Skeleton` subclasses upstream).
pub fn conversion_target(dimension: &str, kind: &str) -> Option<&'static str> {
    (dimension == NETHER && matches!(kind, SKELETON | STRAY)).then_some(WITHER_SKELETON)
}

/// A stone sword or bow dropped by a skeleton-family mob: removed, damaged or
/// not (upstream has no damage predicate).
pub fn is_cleaned_drop(kind: &str, drop: &Drop) -> bool {
    is_skeleton_family(kind) && (drop.item == STONE_SWORD || drop.item == BOW)
}

/// Removes the cleaned drops in place; returns how many were removed.
#[cfg(test)]
pub fn clean_drops(kind: &str, drops: &mut Vec<Drop>) -> usize {
    if !is_skeleton_family(kind) {
        return 0;
    }
    let before = drops.len();
    drops.retain(|drop| !is_cleaned_drop(kind, drop));
    before - drops.len()
}

/// A wither skeleton dropped no skull: the fragment replaces it (the glue
/// adds it only when the content item is registered). `fragment_for` adds the
/// `Shard Drop Chance` roll on top.
pub fn needs_fragment(kind: &str, drops: &[Drop]) -> bool {
    kind == WITHER_SKELETON && !drops.iter().any(|drop| drop.item == WITHER_SKULL)
}

/// The Immolation Blade item carried as content (`WSTObjects.java:16`).
pub const IMMOLATION_BLADE: &str = "wstweaks:immolation_blade";

/// The bow a converted skeleton is given (`Give Bows`).
pub const CONVERSION_BOW: &str = "minecraft:bow";

/// The skull a blade kill guarantees on a normal skeleton-family mob
/// (`WSTLootModifier.java:38-40`).
pub const SKELETON_SKULL: &str = "minecraft:skeleton_skull";

/// Upstream defaults: `Shard Drop Chance` (`WSTConfig.java:18`) and the
/// blade's 150-second ignite (`ImmolationBladeItem.java:20`). The blade's tier
/// stats are carried as content components (`content/data/wstweaks/horizon/
/// item/immolation_blade.json`).
pub const SHARD_DROP_CHANCE: f32 = 1.0;
pub const BLADE_FIRE_SECONDS: u32 = 150;

/// The port's config surface (`config/wstweaks.toml`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Config {
    /// `Shard Drop Chance`, 0..=1.
    pub shard_drop_chance: f32,
    /// `Give Bows`, default true: a converted skeleton gets a fresh bow in its
    /// main hand (`WSTEvents.java:39-42`).
    pub give_bows: bool,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            shard_drop_chance: SHARD_DROP_CHANCE,
            give_bows: true,
        }
    }
}

/// Parses `shard_drop_chance = <0..1>` from the config text. Unknown keys,
/// comments and invalid values are ignored; the chance is clamped.
pub fn parse_config(text: &str) -> Config {
    let mut config = Config::default();
    for line in text.lines() {
        let line = line.split('#').next().unwrap_or_default().trim();
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        if key.trim() == "give_bows" {
            match value.trim() {
                "true" => config.give_bows = true,
                "false" => config.give_bows = false,
                _ => {}
            }
            continue;
        }
        if key.trim() != "shard_drop_chance" {
            continue;
        }
        let Ok(value) = value.trim().parse::<f32>() else {
            continue;
        };
        if value.is_finite() {
            config.shard_drop_chance = value.clamp(0.0, 1.0);
        }
    }
    config
}

/// The config text written when the file is absent.
pub fn format_config(config: &Config) -> String {
    format!(
        "# Wither Skeleton Tweaks (Horizon port)\n\
         # The chance a wither skeleton without a skull drops a fragment (0..1).\n\
         shard_drop_chance = {}\n\
         # Give a converted skeleton a fresh bow (upstream's Give Bows).\n\
         give_bows = {}\n",
        config.shard_drop_chance, config.give_bows
    )
}

/// Whether a roll in `[0, 1)` passes `chance`. Upstream uses `<=`
/// (`WSTLootModifier.java:45`), so a roll of exactly 0 passes chance 0.
pub fn shard_roll_passes(chance: f32, roll: f32) -> bool {
    roll <= chance
}

/// The fragment is added when a wither skeleton has no skull and the roll
/// passes `chance`.
pub fn fragment_for(kind: &str, drops: &[Drop], chance: f32, roll: f32) -> bool {
    needs_fragment(kind, drops) && shard_roll_passes(chance, roll)
}

/// What a blade hit does beyond the sword's own damage.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BladeHit {
    /// How long the target burns.
    pub fire_ticks: u32,
    /// Whether the hit is lethal and guarantees a skull.
    pub behead: bool,
}

/// A blade hit ignites every mob; the skeleton family is also beheaded
/// (`ImmolationBladeItem.java:19-32`).
pub fn blade_hit(kind: &str) -> BladeHit {
    BladeHit {
        fire_ticks: BLADE_FIRE_SECONDS * 20,
        behead: is_skeleton_family(kind),
    }
}

/// The skull a blade kill guarantees, if the target is skeleton family.
pub fn guaranteed_skull(kind: &str) -> Option<&'static str> {
    match kind {
        WITHER_SKELETON => Some(WITHER_SKULL),
        SKELETON | STRAY | BOGGED => Some(SKELETON_SKULL),
        _ => None,
    }
}

/// Upstream's post-kill shove from three random samples in `[0, 1)`
/// (`ImmolationBladeItem.java:30-31`).
pub fn blade_shove(rx: f64, ry: f64, rz: f64) -> [f64; 3] {
    [2.0 - rx * 4.0, ry * 4.0, 2.0 - rz * 4.0]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nether_skeletons_and_strays_convert_but_nothing_else_does() {
        assert_eq!(conversion_target(NETHER, SKELETON), Some(WITHER_SKELETON));
        // Upstream converts `instanceof Skeleton`, which includes strays.
        assert_eq!(conversion_target(NETHER, STRAY), Some(WITHER_SKELETON));
        assert_eq!(conversion_target(NETHER, "minecraft:zombie"), None);
        assert_eq!(conversion_target(NETHER, WITHER_SKELETON), None);
        assert_eq!(conversion_target(NETHER, BOGGED), None);
        assert_eq!(conversion_target("minecraft:overworld", SKELETON), None);
        assert_eq!(conversion_target("minecraft:the_end", SKELETON), None);
        assert_eq!(conversion_target("minecraft:overworld", STRAY), None);
    }

    #[test]
    fn skeleton_weapons_are_cleaned_whether_damaged_or_not() {
        let damaged_sword = Drop::new(STONE_SWORD, 1, 37);
        let fresh_sword = Drop::new(STONE_SWORD, 1, 0);
        let damaged_bow = Drop::new(BOW, 1, 12);
        let fresh_bow = Drop::new(BOW, 1, 0);
        for kind in [SKELETON, WITHER_SKELETON, STRAY, BOGGED] {
            assert!(is_cleaned_drop(kind, &damaged_sword), "{kind}");
            assert!(is_cleaned_drop(kind, &fresh_sword), "{kind}");
            assert!(is_cleaned_drop(kind, &damaged_bow), "{kind}");
            assert!(is_cleaned_drop(kind, &fresh_bow), "{kind}");
            // Only stone swords and bows: other items are untouched.
            assert!(!is_cleaned_drop(kind, &Drop::new("minecraft:bone", 1, 0)));
            assert!(!is_cleaned_drop(
                kind,
                &Drop::new("minecraft:iron_sword", 1, 0)
            ));
        }
        // Other mobs keep their drops.
        assert!(!is_cleaned_drop("minecraft:zombie", &damaged_sword));
        assert!(!is_cleaned_drop("minecraft:zombie", &fresh_bow));
    }

    #[test]
    fn clean_drops_counts_and_keeps_other_items() {
        let mut drops = vec![
            Drop::new(STONE_SWORD, 1, 40),
            Drop::new(STONE_SWORD, 1, 0),
            Drop::new(BOW, 1, 5),
            Drop::new(BOW, 1, 0),
            Drop::new("minecraft:bone", 2, 0),
            Drop::new(WITHER_SKULL, 1, 0),
        ];
        assert_eq!(clean_drops(WITHER_SKELETON, &mut drops), 4);
        assert_eq!(
            drops,
            vec![
                Drop::new("minecraft:bone", 2, 0),
                Drop::new(WITHER_SKULL, 1, 0),
            ]
        );
    }

    #[test]
    fn a_non_skeleton_drop_list_is_untouched() {
        let mut drops = vec![Drop::new(BOW, 1, 0), Drop::new(STONE_SWORD, 1, 9)];
        assert_eq!(clean_drops("minecraft:zombie", &mut drops), 0);
        assert_eq!(
            drops,
            vec![Drop::new(BOW, 1, 0), Drop::new(STONE_SWORD, 1, 9)]
        );
    }

    #[test]
    fn fragment_fills_a_missing_skull() {
        // Upstream item id (`WSTObjects.java:14`), not the old port name.
        assert_eq!(SKULL_FRAGMENT, "wstweaks:fragment");
        let no_skull = vec![Drop::new("minecraft:coal", 1, 0)];
        assert!(needs_fragment(WITHER_SKELETON, &no_skull));
        let with_skull = vec![Drop::new(WITHER_SKULL, 1, 0)];
        assert!(!needs_fragment(WITHER_SKELETON, &with_skull));
        // Only wither skeletons: a normal skeleton's missing skull is not ours.
        assert!(!needs_fragment(SKELETON, &no_skull));
        assert!(!needs_fragment(STRAY, &no_skull));
    }

    #[test]
    fn shard_chance_gates_the_fragment() {
        let no_skull = vec![Drop::new("minecraft:coal", 1, 0)];
        // Default chance: a roll anywhere passes.
        assert!(fragment_for(
            WITHER_SKELETON,
            &no_skull,
            SHARD_DROP_CHANCE,
            0.999
        ));
        // A roll at or below the chance passes; above it does not (`<=`).
        assert!(fragment_for(WITHER_SKELETON, &no_skull, 0.5, 0.5));
        assert!(!fragment_for(WITHER_SKELETON, &no_skull, 0.5, 0.500_001));
        // Chance 0 still passes a roll of exactly 0 (upstream's `<=` quirk).
        assert!(fragment_for(WITHER_SKELETON, &no_skull, 0.0, 0.0));
        assert!(!fragment_for(WITHER_SKELETON, &no_skull, 0.0, 0.001));
        // A skull in the loot suppresses the fragment at any chance.
        let with_skull = vec![Drop::new(WITHER_SKULL, 1, 0)];
        assert!(!fragment_for(WITHER_SKELETON, &with_skull, 1.0, 0.0));
        // Only wither skeletons.
        assert!(!fragment_for(SKELETON, &no_skull, 1.0, 0.0));
        assert!(!fragment_for(STRAY, &no_skull, 1.0, 0.0));
    }

    #[test]
    fn config_parses_the_shard_chance_and_clamps_it() {
        assert_eq!(parse_config("").shard_drop_chance, SHARD_DROP_CHANCE);
        assert_eq!(
            parse_config("# a comment\nshard_drop_chance = 0.25\n").shard_drop_chance,
            0.25
        );
        assert_eq!(
            parse_config("shard_drop_chance = 0.0").shard_drop_chance,
            0.0
        );
        assert_eq!(
            parse_config("shard_drop_chance = 2.0").shard_drop_chance,
            1.0
        );
        assert_eq!(
            parse_config("shard_drop_chance = -3").shard_drop_chance,
            0.0
        );
        assert_eq!(
            parse_config("shard_drop_chance = nope").shard_drop_chance,
            SHARD_DROP_CHANCE
        );
        assert!(Config::default().give_bows);
        assert!(parse_config("").give_bows);
        assert!(!parse_config("give_bows = false").give_bows);
        assert!(parse_config("give_bows = true").give_bows);
        assert!(parse_config("give_bows = maybe").give_bows);
        assert!(parse_config(&format_config(&Config::default())).give_bows);
        assert!(
            !parse_config(&format_config(&Config {
                give_bows: false,
                ..Config::default()
            }))
            .give_bows
        );
        assert_eq!(
            parse_config("unknown = 1").shard_drop_chance,
            SHARD_DROP_CHANCE
        );
        let config = Config {
            shard_drop_chance: 0.35,
            give_bows: false,
        };
        assert_eq!(parse_config(&format_config(&config)), config);
    }

    #[test]
    fn a_blade_hit_ignites_every_mob_and_beheads_the_skeleton_family() {
        for kind in [SKELETON, WITHER_SKELETON, STRAY, BOGGED] {
            let hit = blade_hit(kind);
            assert_eq!(hit.fire_ticks, BLADE_FIRE_SECONDS * 20, "{kind}");
            assert!(hit.behead, "{kind}");
        }
        let zombie = blade_hit("minecraft:zombie");
        assert_eq!(zombie.fire_ticks, 3000);
        assert!(!zombie.behead);
        assert_eq!(guaranteed_skull(WITHER_SKELETON), Some(WITHER_SKULL));
        assert_eq!(guaranteed_skull(SKELETON), Some(SKELETON_SKULL));
        assert_eq!(guaranteed_skull(STRAY), Some(SKELETON_SKULL));
        assert_eq!(guaranteed_skull(BOGGED), Some(SKELETON_SKULL));
        assert_eq!(guaranteed_skull("minecraft:zombie"), None);
    }

    #[test]
    fn the_blade_shove_matches_upstreams_random_push() {
        assert_eq!(blade_shove(0.0, 0.0, 0.0), [2.0, 0.0, 2.0]);
        assert_eq!(blade_shove(0.5, 0.5, 0.5), [0.0, 2.0, 0.0]);
        assert_eq!(blade_shove(1.0, 1.0, 1.0), [-2.0, 4.0, -2.0]);
    }
}
