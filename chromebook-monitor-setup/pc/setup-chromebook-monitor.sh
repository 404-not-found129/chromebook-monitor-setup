#!/bin/bash
# Creates the headless virtual monitor for the Chromebook and pins its size/position.
# Hyprland's wildcard "auto" monitor rule occasionally races with this and resets
# position/mode right after it's set, so this verifies the change actually stuck
# and retries until it does, instead of silently leaving it broken.

TARGET_MODE="1366x768@60"
TARGET_POS="0x336"

hyprctl output create headless
sleep 2

OUT=""
for i in $(seq 1 10); do
    OUT=$(hyprctl monitors | grep "^Monitor HEADLESS" | awk '{print $2}' | tail -1)
    [ -n "$OUT" ] && break
    sleep 1
done

if [ -z "$OUT" ]; then
    exit 1
fi

for i in $(seq 1 15); do
    hyprctl eval "hl.monitor({output=\"$OUT\", mode=\"$TARGET_MODE\", position=\"$TARGET_POS\", scale=1})" >/dev/null 2>&1
    sleep 1
    CURRENT=$(hyprctl monitors | grep -A1 "^Monitor $OUT " | tail -1 | awk '{print $1, $3}')
    if [ "$CURRENT" = "${TARGET_MODE}.00000 at ${TARGET_POS}" ]; then
        break
    fi
done

# waynergy receives trackpad/keyboard from the Chromebook's deskflow server and
# injects it via wlroots virtual-pointer, letting that trackpad drive the cursor
# across BOTH monitors. Retries because the Chromebook's server may not be up yet.
(
    while true; do
        waynergy -b wlr -c 192.168.86.132 -p 24800 -N archpc -L info -l "$HOME/waynergy.log"
        sleep 5
    done
) &

# Capture only the headless output. Whole-desktop capture (-a) was tried and
# fails on this wayvnc/Hyprland combo: the server accepts the connection, then
# dies with "Failed to start capture" as soon as a client attaches.
wayvnc -o "$OUT" -r -g -f 60
