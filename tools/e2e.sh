#!/usr/bin/env bash
# In-game check for the Wither Skeleton Tweaks port (slices 1 and 2).
#
# 1. Conversion: a skeleton (and a stray) summoned in the Nether must be
#    replaced by a wither skeleton; a skeleton summoned in the Overworld must
#    stay a skeleton.
# 2. Drop cleanup: a wither skeleton killed while holding a *fresh, undamaged*
#    bow must not drop that bow (upstream has no damage predicate). A zombie
#    with the identical fresh bow keeps it, which proves the equipment drop
#    and its forced chance work in this build and that only the skeleton-family
#    predicate removes the item.
# 3. Content: both carried items are giveable. The fragment drops from a
#    wither skeleton with `Shard Drop Chance=1`; after rewriting the config to
#    0 (the port re-reads a changed config file on the next death) it does not.
# 4. Immolation Blade: a blade hit sets an iron golem on fire (its health keeps
#    falling after the hit) while a wooden sword does not. A blade kill beheads
#    a skeleton (a guaranteed skeleton skull) while `/kill` does not.
#
#   tools/e2e.sh            # uses the fast build under target/horizon-cargo
#
# Notes on the commands used:
#  * Horizon keeps one level in place at a time; `execute in minecraft:the_nether`
#    enters the Nether level while its command runs, so the mod's spawn hook is
#    told `minecraft:the_nether`. A freshly opened level's chunks load in the
#    background, so chunk [0,0] is force-loaded and a moment is given to it
#    before summoning (the converted mob can only spawn in a loaded chunk).
#  * The item NBT is 26.3's ItemStack codec: `equipment:{mainhand:{id,count,
#    components:{"minecraft:damage":N}}}` and `drop_chances:{mainhand:N}`;
#    `HandItems`/`HandDropChances` are the old format and are ignored.
#  * The content folder is loaded with `--dev-mod`; without it the fragment is
#    not registered and the blade does not exist.
#
# Default run: the game loads `content/` as a dev mod.
# EMBEDDED=1: the game is launched with **only the native bundle** (no
# `--dev-mod`) and the content comes from the bundle's embedded copy
# (`mixins/<id>/data/…`, the AE2 pattern). The run also checks the file the
# helper wrote, and CONTROL=1 (default with EMBEDDED) first launches the same
# binary with `.horizon-cache` unusable, where the item ids must be unknown.
set -euo pipefail

CLONE=${CAMPAIGN_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}
PORT=$CLONE/ports/wstweaks
# The control binary is shared at the campaign pin; the game is this port's build.
CTL=${CTL:-$CLONE/ports/_shared/bin/horizon-1d63e0a5/horizon-ctl}
GAME=${GAME:-$PORT/target/horizon-cargo/fast/horizon-client}
RES=${RES:-${HORIZON_RES:-${HORIZON_RES:-$HOME/.local/horizon-client/26.3}}}
SOCK=${SOCK:-/tmp/opencode/wstweaks-e2e.sock}
LOG=${LOG:-/tmp/opencode/wstweaks-e2e.log}
CONTENT=${CONTENT:-$PORT/content}
# NEGATIVE=1 keeps the scenario but expects the Nether skeleton NOT to be
# converted: the run MUST fail at that assertion, proving it is not vacuous.
NEGATIVE=${NEGATIVE:-0}
[ "$NEGATIVE" = 1 ] && WANT_CONVERTED=0 || WANT_CONVERTED=1
EMBEDDED=${EMBEDDED:-0}
CONTROL=${CONTROL:-$EMBEDDED}
WORLD=WsTweaksE2E
CONTROL_WORLD=WsTweaksControl

mkdir -p "$(dirname "$LOG")"
exec > >(tee "$LOG") 2>&1

[ -x "$CTL" ] || { echo "missing horizon-ctl: $CTL" >&2; exit 1; }
[ -x "$GAME" ] || { echo "missing horizon-client: $GAME" >&2; exit 1; }
[ -d "$RES/assets" ] || { echo "missing prepared resources: $RES" >&2; exit 1; }
[ -f "$CONTENT/horizon-mod.toml" ] || { echo "missing content mod: $CONTENT" >&2; exit 1; }
command -v jq >/dev/null || { echo "missing jq" >&2; exit 1; }

SCRATCH=$(mktemp -d /tmp/opencode/wstweaks-home.XXXXXX)
export HORIZON_HOME=$SCRATCH/game
export HORIZON_LAUNCHER_HOME=$SCRATCH/launcher
export XDG_DATA_HOME=$SCRATCH/data
export XDG_CONFIG_HOME=$SCRATCH/config
export HORIZON_NO_AUDIO=1
mkdir -p "$(dirname "$SOCK")"
rm -f "$SOCK"
# The game's game folder (saves, options, its own caches) defaults to the
# working directory: run from the scratch home so nothing lands in the port.
# The port's config lives in the game folder's config/.
cd "$SCRATCH"
CONFIG=$SCRATCH/game/config/wstweaks.toml
mkdir -p "$SCRATCH/game/config"
printf 'shard_drop_chance = 1.0\n' > "$CONFIG"

ctl() { "$CTL" --socket "$SOCK" "$@"; }

cleanup() {
    ctl quit >/dev/null 2>&1 || true
    sleep 2
    rm -rf "$SCRATCH" 2>/dev/null || true
}
# Print the run's real exit status: `PASS:` alone is not exit-status evidence.
finish() {
    local status=$?
    # DIAG=1: dump the mod's own decision log before the scratch home goes away.
    if [ "${DIAG:-0}" = 1 ] && [ -f "$HORIZON_HOME/logs/latest.log" ]; then
        echo "-- DIAG: [wstweaks] decisions --"
        grep -a '\[wstweaks\]' "$HORIZON_HOME/logs/latest.log" \
            | grep -aE 'DIAG (hurt|behead|loot entity=)' | tail -120
    fi
    cleanup
    printf 'EXIT:%s\n' "$status" >> "$LOG"
    echo "EXIT:$status"
}
trap finish EXIT

# A fresh, undamaged bow in the main hand, dropped every time (chance 2.0).
# No `components` block at all: the cleanup must remove it without any damage
# predicate (upstream `WSTEvents.java:52-56`).
FRESH_BOW='equipment:{mainhand:{id:"minecraft:bow",count:1}},drop_chances:{mainhand:2.0f}'

expect() { # expect <token> <json>
    case "$2" in
        *"$1"*) ;;
        *) echo "FAIL: expected $1 in: $2" >&2; exit 1 ;;
    esac
}
fail() { echo "FAIL: $*" >&2; exit 1; }
# Number of dropped stacks of an item in an `entities ... item` reply.
count_items() { # count_items <json> <item id>
    printf '%s' "$1" | jq -r --arg i "$2" '[.entities[]? | select(.item.item == $i)] | length'
}
mob_id() { # mob_id <type without namespace>
    ctl entities 10 "$1" 2>/dev/null | jq -r --arg t "minecraft:$1" \
        '[.entities[] | select(.type == $t) | .id] | first // empty' || true
}
mob_health() { # mob_health <type without namespace>
    ctl entities 10 "$1" 2>/dev/null | jq -r --arg t "minecraft:$1" \
        '[.entities[] | select(.type == $t) | .health] | first // empty' || true
}
health_lt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 < b + 0) }'; }
health_eq() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 == b + 0) }'; }

launch() { # launch [WORLD]
    local world=${1:-$WORLD}
    rm -f "$SOCK"
    local args=(--game "$GAME" --world "$world" --creative --headless --wait
                --game-dir "$SCRATCH/game" --resources "$RES")
    if [ "$EMBEDDED" = 1 ]; then
        echo "  launch: no --dev-mod; the bundle carries its own content" >&2
    else
        args+=(--dev-mod "$CONTENT")
    fi
    "$CTL" --socket "$SOCK" launch "${args[@]}"
    ctl wait-ready 120
}

# The `.horizon-cache` folder the helper writes into is relative to the game's
# working directory; accept either the scratch root or the `--game-dir` game
# folder, so the check does not depend on the launcher's cwd choice.
cache_file() { # cache_file <name>
    local name=$1 path
    for path in "$SCRATCH/.horizon-cache/$name" "$SCRATCH/game/.horizon-cache/$name"; do
        if [ -f "$path" ]; then printf '%s' "$path"; return 0; fi
    done
    return 1
}

# The control for EMBEDDED=1: the same binary (every hook is in it) with the
# embedded content made unavailable — `.horizon-cache` is a plain file, so the
# helper can neither compare nor write its content file and falls back to
# `Continue`. Both carried item ids must then be unknown; if they resolve, the
# run proves nothing about the embedded file.
control_leg() {
    echo "== control: the same game with no embedded content file =="
    rm -rf "$SCRATCH/.horizon-cache" "$SCRATCH/game/.horizon-cache"
    mkdir -p "$SCRATCH/game"
    : > "$SCRATCH/.horizon-cache"
    : > "$SCRATCH/game/.horizon-cache"
    launch "$CONTROL_WORLD"
    ctl command "time set noon" >/dev/null
    ctl command "weather clear" >/dev/null
    local reply
    reply=$(ctl command "give @s wstweaks:immolation_blade" 2>&1 || true)
    echo "  blade give reply: $(tr -d '\n' <<<"$reply" | cut -c1-200)"
    reply=$(ctl command "give @s wstweaks:fragment" 2>&1 || true)
    echo "  fragment give reply: $(tr -d '\n' <<<"$reply" | cut -c1-200)"
    ctl command "give @s minecraft:stick" >/dev/null
    ctl wait 4 >/dev/null
    ctl inventory | jq -e '[.hotbar[], .main[] | select(.item == "wstweaks:immolation_blade" or .item == "wstweaks:fragment")] | length == 0' >/dev/null \
        || fail "the control game has a wstweaks item, so the content did not come from the embedded file"
    ctl inventory | jq -e '[.hotbar[], .main[] | select(.item == "minecraft:stick")] | length >= 1' >/dev/null \
        || fail "the control game cannot even give a vanilla item: the check is not a valid control"
    [ -f "$SCRATCH/.horizon-cache" ] || fail "the control's .horizon-cache was replaced: the helper wrote its content"
    echo "  without the embedded file: no wstweaks item, a vanilla stick still lands"
    ctl quit >/dev/null 2>&1 || true
    # The next launch reuses the scratch home and the game folder: wait until
    # this game is gone so its exit cannot race the main run's content write.
    for _ in $(seq 1 60); do
        ctl state >/dev/null 2>&1 || break
        sleep 0.5
    done
    rm -f "$SCRATCH/.horizon-cache" "$SCRATCH/game/.horizon-cache"
}

# EMBEDDED=1: the bundle must have written its content out at startup, byte for
# byte the delivered content mod.
embedded_content_check() {
    local cache
    for _ in $(seq 1 20); do
        cache=$(cache_file wstweaks-embedded-content.hmod) && break
        sleep 0.5
    done
    if [ -z "${cache:-}" ] || [ ! -f "$cache" ]; then
        echo "  no embedded content written; cache locations seen:" >&2
        find "$SCRATCH" -maxdepth 3 -name '.horizon-cache' -o -maxdepth 3 -name '*embedded-content.hmod' 2>/dev/null | head -5 >&2
        fail "the bundle did not write its embedded content into .horizon-cache/"
    fi
    cmp -s "$cache" "$PORT/content/wstweaks.hmod" \
        || fail "the embedded content differs from content/wstweaks.hmod"
    echo "  embedded content: $(wc -c < "$cache" | tr -d ' ') B at $cache, identical to content/wstweaks.hmod"
}

echo "== launch (world WsTweaksE2E) =="
if [ "$CONTROL" = 1 ]; then control_leg; fi
launch
if [ "$EMBEDDED" = 1 ]; then embedded_content_check; fi
ctl command "time set noon"
ctl command "weather clear"
ctl command "difficulty normal"
ctl command "kill @e[type=!player]"
ctl tp 0 64 0
sleep 1

echo "== nether: force-load the spawn chunk =="
ctl command "execute in minecraft:the_nether run forceload add 0 0"
sleep 5

echo "== conversion: Nether skeleton -> wither skeleton =="
ctl command "execute in minecraft:the_nether run summon minecraft:skeleton 0 64 0"
sleep 1
out=$(ctl command "execute in minecraft:the_nether if entity @e[type=minecraft:wither_skeleton,x=0,y=64,z=0,distance=..4] run say NETHER_CONVERTED")
echo "$out"
if [ "$WANT_CONVERTED" = 1 ]; then
    expect NETHER_CONVERTED "$out"
else
    case "$out" in
        *NETHER_CONVERTED*) fail "NEGATIVE: the Nether skeleton converted, but this leg expects it not to" ;;
    esac
    echo "NEGATIVE leg reached the conversion assertion as designed"
fi
# `Give Bows` (default true): the replacement holds a fresh bow
# (`WSTEvents.java:39-42`), read from the entity's saved equipment.
equipment=$(ctl command 'execute in minecraft:the_nether run data get entity @e[type=minecraft:wither_skeleton,x=0,y=64,z=0,distance=..4,limit=1] equipment')
echo "converted equipment: $equipment"
case "$equipment" in
    *minecraft:bow*) ;;
    *) fail "the converted skeleton has no bow: $equipment" ;;
esac

echo "== conversion: Nether stray -> wither skeleton =="
# Remove the skeleton's replacement first: a wither skeleton left at (0,64,0)
# would satisfy the check below even if the stray never converted.
ctl command "execute in minecraft:the_nether run kill @e[type=minecraft:wither_skeleton]"
sleep 1
ctl command "execute in minecraft:the_nether run summon minecraft:stray 0 64 0"
sleep 1
left=$(ctl command "execute in minecraft:the_nether if entity @e[type=minecraft:stray,x=0,y=64,z=0,distance=..4] run say STRAY_LEFT_BEHIND")
case "$left" in
    *STRAY_LEFT_BEHIND*) echo "FAIL: Nether stray was not converted: $left" >&2; exit 1 ;;
esac
out=$(ctl command "execute in minecraft:the_nether if entity @e[type=minecraft:wither_skeleton,x=0,y=64,z=0,distance=..4] run say STRAY_CONVERTED")
echo "$out"
expect STRAY_CONVERTED "$out"
ctl command "execute in minecraft:the_nether run kill @e[type=minecraft:wither_skeleton]"
sleep 1

echo "== control: Overworld skeleton stays a skeleton =="
ctl command "summon minecraft:skeleton 3 64 0"
sleep 1
out=$(ctl command "execute if entity @e[type=minecraft:skeleton,x=3,y=64,z=0,distance=..4] run say OVERWORLD_KEPT")
echo "$out"
expect OVERWORLD_KEPT "$out"
ctl command "kill @e[type=minecraft:skeleton]"

echo "== content: both items are giveable =="
ctl give wstweaks:fragment 1 >/dev/null || fail "cannot give wstweaks:fragment"
ctl give wstweaks:immolation_blade 1 >/dev/null || fail "cannot give wstweaks:immolation_blade"
ctl give minecraft:wooden_sword 1 >/dev/null || fail "cannot give the control sword"
sleep 1
inv=$(ctl inventory)
echo "$inv"
fragments=$(printf '%s' "$inv" | jq -r '(.counts["wstweaks:fragment"] // 0)')
blades=$(printf '%s' "$inv" | jq -r '(.counts["wstweaks:immolation_blade"] // 0)')
[ "$fragments" -ge 1 ] || fail "wstweaks:fragment is missing from the inventory"
[ "$blades" -ge 1 ] || fail "wstweaks:immolation_blade is missing from the inventory"
echo "inventory: fragment=$fragments blade=$blades"

echo "== drop cleanup: fresh undamaged bow is not dropped =="
# Control: a zombie (not skeleton family) keeps the identical fresh bow, so
# the equipment drop and its forced chance are known to work in this build.
# `NoAI` keeps the control and the test mobs where they were summoned, in
# reach of the query.
ctl command "summon minecraft:zombie 5 64 0 {$FRESH_BOW,NoAI:1b}"
sleep 1
ctl command "kill @e[type=minecraft:zombie]"
sleep 2
control=$(ctl entities 12 item)
echo "-- zombie control items:"; echo "$control"
expect minecraft:bow "$control"

ctl command "kill @e[type=minecraft:item]"
sleep 1

# Three wither skeletons with the same fresh bow: the port removes each bow
# from the rolled drops, so the ground must hold bones/coal (or nothing) but
# never a bow.
for x in 4 5 6; do
    ctl command "summon minecraft:wither_skeleton $x 64 0 {$FRESH_BOW,NoAI:1b}"
done
sleep 1
ctl command "kill @e[type=minecraft:wither_skeleton]"
sleep 2
echo "-- dropped items near (no minecraft:bow expected):"
items=$(ctl entities 8 item)
echo "$items"
wide=$(ctl entities 12 item)
[ "$wide" = "$items" ] || echo "(radius 12) $wide"
case "$items$wide" in
    *minecraft:bow*) echo "FAIL: a cleaned fresh bow was dropped: $wide" >&2; exit 1 ;;
esac

echo "== fragment: Shard Drop Chance=1 drops one =="
ctl command "kill @e[type=minecraft:item]"
for x in 4 5 6; do
    ctl command "summon minecraft:wither_skeleton $x 64 0 {NoAI:1b}"
done
sleep 1
ctl command "kill @e[type=minecraft:wither_skeleton]"
sleep 2
items=$(ctl entities 12 item)
echo "$items"
chance_one=$(count_items "$items" wstweaks:fragment)
echo "fragments at chance 1: $chance_one"
[ "$chance_one" -ge 1 ] || fail "no fragment dropped at Shard Drop Chance=1"

echo "== fragment: Shard Drop Chance=0 drops none =="
printf 'shard_drop_chance = 0.0\n' > "$CONFIG"
sleep 2
ctl command "kill @e[type=minecraft:item]"
for x in 4 5 6; do
    ctl command "summon minecraft:wither_skeleton $x 64 0 {NoAI:1b}"
done
sleep 1
ctl command "kill @e[type=minecraft:wither_skeleton]"
sleep 2
items=$(ctl entities 12 item)
echo "$items"
chance_zero=$(count_items "$items" wstweaks:fragment)
echo "fragments at chance 0: $chance_zero"
[ "$chance_zero" -eq 0 ] || fail "a fragment dropped at Shard Drop Chance=0"

echo "== conversion: Give Bows=false leaves the converted mob bare =="
printf 'shard_drop_chance = 1.0\ngive_bows = false\n' > "$CONFIG"
sleep 2
ctl command "execute in minecraft:the_nether run kill @e[type=minecraft:wither_skeleton]"
sleep 1
ctl command "execute in minecraft:the_nether run summon minecraft:skeleton 0 64 0"
sleep 2
bare=$(ctl command "execute in minecraft:the_nether if entity @e[type=minecraft:wither_skeleton,x=0,y=64,z=0,distance=..4] run say CONVERTED_BARE")
echo "$bare"
expect CONVERTED_BARE "$bare"
equipment=$(ctl command 'execute in minecraft:the_nether run data get entity @e[type=minecraft:wither_skeleton,x=0,y=64,z=0,distance=..4,limit=1] equipment')
echo "bare equipment: $equipment"
case "$equipment" in
    *minecraft:bow*) fail "Give Bows=false still equipped a bow: $equipment" ;;
esac
ctl command "execute in minecraft:the_nether run kill @e[type=minecraft:wither_skeleton]"
printf 'shard_drop_chance = 1.0\n' > "$CONFIG"
sleep 2

echo "== blade: sets an iron golem on fire, a wooden sword does not =="
ctl command "kill @e[type=minecraft:wither_skeleton]"
ctl command "kill @e[type=minecraft:skeleton]"
ctl command "kill @e[type=minecraft:zombie]"
ctl command "kill @e[type=minecraft:iron_golem]"
ctl command "kill @e[type=minecraft:item]"
# The player is on the ground (~y=56), so put a platform at y=63 and stand on
# it at y=64: the test mobs are summoned at y=64 and must be in attack reach.
ctl fill -6 63 -6 8 63 8 minecraft:stone
ctl tp 0 64 0
ctl command "summon minecraft:iron_golem 2 64 0 {NoAI:1b}"
sleep 1
golem=$(mob_id iron_golem)
[ -n "$golem" ] || fail "no iron golem to hit with the blade"
ctl select wstweaks:immolation_blade >/dev/null || fail "cannot select the blade"
before=$(mob_health iron_golem)
[ -n "$before" ] || fail "no health reading for the blade golem"
ctl attack "$golem" >/dev/null || fail "the blade swing missed the golem"
sleep 1
after_hit=$(mob_health iron_golem)
sleep 4
after_fire=$(mob_health iron_golem)
echo "blade golem health: $before -> $after_hit -> $after_fire"
health_lt "$after_hit" "$before" || fail "the blade hit did not damage the golem"
health_lt "$after_fire" "$after_hit" || fail "the blade did not set the golem on fire"

ctl command "kill @e[type=minecraft:iron_golem]"
ctl command "kill @e[type=minecraft:item]"
ctl command "summon minecraft:iron_golem 2 64 0 {NoAI:1b}"
sleep 1
golem=$(mob_id iron_golem)
[ -n "$golem" ] || fail "no iron golem for the wooden-sword control"
ctl select minecraft:wooden_sword >/dev/null || fail "cannot select the wooden sword"
before=$(mob_health iron_golem)
[ -n "$before" ] || fail "no health reading for the wooden-sword golem"
ctl attack "$golem" >/dev/null || fail "the wooden-sword swing missed the golem"
sleep 1
after_hit=$(mob_health iron_golem)
sleep 4
after_fire=$(mob_health iron_golem)
echo "wooden-sword golem health: $before -> $after_hit -> $after_fire"
health_lt "$after_hit" "$before" || fail "the wooden sword did not damage the golem"
health_eq "$after_fire" "$after_hit" || fail "the wooden sword set the golem on fire"

echo "== blade: a blade kill guarantees a skeleton skull =="
# Control: an ordinary death of the same mob drops no skeleton skull (vanilla
# skeletons only drop one from a charged creeper).
ctl command "kill @e[type=minecraft:iron_golem]"
ctl command "kill @e[type=minecraft:skeleton]"
ctl command "kill @e[type=minecraft:item]"
ctl command "summon minecraft:skeleton 2 64 0 {NoAI:1b}"
sleep 1
ctl command "kill @e[type=minecraft:skeleton]"
sleep 2
items=$(ctl entities 10 item)
echo "-- ordinary skeleton death items:"; echo "$items"
[ "$(count_items "$items" minecraft:skeleton_skull)" -eq 0 ] \
    || fail "an ordinary skeleton death dropped a skeleton skull"

ctl command "kill @e[type=minecraft:item]"
ctl command "summon minecraft:skeleton 2 64 0 {NoAI:1b}"
sleep 1
skeleton=$(mob_id skeleton)
[ -n "$skeleton" ] || fail "no skeleton for the blade beheading"
ctl select wstweaks:immolation_blade >/dev/null || fail "cannot select the blade"
echo "blade phase target: id=$skeleton"
ctl attack "$skeleton" >/dev/null || fail "the blade swing missed the skeleton"
echo "blade phase held after the swing: $(ctl inventory | jq -c '{selected, held}')"
echo "skeletons after the swing: $(ctl entities 10 skeleton | jq -c '[.entities[] | {id, health, distance}]')"
# The blade sets health 1 and kills; give the death/loot tick (and, if the
# instant kill lost a race, the fire) time to land before reading the drops.
sleep 5
items=$(ctl entities 10 item)
echo "-- blade-killed skeleton items:"; echo "$items"
[ "$(count_items "$items" minecraft:skeleton_skull)" -ge 1 ] \
    || fail "the blade kill did not guarantee a skeleton skull"

ctl quit >/dev/null 2>&1 || true
sleep 2
trap - EXIT
rm -rf "$SCRATCH" 2>/dev/null || true
echo "done: nether skeleton + stray converted, overworld skeleton kept, items giveable, fragment chance 1 -> drop / chance 0 -> none, blade burns but wooden sword does not, blade kill beheads a skeleton"
echo "PASS: wstweaks slice 2 (conversion with a fresh bow and Give Bows=false bare, cleanup, fragment chance 1/0, blade fire differential, blade beheading)"
echo "EXIT:0"
