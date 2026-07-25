#!/bin/bash
# Per-monitor workspaces.
#
# Hyprland binds each workspace to a monitor, so a plain "workspace 2" bind
# yanks focus to whichever monitor happens to own workspace 2 - meaning the
# Chromebook stole every switch. This maps each monitor to its own range so a
# switch always lands on the screen the cursor is on:
#
#   main monitor -> workspaces 1-10
#   Chromebook   -> workspaces 11-20
#
# Usage: hypr-workspace.sh <1-10> [move]
#   move  - send the focused window there instead of just switching

set -uo pipefail

N="${1:?usage: hypr-workspace.sh <1-10> [move]}"
ACTION="${2:-switch}"

HEADLESS_OFFSET=10

read -r CX CY < <(hyprctl cursorpos 2>/dev/null | tr -d ',')

# Which monitor is the cursor inside? Fall back to the focused one if the
# cursor is somewhere unexpected (e.g. mid-transition between outputs).
MON=$(hyprctl -j monitors 2>/dev/null | jq -r --argjson x "${CX:-0}" --argjson y "${CY:-0}" '
    (.[] | select($x >= .x and $x < (.x + .width) and $y >= .y and $y < (.y + .height)) | .name)
    // (.[] | select(.focused) | .name)' | head -1)

case "$MON" in
    HEADLESS*) TARGET=$(( N + HEADLESS_OFFSET )) ;;
    *)         TARGET=$N ;;
esac

# This Hyprland uses the Lua config parser, so dispatchers take Lua syntax --
# plain "hyprctl dispatch workspace 13" is a Lua parse error here.
if [ "$ACTION" = "move" ]; then
    hyprctl dispatch "hl.dsp.window.move({workspace = $TARGET})"
else
    hyprctl dispatch "hl.dsp.focus({workspace = $TARGET})"
fi
