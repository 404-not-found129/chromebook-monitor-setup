#!/usr/bin/env bash
#
# Sets up an old Chromebook as a wireless second monitor for an Arch/Hyprland PC,
# with the Chromebook's trackpad able to drive the cursor across both screens.
#
#   PC (Arch + Hyprland)  : headless virtual output + wayvnc server + waynergy client
#   Chromebook (Debian/XFCE): fullscreen VNC viewer + deskflow server (shares trackpad)
#
# Run on the PC:          ./install.sh pc
# Run on the Chromebook:  ./install.sh chromebook
#
# Both halves are idempotent - safe to re-run.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Settings - edit these to match your setup.
# ---------------------------------------------------------------------------
PC_IP="192.168.86.161"          # Arch PC's LAN address
CHROMEBOOK_IP="192.168.86.132"  # Chromebook's LAN address
CHROMEBOOK_USER="linux"         # username on the Chromebook

MAIN_OUTPUT="DP-1"              # your real monitor (hyprctl monitors)
MAIN_POS="1366x0"               # placed right of the virtual screen
HEADLESS_MODE="1366x768@60"     # MUST match the Chromebook's panel resolution
HEADLESS_POS="0x336"            # left of main, vertically centred

VNC_PORT=5900
DESKFLOW_PORT=24800

say()  { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$1"; }
ok()   { printf '\033[1;32m[ok]\033[0m %s\n' "$1"; }

# ===========================================================================
# PC half
# ===========================================================================
install_pc() {
    say "Installing PC half (Arch + Hyprland)"

    if ! command -v pacman >/dev/null; then
        warn "This half expects Arch. Aborting."; exit 1
    fi

    say "Installing packages"
    # wayvnc  : serves the virtual screen over VNC
    # waynergy: receives trackpad input, injects it via wlroots virtual-pointer
    sudo pacman -S --needed --noconfirm wayvnc || exit 1
    if ! command -v waynergy >/dev/null; then
        # AUR - needs an AUR helper. waynergy is the only client that injects
        # through zwlr_virtual_pointer_v1, which is the sole injection path
        # Hyprland offers (it has no org.freedesktop.portal.RemoteDesktop).
        if command -v yay >/dev/null; then
            yay -S --needed --noconfirm waynergy || warn "waynergy install failed - trackpad sharing will not work"
        else
            warn "No AUR helper found. Install waynergy manually for trackpad sharing."
        fi
    fi

    say "Writing wayvnc config"
    mkdir -p "$HOME/.config/wayvnc"
    install -m 644 "$REPO_DIR/pc/wayvnc.config" "$HOME/.config/wayvnc/config"
    ok "~/.config/wayvnc/config"

    say "Installing the monitor setup script"
    mkdir -p "$HOME/.local/bin"
    install -m 755 "$REPO_DIR/pc/setup-chromebook-monitor.sh" "$HOME/.local/bin/"
    ok "~/.local/bin/setup-chromebook-monitor.sh"

    say "Patching Hyprland config"
    local hypr_lua="$HOME/.config/hypr/hyprland.lua"
    local hypr_conf="$HOME/.config/hypr/hyprland.conf"
    local target=""
    [ -f "$hypr_lua" ] && target="$hypr_lua"
    [ -z "$target" ] && [ -f "$hypr_conf" ] && target="$hypr_conf"

    if [ -z "$target" ]; then
        warn "No Hyprland config found - add the monitor rules and autostart manually:"
        warn "  monitor: $MAIN_OUTPUT at $MAIN_POS, HEADLESS-1 $HEADLESS_MODE at $HEADLESS_POS"
        warn "  autostart: ~/.local/bin/setup-chromebook-monitor.sh"
    elif grep -q "setup-chromebook-monitor" "$target"; then
        ok "Hyprland config already patched - skipping"
    elif [ "$target" = "$hypr_lua" ]; then
        cp "$target" "$target.bak.$(date +%s)"
        cat >> "$target" <<EOF

------------------------------------------------------------------
---- Chromebook second monitor (added by install.sh) ----
------------------------------------------------------------------
-- Pin both outputs explicitly. A wildcard 'position = auto' rule gets
-- re-evaluated for ALL outputs whenever the layout recalculates, which can
-- otherwise reshuffle the real monitor when the headless one appears.
-- Coordinates must stay >= 0: negative origins break composited capture.
hl.monitor({ output = "$MAIN_OUTPUT", mode = "highrr", position = "$MAIN_POS", scale = 1 })
hl.monitor({ output = "HEADLESS-1", mode = "$HEADLESS_MODE", position = "$HEADLESS_POS", scale = 1 })

hl.on("hyprland.start", function()
    hl.exec_cmd("sleep 2 && ~/.local/bin/setup-chromebook-monitor.sh")
end)
EOF
        ok "Appended to hyprland.lua (backup saved)"
    else
        cp "$target" "$target.bak.$(date +%s)"
        cat >> "$target" <<EOF

# ---- Chromebook second monitor (added by install.sh) ----
monitor = $MAIN_OUTPUT, highrr, $MAIN_POS, 1
monitor = HEADLESS-1, $HEADLESS_MODE, $HEADLESS_POS, 1
exec-once = sleep 2 && ~/.local/bin/setup-chromebook-monitor.sh
EOF
        ok "Appended to hyprland.conf (backup saved)"
    fi

    say "Keeping the status bar off the virtual screen"
    local waybar_cfg="$HOME/.config/waybar/config.jsonc"
    [ -f "$waybar_cfg" ] || waybar_cfg="$HOME/.config/waybar/config"
    if [ -f "$waybar_cfg" ]; then
        if grep -q '"output"' "$waybar_cfg"; then
            ok "waybar already has an output rule - leaving it alone"
        else
            cp "$waybar_cfg" "$waybar_cfg.bak.$(date +%s)"
            # Note: string form. An array (["!HEADLESS-1"]) silently shows no bar at all.
            sed -i '0,/^{/s//{\n    "output": "!HEADLESS-1",/' "$waybar_cfg"
            ok "waybar excluded from HEADLESS-1"
        fi
    else
        warn "No waybar config found - skipping"
    fi

    say "Opening the firewall"
    if command -v firewall-cmd >/dev/null && sudo firewall-cmd --state >/dev/null 2>&1; then
        sudo firewall-cmd --permanent --add-port=${VNC_PORT}/tcp >/dev/null
        sudo firewall-cmd --reload >/dev/null
        ok "Port ${VNC_PORT}/tcp opened"
    elif command -v ufw >/dev/null && sudo ufw status 2>/dev/null | grep -q active; then
        sudo ufw allow ${VNC_PORT}/tcp >/dev/null
        ok "Port ${VNC_PORT}/tcp opened"
    else
        ok "No active firewall detected - nothing to open"
    fi

    say "Setting up SSH key to the Chromebook (for shutdown sync)"
    if [ ! -f "$HOME/.ssh/id_ed25519" ]; then
        ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N "" -C "pc-to-chromebook" >/dev/null
        ok "Key generated"
    fi
    echo
    echo "  Run this ON THE CHROMEBOOK to authorise passwordless SSH:"
    echo
    echo "    mkdir -p ~/.ssh && echo '$(cat "$HOME/.ssh/id_ed25519.pub")' >> ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"
    echo

    say "Installing shutdown sync (PC off -> Chromebook off)"
    if [ -f "$REPO_DIR/pc/chromebook-shutdown.service" ]; then
        sudo install -m 644 "$REPO_DIR/pc/chromebook-shutdown.service" /etc/systemd/system/
        sudo systemctl daemon-reload
        sudo systemctl enable --now chromebook-shutdown.service >/dev/null 2>&1
        ok "chromebook-shutdown.service enabled"
        echo
        echo "  Also run this ON THE CHROMEBOOK so the PC may power it off:"
        echo
        echo "    echo '${CHROMEBOOK_USER} ALL=(root) NOPASSWD: /usr/sbin/poweroff' | sudo tee /etc/sudoers.d/010-poweroff && sudo chmod 440 /etc/sudoers.d/010-poweroff"
        echo
    fi

    say "PC half done - log out and back in, or restart Hyprland."
}

# ===========================================================================
# Chromebook half
# ===========================================================================
install_chromebook() {
    say "Installing Chromebook half (Debian + XFCE)"

    if ! command -v apt >/dev/null; then
        warn "This half expects Debian/Ubuntu. Aborting."; exit 1
    fi

    say "Installing packages"
    # tigervnc-viewer: displays the PC's virtual screen
    # wmctrl         : forces true fullscreen (XFCE ignores the viewer's own request)
    # deskflow       : shares this machine's trackpad/keyboard with the PC
    sudo apt update
    sudo apt install -y tigervnc-viewer wmctrl deskflow || exit 1

    say "Installing scripts"
    mkdir -p "$HOME/.local/bin"
    install -m 755 "$REPO_DIR/chromebook/vnc-fullscreen.sh" "$HOME/.local/bin/"
    install -m 755 "$REPO_DIR/chromebook/deskflow-server.sh" "$HOME/.local/bin/"
    sed -i "s|192\.168\.[0-9]*\.[0-9]*|$PC_IP|g" "$HOME/.local/bin/vnc-fullscreen.sh"
    ok "~/.local/bin/{vnc-fullscreen,deskflow-server}.sh"

    say "Installing deskflow config"
    mkdir -p "$HOME/.config/deskflow"
    install -m 644 "$REPO_DIR/chromebook/deskflow-server.conf" "$HOME/.config/deskflow/"
    ok "~/.config/deskflow/deskflow-server.conf"

    say "Installing autostart entries"
    mkdir -p "$HOME/.config/autostart"
    for f in wayvnc-autostart.desktop deskflow-server.desktop; do
        install -m 644 "$REPO_DIR/chromebook/$f" "$HOME/.config/autostart/"
        sed -i "s|/home/[^/]*/|$HOME/|g" "$HOME/.config/autostart/$f"
    done
    ok "~/.config/autostart/"

    say "Disabling screen blanking, sleep and lock"
    # A monitor that blanks or locks itself is useless.
    for p in blank-on-ac blank-on-battery dpms-on-ac-off dpms-on-ac-sleep \
             dpms-on-battery-off dpms-on-battery-sleep inactivity-on-ac \
             inactivity-on-battery inactivity-sleep-mode-on-ac \
             inactivity-sleep-mode-on-battery; do
        xfconf-query -c xfce4-power-manager -p "/xfce4-power-manager/$p" -s 0 --create -t int 2>/dev/null
    done
    xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-enabled -s false --create -t bool 2>/dev/null
    for p in /saver/enabled /lock/enabled /lock/saver-activation/enabled \
             /lock/session-activation/enabled /saver/idle-activation/enabled; do
        xfconf-query -c xfce4-screensaver -p "$p" -s false --create -t bool 2>/dev/null
    done
    pkill -x xfce4-screensaver 2>/dev/null
    ok "Power management and screensaver disabled"

    say "Chromebook half done."
    echo
    echo "  Optional, needs root:"
    echo
    echo "  Auto-login (skip the password prompt at boot):"
    echo "    sudo sed -i '/^\\[SeatDefaults\\]/a autologin-user=$USER\\nautologin-user-timeout=0' /etc/lightdm/lightdm.conf"
    echo
    echo "  Let the PC power this machine off at shutdown:"
    echo "    echo '$USER ALL=(root) NOPASSWD: /usr/sbin/poweroff' | sudo tee /etc/sudoers.d/010-poweroff && sudo chmod 440 /etc/sudoers.d/010-poweroff"
    echo
    echo "  Don't suspend when the lid closes:"
    echo "    sudo sed -i 's/^#HandleLidSwitch=.*/HandleLidSwitch=ignore/' /etc/systemd/logind.conf"
    echo
}

case "${1:-}" in
    pc)         install_pc ;;
    chromebook) install_chromebook ;;
    *)
        echo "Usage: $0 {pc|chromebook}"
        echo
        echo "  pc          - run on the Arch/Hyprland machine"
        echo "  chromebook  - run on the Debian/XFCE Chromebook"
        exit 1
        ;;
esac
