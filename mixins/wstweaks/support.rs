// Game-side glue for Wither Skeleton Tweaks: the entry functions the helpers
// call, the config surface and the small translation between `ItemStack` and
// the pure engine's `Drop`. Injected into `crate::game` as `wstweaks_state`;
// it needs the game, so it is not part of the standalone library.

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::MutexGuard;
use std::time::SystemTime;

use horizon_client::items::ItemStack;
use horizon_client::mod_api::EquipmentSlot;
use horizon_core::random::RandomSource;

use crate::game::native_hooks::NativeLootDrops;

use crate::game::wstweaks::{
    CONVERSION_BOW, Config, Drop, IMMOLATION_BLADE, SKULL_FRAGMENT, blade_hit, blade_shove,
    conversion_target, format_config, fragment_for, guaranteed_skull, is_cleaned_drop,
    parse_config,
};

/// The port's config file under `config/`. Upstream's Placebo file is named
/// after the mod id; this is the same `shard_drop_chance` key in TOML form.
const CONFIG_FILE: &str = "wstweaks.toml";

/// A blade kill stays marked for the guaranteed skull for this long: the
/// pin's own player-hit memory is 100 ticks.
const BLADE_MARK_TICKS: i64 = 100;

struct ConfigCache {
    config: Config,
    path: Option<PathBuf>,
    modified: Option<SystemTime>,
}

static CONFIG: Mutex<Option<ConfigCache>> = Mutex::new(None);

fn config_cache() -> MutexGuard<'static, Option<ConfigCache>> {
    CONFIG.lock().expect("wstweaks config lock poisoned")
}

/// A mob spawned: a Nether skeleton or stray is swapped for a wither skeleton.
/// The callback runs once the mob exists (the pin's `mob_spawned` is post-add,
/// so `/summon` converts here even though upstream only hooks spawn
/// finalisation), so the original is found among the level's mobs at the spawn
/// position and removed; the replacement spawns at the same point and, when
/// `give_bows` is on (upstream's `Give Bows`, default true), gets a fresh
/// undamaged bow in its main hand (`WSTEvents.java:39-42`) through the living
/// equipment write (API 382).
#[allow(private_interfaces)]
pub fn on_mob_spawned(
    game: &mut crate::game::Game<'_>,
    dimension: &str,
    kind: &str,
    pos: [f64; 3],
) {
    let Some(target) = conversion_target(dimension, kind) else {
        return;
    };
    let found = game
        .native_mobs(dimension)
        .into_iter()
        .filter(|mob| mob.kind == kind)
        .min_by(|a, b| distance2(a.pos, pos).total_cmp(&distance2(b.pos, pos)));
    let Some(mob) = found else {
        return;
    };
    // A metre of slack: the callback's position is the spawn point, and a
    // just-spawned mob has not moved yet. Anything near it is the one.
    if distance2(mob.pos, pos) > 1.0 {
        return;
    }
    game.native_remove_mob(dimension, mob.id);
    let spawned = game.native_spawn_mob(
        dimension,
        target,
        pos,
        &crate::game::native_mobs::NativeSpawn::default(),
    );
    if current_config().give_bows
        && let Some(id) = spawned
    {
        equip_bow(game, id);
    }
}

/// Put a fresh bow in the converted mob's main hand (`Give Bows`).
fn equip_bow(game: &mut crate::game::Game<'_>, id: u32) {
    let Some(entity) = game.native_entity(id) else {
        return;
    };
    let Some(living) = game.native_living(entity) else {
        return;
    };
    let bow = ItemStack::new(CONVERSION_BOW, 1);
    let _ = game.native_living_set_equipment(living, EquipmentSlot::MainHand, Some(bow));
}

/// Before the server opens its worlds: read `config/wstweaks.toml`, writing
/// the default file when it is absent.
#[allow(private_interfaces)]
pub fn on_server_about_to_start(_game: &mut crate::game::Game<'_>) {
    let path = crate::game::Game::native_config_dir()
        .ok()
        .map(|dir| dir.join(CONFIG_FILE));
    let config = match &path {
        Some(path) => read_or_create(path),
        None => {
            log::warn!("[wstweaks] no config dir; using the defaults");
            Config::default()
        }
    };
    let modified = path.as_deref().and_then(modified);
    let mut guard = config_cache();
    *guard = Some(ConfigCache {
        config,
        path,
        modified,
    });
    log::info!(
        "[wstweaks] shard_drop_chance={}",
        config.shard_drop_chance
    );
}

/// A player's hit landed on a mob holding `stack`: the Immolation Blade
/// ignites the target and, for the skeleton family, beheads it.
#[allow(private_interfaces)]
pub fn on_hurt_enemy(
    game: &mut crate::game::Game<'_>,
    stack: &ItemStack,
    entity: u32,
    kind: &str,
) {
    log::info!(
        "[wstweaks] DIAG hurt_enemy entity={entity} kind={kind} held={} blade={}",
        &*stack.item,
        &*stack.item == IMMOLATION_BLADE
    );
    if &*stack.item != IMMOLATION_BLADE {
        return;
    }
    let hit = blade_hit(kind);
    let dimension = game.dim.id().to_owned();
    if let Some(mob) = game
        .mobs
        .iter_mut()
        .find(|mob| mob.id == entity && !mob.removed)
    {
        mob.ignite_for_ticks(hit.fire_ticks as i32);
    }
    if !hit.behead {
        return;
    }
    // The normal sword hit has already landed; upstream then sets health to 1
    // and deals a lethal fireworks hit. The pin's loot context has no damage
    // source, so the guaranteed skull is carried by this mark instead.
    let before = game
        .mobs
        .iter()
        .find(|mob| mob.id == entity)
        .map(|mob| (mob.health, mob.death_time, mob.removed));
    mark_blade_kill(entity, game.world.game_time);
    let set = game.native_set_mob_health(&dimension, entity, 1.0);
    let killed = game.native_kill_mob(&dimension, entity);
    log::info!(
        "[wstweaks] DIAG behead entity={entity} kind={kind} now={} before={before:?} set={set} killed={killed}",
        game.world.game_time
    );
    let shove = blade_shove(
        f64::from(game.world.random.next_float()),
        f64::from(game.world.random.next_float()),
        f64::from(game.world.random.next_float()),
    );
    let _ = game.native_push_mob(&dimension, entity, shove);
}

/// Drops are being rolled: clean skeleton weapons (stone swords and bows,
/// damaged or not), add a guaranteed skull after a blade kill, and add a skull
/// fragment when a wither skeleton dropped no skull and the shard roll passes.
/// Only mob drops: a block break's context names no entity.
#[allow(private_interfaces)]
pub fn on_loot_drops(
    game: &mut crate::game::Game<'_>,
    context: &NativeLootDrops<'_>,
    drops: &mut Vec<ItemStack>,
) {
    let Some((entity, kind)) = context.entity else {
        return;
    };
    drops.retain(|stack| !is_cleaned_drop(kind, &drop_of(stack)));
    // The guaranteed skull comes first: it also suppresses the fragment. The
    // mark is the reliable path for a delayed death; the held-blade check
    // covers the same-tick case even if another loot event consumed the mark.
    let now = game.world.game_time;
    let took = take_blade_kill(entity, now);
    let held = blade_held_by(game, context.player);
    let beheaded = took || held;
    log::info!(
        "[wstweaks] DIAG loot entity={entity} kind={kind} now={now} took={took} held={held} player={:?} acting={:?} drops={:?}",
        context.player,
        game.native_acting_id(),
        drops.iter().map(|s| s.item.to_string()).collect::<Vec<_>>()
    );
    if beheaded
        && let Some(skull) = guaranteed_skull(kind)
        && !drops.iter().any(|stack| &*stack.item == skull)
    {
        drops.push(one(skull));
    }
    let present: Vec<Drop> = drops.iter().map(drop_of).collect();
    let config = current_config();
    let roll = game.world.random.next_float();
    if fragment_for(kind, &present, config.shard_drop_chance, roll)
        && game.res.items().get(SKULL_FRAGMENT).is_some()
        && !drops.iter().any(|stack| &*stack.item == SKULL_FRAGMENT)
    {
        drops.push(one(SKULL_FRAGMENT));
    }
    log::info!(
        "[wstweaks] DIAG loot-out entity={entity} drops={:?}",
        drops.iter().map(|s| s.item.to_string()).collect::<Vec<_>>()
    );
}

/// Whether `player` is the acting player and still holds the blade. The loot
/// context has no tool for a mob death at the pin, and a same-tick kill can
/// race another loot event's mark consumption.
fn blade_held_by(game: &mut crate::game::Game<'_>, player: Option<u128>) -> bool {
    let Some(player) = player else {
        return false;
    };
    if player != game.native_acting_id() {
        return false;
    }
    game.held()
        .is_some_and(|stack| &*stack.item == IMMOLATION_BLADE)
}

fn drop_of(stack: &ItemStack) -> Drop {
    Drop {
        item: stack.item.to_string(),
        count: stack.count,
        damage: stack.damage,
    }
}

fn one(item: &str) -> ItemStack {
    ItemStack {
        item: item.into(),
        count: 1,
        damage: 0,
        extra: None,
    }
}

fn modified(path: &Path) -> Option<SystemTime> {
    fs::metadata(path)
        .ok()
        .and_then(|metadata| metadata.modified().ok())
}

fn read_or_create(path: &Path) -> Config {
    match fs::read_to_string(path) {
        Ok(text) => parse_config(&text),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            let config = Config::default();
            if let Err(error) = fs::write(path, format_config(&config)) {
                log::warn!("[wstweaks] could not write {}: {error}", path.display());
            }
            config
        }
        Err(error) => {
            log::warn!("[wstweaks] could not read {}: {error}", path.display());
            Config::default()
        }
    }
}

/// The config in force, re-read when the file's mtime changed. Upstream reloads
/// on a datapack reload; the pin has no such hook, so a changed file is picked
/// up on the next mob death.
fn current_config() -> Config {
    let mut guard = config_cache();
    let Some(cache) = guard.as_mut() else {
        return Config::default();
    };
    let Some(path) = cache.path.clone() else {
        return cache.config;
    };
    let modified = modified(&path);
    if modified == cache.modified {
        return cache.config;
    }
    if let Ok(text) = fs::read_to_string(&path) {
        cache.config = parse_config(&text);
        log::info!(
            "[wstweaks] reloaded {} (shard_drop_chance={})",
            path.display(),
            cache.config.shard_drop_chance
        );
    }
    cache.modified = modified;
    cache.config
}

fn mark_blade_kill(id: u32, now: i64) {
    let mut marks = BLADE_KILLS
        .lock()
        .expect("wstweaks blade-mark lock poisoned");
    marks.retain(|(_, at)| now - *at <= BLADE_MARK_TICKS);
    marks.push((id, now));
}

fn take_blade_kill(id: u32, now: i64) -> bool {
    let mut marks = BLADE_KILLS
        .lock()
        .expect("wstweaks blade-mark lock poisoned");
    let Some(index) = marks
        .iter()
        .position(|(marked, at)| *marked == id && now - *at <= BLADE_MARK_TICKS)
    else {
        return false;
    };
    marks.remove(index);
    true
}

static BLADE_KILLS: Mutex<Vec<(u32, i64)>> = Mutex::new(Vec::new());

fn distance2(a: [f64; 3], b: [f64; 3]) -> f64 {
    let dx = a[0] - b[0];
    let dy = a[1] - b[1];
    let dz = a[2] - b[2];
    dx * dx + dy * dy + dz * dz
}
