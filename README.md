# Chromebook as a wireless second monitor

Turns an old Chromebook running Debian into a second monitor for an Arch/Hyprland
PC over Wi-Fi — and lets the Chromebook's **trackpad drive the cursor across both
screens**.

```
┌──────────────────┐   VNC :5900  ──────▶ ┌───────────────────────┐
│  Chromebook      │   (video)            │  Arch PC / Hyprland   │
│  Debian + XFCE   │                      │                       │
│                  │   deskflow :24800 ──▶│  headless output      │
│  trackpad ───────┼──────────────────────┤  + real monitor       │
└──────────────────┘   (input)            └───────────────────────┘
```

## Install

```bash
git clone https://github.com/404-not-found129/chromebook-monitor-setup.git && cd chromebook-monitor-setup
```

Edit the settings block at the top of `install.sh` (IP addresses, your monitor's
output name, the Chromebook's panel resolution), then:

```bash
./install.sh pc          # on the Arch PC
./install.sh chromebook  # on the Chromebook
```

Each half prints a short list of optional root commands at the end (auto-login,
shutdown sync, lid behaviour). They're optional — everything else works without
them.

## How it works

**Display.** Hyprland creates a *headless* output — a real monitor as far as the
compositor is concerned, just with no physical panel. `wayvnc` serves that one
output over VNC; the Chromebook shows it fullscreen. Drag a window off the left
edge of your main screen and it appears on the Chromebook.

**Input.** VNC pointer input is clamped to the captured output, so the trackpad
alone can't reach the main monitor. Instead `deskflow` on the Chromebook shares
its trackpad, and `waynergy` on the PC injects those events through
`zwlr_virtual_pointer_v1` — moving the PC's real cursor across *both* screens.
The VNC viewer runs `-ViewOnly=1` so the two input paths don't fight.

## Things that cost me hours

Documented so future-me doesn't rediscover them.

**`protocol = barrier` is mandatory** in `deskflow-server.conf`. Deskflow's own
protocol (Synergy 1.8) makes waynergy fail with `Protocol error`; without any
protocol setting at all the server dies instantly with `XInvalidProtocol` the
moment a client connects. Barrier mode is the only combination that pairs.

**Monitor coordinates must be non-negative.** Putting the headless output at
`-1366x336` (left of a main monitor at `0x0`) looks fine and works for
single-output capture, but any composited capture fails with
`Attempted to configure an invalid screen layout` — VNC framebuffers start at
0,0. Place the headless output at `0x336` and shift the main monitor to `1366x0`
instead. Same physical arrangement, valid coordinates.

**Whole-desktop capture (`wayvnc -a`) does not work** on this stack. The server
accepts the connection and then exits with `Failed to start capture`. That path
would have let VNC alone handle cross-monitor input; it doesn't, hence deskflow.

**Waybar's `output` key must be a string**, not an array. `"output": "!HEADLESS-1"`
works; `"output": ["!HEADLESS-1"]` silently renders no bar on *any* screen.

**TigerVNC blocks on a modal dialog** when it can't connect, instead of exiting —
so a naive `while true; do vncviewer ...; done` retry loop hangs forever on the
first failed attempt. The PC boots slower than the Chromebook, so this happens
every single time. Fix: poll the port with `/dev/tcp` before launching, plus
`-AlertOnFatalError=0 -ReconnectOnError=0`.

**The headless output gets renamed** on every recreate — `HEADLESS-1`, then
`HEADLESS-2`, and so on within a session (it resets on reboot). Anything holding
the old name silently breaks, so `setup-chromebook-monitor.sh` discovers the name
at runtime rather than assuming it.

**Hyprland's wildcard monitor rule races with the headless output.** A
`position = auto` rule is re-evaluated for *all* outputs whenever the layout
recalculates, which can reposition the real monitor when the headless one
appears. Both outputs are pinned by name, and the setup script verifies the
placement actually stuck and retries up to 15 times.

## Not solved

**The dev-mode boot screen.** Removing the "OS verification is off" screen
requires disabling hardware write-protect, which on this board (`kappa`, an
MT8183 Chromebook) means opening the case and disconnecting the battery. Even
then the best case is a 2-second screen rather than 30. Not worth it; wait it out.

**Powering the Chromebook on remotely.** A powered-off Chromebook has no
wake-on-LAN over Wi-Fi. Shutdown syncs one way (PC off → Chromebook off); turning
it back on needs a physical button press. Alternatively, put both machines on a
switched power strip and set the PC's BIOS to power on after AC restore —
Chromebooks boot themselves when AC appears.

## Layout

```
install.sh                        both halves, idempotent
pc/
  setup-chromebook-monitor.sh     creates the headless output, starts wayvnc + waynergy
  wayvnc.config                   listen on all interfaces, port 5900
  chromebook-shutdown.service     powers the Chromebook off with the PC
chromebook/
  vnc-fullscreen.sh               fullscreen view-only viewer with reconnect loop
  deskflow-server.sh              shares the trackpad
  deskflow-server.conf            screen layout + protocol = barrier
  *.desktop                       XDG autostart entries
```
