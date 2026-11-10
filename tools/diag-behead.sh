#!/usr/bin/env bash
# Diagnostic (not evidence): which launch path loses the guaranteed skull?
#
# One launch per mode, each doing only the blade-behead phase of tools/e2e.sh:
#   default   --dev-mod content/ + the bundle's embedded content (the default
#             e2e leg)
#   devinert  --dev-mod content/ and the embedded helper made inert
#             (.horizon-cache/wstweaks-embedded-content.hmod is a read-only
#             file with different bytes, so the helper's write fails and it
#             falls back to Continue) — the 2026-11-09 launch mode
#   embedded  no --dev-mod; content only from the bundle's embedded copy
#
# It prints the blade identity, the target's saved state, the drop list at
# 1/2/5 seconds and every `[wstweaks] DIAG` line from the game log.
#
#   MODES="default devinert" tools/diag-behead.sh
set -uo pipefail

CLONE=${CAMPAIGN_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}
PORT=$CLONE/ports/wstweaks
CTL=${CTL:-$CLONE/ports/_shared/bin/horizon-1d63e0a5/horizon-ctl}
GAME=${GAME:-$PORT/target/horizon-cargo/fast/horizon-client}
RES=${RES:-${HORIZON_RES:-${HORIZON_RES:-$HOME/.local/horizon-client/26.3}}}
MODES=${MODES:-default}
SOCK=${SOCK:-/tmp/opencode/wstweaks-diag.sock}
LOG=${LOG:-/tmp/opencode/wstweaks-diag.log}
CONTENT=$PORT/content
WORLD=WsTweaksDiag

mkdir -p "$(dirname "$LOG")"
exec > >(tee "$LOG") 2>&1

[ -x "$CTL" ] || { echo "missing horizon-ctl: $CTL" >&2; exit 1; }
[ -x "$GAME" ] || { echo "missing horizon-client: $GAME" >&2; exit 1; }
[ -d "$RES/assets" ] || { echo "missing prepared resources: $RES" >&2; exit 1; }
command -v jq >/dev/null || { echo "missing jq" >&2; exit 1; }

SCRATCH=""
ctl() { "$CTL" --socket "$SOCK" "$@"; }
cleanup() {
    [ -n "$SCRATCH" ] && "$CTL" --socket "$SOCK" quit >/dev/null 2>&1
    sleep 2
    [ -n "$SCRATCH" ] && rm -rf "$SCRATCH" 2>/dev/null
}

run_mode() {
    local mode=$1
    SCRATCH=$(mktemp -d /tmp/opencode/wstweaks-diag-home.XXXXXX)
    export HORIZON_HOME=$SCRATCH/game
    export HORIZON_LAUNCHER_HOME=$SCRATCH/launcher
    export XDG_DATA_HOME=$SCRATCH/data
    export XDG_CONFIG_HOME=$SCRATCH/config
    export HORIZON_NO_AUDIO=1
    mkdir -p "$(dirname "$SOCK")" "$SCRATCH/game/config"
    rm -f "$SOCK"
    cd "$SCRATCH" || return 1
    printf 'shard_drop_chance = 1.0\n' > "$SCRATCH/game/config/wstweaks.toml"

    echo
    echo "================ mode $mode ================"
    if [ "$mode" = devinert ]; then
        for dir in "$SCRATCH/.horizon-cache" "$SCRATCH/game/.horizon-cache"; do
            mkdir -p "$dir"
            printf 'not the embedded content\n' > "$dir/wstweaks-embedded-content.hmod"
            chmod 0444 "$dir/wstweaks-embedded-content.hmod"
        done
    fi

    local args=(--game "$GAME" --world "$WORLD" --creative --headless --wait
                --game-dir "$SCRATCH/game" --resources "$RES")
    case "$mode" in
        default|devinert) args+=(--dev-mod "$CONTENT") ;;
        embedded) ;;
        *) echo "unknown mode $mode" >&2; return 2 ;;
    esac
    "$CTL" --socket "$SOCK" launch "${args[@]}" >/dev/null || { echo "launch failed" >&2; return 1; }
    "$CTL" --socket "$SOCK" wait-ready 120 >/dev/null
    ctl command "time set noon" >/dev/null
    ctl command "weather clear" >/dev/null
    ctl command "difficulty normal" >/dev/null
    ctl command "kill @e[type=!player]" >/dev/null
    ctl tp 0 64 0 >/dev/null
    ctl fill -6 63 -6 8 63 8 minecraft:stone >/dev/null
    ctl tp 0 64 0 >/dev/null
    sleep 1

    echo "-- content: blade giveable =="
    local reply
    reply=$(ctl give wstweaks:immolation_blade 1 2>&1)
    echo "give blade: $(tr -d '\n' <<<"$reply" | cut -c1-200)"
    reply=$(ctl give minecraft:wooden_sword 1 2>&1)
    echo "give wooden sword: $(tr -d '\n' <<<"$reply" | cut -c1-200)"
    sleep 1
    ctl inventory | jq -c '{selected, held, counts}'

    echo "-- summon skeleton at 2 64 0 =="
    local round
    for round in $(seq 1 "${ROUNDS:-1}"); do
        echo "-- round $round --"
        # Clean the ground so each round's drop list is its own.
        ctl command "kill @e[type=minecraft:item]" >/dev/null
        ctl command "kill @e[type=minecraft:skeleton]" >/dev/null
        sleep 1
        ctl command "summon minecraft:skeleton 2 64 0 {NoAI:1b}"
        sleep 1
        local skeleton
        skeleton=$(ctl entities 10 skeleton | jq -r '[.entities[] | select(.type == "minecraft:skeleton") | .id] | first // empty')
        echo "skeleton id: ${skeleton:-none}"
        [ -n "$skeleton" ] || { echo "no skeleton" >&2; return 1; }
        ctl command "data get entity @e[type=minecraft:skeleton,x=2,y=64,z=0,distance=..2,limit=1]" >/dev/null
        ctl select wstweaks:immolation_blade >/dev/null || { echo "cannot select the blade" >&2; return 1; }
        ctl inventory | jq -c '{selected, held}'
        ctl attack "$skeleton" >/dev/null || { echo "swing missed" >&2; return 1; }
        sleep 3
        echo "items at +3 s:"; ctl entities 10 item | jq -c '.entities'
        ctl entities 10 skeleton | jq -c '.entities'
    done

    echo "-- game log [wstweaks] (skeleton family) =="
    grep -h '\[wstweaks\]' "$HORIZON_HOME/logs/latest.log" 2>/dev/null | grep -E 'skeleton|behead' | tail -60

    echo "-- game log tail =="
    tail -10 "$HORIZON_HOME/logs/latest.log" 2>/dev/null

    "$CTL" --socket "$SOCK" quit >/dev/null 2>&1
    sleep 2
    rm -rf "$SCRATCH" 2>/dev/null
    SCRATCH=""
}

trap cleanup EXIT
for mode in $MODES; do
    run_mode "$mode" || echo "mode $mode did not finish"
done
trap - EXIT
echo "done: modes $MODES"
