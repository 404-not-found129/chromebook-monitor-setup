#!/bin/bash
# Single-instance guard: two copies of this loop each spawn their own fullscreen
# viewer, and they fight over focus/stacking - which looks like screen flicker.
exec 9>/tmp/vnc-fullscreen.lock
flock -n 9 || exit 0

# Keep the display awake: X resets these each session.
xset s off
xset s noblank
xset -dpms

HOST=192.168.86.161
PORT=5900

# The PC boots slower than this machine and wayvnc starts late in its boot, so
# poll for the port before launching. vncviewer would otherwise pop a modal
# 'failed to connect' dialog and block forever instead of retrying.
while true; do
    until timeout 2 bash -c "</dev/tcp/$HOST/$PORT" 2>/dev/null; do
        sleep 3
    done

    vncviewer -FullScreen -FullscreenSystemKeys=0 -AlertOnFatalError=0 \
              -ReconnectOnError=0 -RemoteResize=0 -ViewOnly=1 $HOST::$PORT &
    VPID=$!
    sleep 3
    wmctrl -r :ACTIVE: -b add,fullscreen
    wait $VPID
    sleep 3
done
