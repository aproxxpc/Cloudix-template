#!/usr/bin/env bash

echo "=== [Cloudix] Starting Automated Desktop & Audio Services ==="
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="${HOME}/.config/cloudix"
AUTH_FILE="${CONFIG_DIR}/credentials"
SETUP_TOKEN_FILE="${CONFIG_DIR}/setup-token"
mkdir -p "$CONFIG_DIR"
rm -f "$SETUP_TOKEN_FILE"
AUTH_USERNAME="cloudix"
if [ -s "$AUTH_FILE" ]; then
    EXISTING_USER="$(sed -n 's/^username=//p' "$AUTH_FILE" | head -n 1)"
    if [ -n "$EXISTING_USER" ]; then
        AUTH_USERNAME="$EXISTING_USER"
    fi
fi
printf 'username=%s\n' "$AUTH_USERNAME" > "$AUTH_FILE"
chmod 600 "$AUTH_FILE"

# 0. Kill stale service processes before starting this workspace's version
pkill -9 -f x11vnc 2>/dev/null || true
pkill -9 -f websockify 2>/dev/null || true
pkill -9 -f xfce4 2>/dev/null || true
pkill -9 -f Xvfb 2>/dev/null || true
pkill -9 -f cloudflared 2>/dev/null || true
pkill -9 -f audio_streamer.py 2>/dev/null || true
sudo nginx -s stop -c "$REPO_DIR/.devcontainer/nginx.conf" 2>/dev/null || true
sudo pkill -9 nginx 2>/dev/null || true

# 1.5 Fix DBus machine-id & X11 Unix socket permissions (Prevents Black Screen & D-Bus crash)
sudo dbus-uuidgen --ensure=/etc/machine-id 2>/dev/null || true
sudo mkdir -p /var/lib/dbus 2>/dev/null || true
sudo dbus-uuidgen --ensure=/var/lib/dbus/machine-id 2>/dev/null || true
sudo rm -f /tmp/.X1-lock 2>/dev/null || true
sudo mkdir -p /tmp/.X11-unix 2>/dev/null || true
sudo chmod 1777 /tmp/.X11-unix 2>/dev/null || true

# 2. Use a balanced 16-bit display so desktop UI scales to a more normal size
export DISPLAY=:1
nohup Xvfb :1 -screen 0 960x540x16 -ac +extension GLX +render -noreset </dev/null > /tmp/xvfb.log 2>&1 &
sleep 2

# 3. Start PulseAudio Virtual Sound Card
pulseaudio -D --exit-idle-time=-1 2>/dev/null || true
sleep 1
if ! pactl list short sinks | awk '$2 == "Speaker" { found = 1 } END { exit !found }'; then
    pactl load-module module-null-sink sink_name=Speaker \
        sink_properties=device.description="Speaker" >/dev/null || {
        echo "ERROR: Could not create the desktop audio sink."
        exit 1
    }
fi
pactl set-default-sink Speaker 2>/dev/null || true
pactl set-default-source Speaker.monitor 2>/dev/null || true
pactl set-sink-mute Speaker 0 2>/dev/null || true
pactl set-sink-volume Speaker 100% 2>/dev/null || true
export CLOUDIX_AUDIO_SOURCE=Speaker.monitor
python3 - <<'PY'
import re
import subprocess

module_lines = subprocess.check_output(
    ["pactl", "list", "short", "modules"], text=True
).splitlines()
null_sink_modules = {
    int(parts[0])
    for line in module_lines
    if len(parts := line.split(maxsplit=2)) == 3
    and parts[1] == "module-null-sink"
    and re.search(r"(?:^|\s)sink_name=Speaker(?:\s|$)", parts[2])
}

for line in subprocess.check_output(
    ["pactl", "list", "short", "sink-inputs"], text=True
).splitlines():
    sink_input_id = line.split(maxsplit=1)[0]
    subprocess.run(
        ["pactl", "move-sink-input", sink_input_id, "Speaker"], check=True
    )

sink_blocks = re.split(r"(?m)^Sink #", subprocess.check_output(
    ["pactl", "list", "sinks"], text=True
))
for block in sink_blocks[1:]:
    name = re.search(r"(?m)^\s*Name:\s*(\S+)", block)
    owner = re.search(r"(?m)^\s*Owner Module:\s*(\d+)", block)
    if (
        name
        and name.group(1).startswith("Speaker.")
        and owner
        and int(owner.group(1)) in null_sink_modules
    ):
        subprocess.run(["pactl", "unload-module", owner.group(1)], check=True)
PY

# 3.5 Keep noVNC stock except for the user-activated audio control
sudo python3 - <<'PY'
import re
from pathlib import Path

novnc_dir = Path("/usr/share/novnc")
page = novnc_dir / "vnc.html"
if page.exists():
    html = page.read_text()
    html = re.sub(
        r'\s*<script type="module" id="cloudix_gamepad_module"[^>]*></script>',
        "",
        html,
    )
    html = re.sub(
        r'\s*<script id="cloudix_sound_engine">.*?</script>',
        "",
        html,
        flags=re.DOTALL,
    )
    html = html.replace("\n        window.cloudixUI = UI;", "")
    html = re.sub(
        r'\s*<script defer id="cloudix_audio_module"[^>]*></script>',
        "",
        html,
    )
    script_tag = '<script defer id="cloudix_audio_module" src="./cloudix_audio.js?v=audio-only-1"></script>'
    if script_tag not in html:
        if "</body>" not in html:
            raise SystemExit("Could not find closing body tag in noVNC vnc.html")
        html = html.replace("</body>", f"{script_tag}\n</body>", 1)
    page.write_text(html)

ui = novnc_dir / "app/ui.js"
if ui.exists():
    source = ui.read_text()
    cleaned_source = source.replace("\nwindow.cloudixUI = UI;", "")
    if source != cleaned_source:
        ui.write_text(cleaned_source)

PY
sudo install -m 0644 "$REPO_DIR/.devcontainer/browser_audio.js" \
    /usr/share/novnc/cloudix_audio.js

# 4. Start XFCE Desktop session with compositing disabled (zero lag)
export DISPLAY=:1
DBUS_LAUNCH_OUTPUT="$(dbus-launch --sh-syntax)"
DBUS_SESSION_BUS_ADDRESS="$(
    printf '%s\n' "$DBUS_LAUNCH_OUTPUT" |
        sed -n "s/^DBUS_SESSION_BUS_ADDRESS='\([^']*\)';$/\1/p"
)"
DBUS_SESSION_BUS_PID="$(
    printf '%s\n' "$DBUS_LAUNCH_OUTPUT" |
        sed -n "s/^DBUS_SESSION_BUS_PID=\([0-9][0-9]*\);$/\1/p"
)"
if [ -z "$DBUS_SESSION_BUS_ADDRESS" ] || [ -z "$DBUS_SESSION_BUS_PID" ]; then
    echo "ERROR: Could not start the desktop session bus."
    exit 1
fi
export DBUS_SESSION_BUS_ADDRESS DBUS_SESSION_BUS_PID
nohup xfce4-session </dev/null > /tmp/xfce4-session.log 2>&1 &
sleep 2
xfconf-query -c xfwm4 -p /general/use_compositing -s false 2>/dev/null || true
if pgrep -u "$USER" -x xfdesktop >/dev/null; then
    xfdesktop --reload
else
    nohup xfdesktop </dev/null > /tmp/xfdesktop.log 2>&1 &
fi

# 4.1 Apply Ubuntu's Yaru appearance while keeping the lightweight XFCE session
xfconf-query -c xsettings --create -p /Net/ThemeName -t string -s Yaru
xfconf-query -c xsettings --create -p /Net/IconThemeName -t string -s Yaru
xfconf-query -c xsettings --create -p /Gtk/FontName -t string -s "Ubuntu 10"
xfconf-query -c xfwm4 --create -p /general/theme -t string -s Yaru
xfconf-query -c xfce4-panel --create -p /panels/panel-1/size -t int -s 32
xfconf-query -c xfce4-panel --create -p /panels/panel-1/icon-size -t int -s 22
xfconf-query -c xfce4-panel --create -p /panels/panel-1/position -t string -s "p=6;x=0;y=0"
xfconf-query -c xfce4-panel --create -p /panels/panel-1/length -t int -s 100
xfconf-query -c xfce4-panel --create -p /panels/panel-2/size -t int -s 42
xfconf-query -c xfce4-panel --create -p /panels/panel-2/icon-size -t int -s 32
xfconf-query -c xfce4-panel --create -p /panels/panel-2/mode -t int -s 0
xfconf-query -c xfce4-panel --create -p /panels/panel-2/position -t string -s "p=10;x=0;y=0"
xfconf-query -c xfce4-panel --create -p /panels/panel-2/length -t int -s 1
xfconf-query -c xfce4-panel --create -p /panels/panel-2/length-adjust -t bool -s true
xfconf-query -c xfce4-panel --create -p /panels/panel-2/autohide-behavior -t int -s 1
xfconf-query -c xfce4-desktop --create -p /desktop-icons/style -t int -s 2
xfconf-query -c xfce4-desktop --create -p /desktop-icons/icon-size -t int -s 36
xfconf-query -c xfce4-desktop --create -p /desktop-icons/file-icons/show-home -t bool -s true
xfconf-query -c xfce4-desktop --create -p /desktop-icons/file-icons/show-trash -t bool -s true
xfconf-query -c xfce4-desktop --create -p /desktop-icons/file-icons/show-filesystem -t bool -s true
xfconf-query -c xfce4-desktop --create -p /backdrop/screen0/monitorscreen/workspace0/image-style -t int -s 5
xfconf-query -c xfce4-panel -p /plugins/plugin-1 -s whiskermenu
xfconf-query -c xfce4-panel --create -p /plugins/plugin-1/show-button-title -t bool -s true
xfconf-query -c xfce4-panel --create -p /plugins/plugin-1/button-title -t string -s Applications
xfconf-query -c xfce4-panel --create -p /plugins/plugin-1/show-button-icon -t bool -s true
xfconf-query -c xfce4-panel --create -p /plugins/plugin-1/button-icon -t string -s start-here
WALLPAPER="$(find /usr/share/backgrounds -maxdepth 2 -type f -iname 'Numbat_wallpaper_light*' -print -quit)"
if [ -z "$WALLPAPER" ]; then
    WALLPAPER=/usr/share/backgrounds/xfce/xfce-blue.jpg
fi
xfconf-query -c xfce4-desktop --create \
    -p /backdrop/screen0/monitorscreen/image-path -t string -s "$(dirname "$WALLPAPER")"
for workspace in 0 1 2 3; do
    xfconf-query -c xfce4-desktop --create \
        -p "/backdrop/screen0/monitorscreen/workspace${workspace}/last-image" \
        -t string -s "$WALLPAPER"
    xfconf-query -c xfce4-desktop --create \
        -p "/backdrop/screen0/monitorscreen/workspace${workspace}/image-style" \
        -t int -s 5
done
bash "$REPO_DIR/.devcontainer/update_desktop.sh"
xfce4-panel --restart
sleep 2

# 5. Keep idle polling light and shorten screen response during user input
nohup x11vnc -display :1 -rfbport 5900 -localhost -nopw -forever -shared -repeat \
    -nowf -wait 10 -defer 10 -wait_ui 2 </dev/null > /tmp/x11vnc.log 2>&1 &
sleep 2

# 6. Start Real-time Audio Streamer on port 6081
nohup python3 "$REPO_DIR/.devcontainer/audio_streamer.py" </dev/null > /tmp/audio_streamer.log 2>&1 &
sleep 1
AUDIO_READY=0
for _ in $(seq 1 15); do
    if curl --silent http://127.0.0.1:6081/health | grep -q "OK"; then
        AUDIO_READY=1
        echo "=== [Cloudix Audio] Audio streamer & status API is active on port 6081 ==="
        break
    fi
    sleep 1
done
if [ "$AUDIO_READY" -ne 1 ]; then
    echo "WARNING: audio_streamer.py did not respond on port 6081 within 15 seconds. Log:"
    cat /tmp/audio_streamer.log 2>/dev/null || true
fi

# 7. Start Websockify and Unified Nginx Proxy on port 6080
if ! command -v nginx >/dev/null 2>&1; then
    echo "ERROR: nginx is required to serve the desktop web interface."
    exit 1
fi
nohup websockify 127.0.0.1:6082 localhost:5900 </dev/null > /tmp/websockify.log 2>&1 &
if ! sudo nginx -c "$REPO_DIR/.devcontainer/nginx.conf"; then
    echo "ERROR: Could not start nginx proxy."
    exit 1
fi
sleep 2

# Confirm nginx and upstream setup-status/health are serving 200 before opening tunnel.
PROXY_STATUS="$(curl --silent --output /dev/null --write-out '%{http_code}' \
    http://127.0.0.1:6080/vnc.html)"
HEALTH_STATUS="$(curl --silent --output /dev/null --write-out '%{http_code}' \
    http://127.0.0.1:6080/api/health)"
if [ "$PROXY_STATUS" != 200 ] || [ "$HEALTH_STATUS" != 200 ]; then
    echo "ERROR: Local proxy check failed (vnc=$PROXY_STATUS, health=$HEALTH_STATUS); refusing to start tunnel."
    exit 1
fi

# 7.5 Keep the Codespaces forwarded port private
if [ -n "$CODESPACE_NAME" ]; then
    echo "=== [Cloudix] Keeping Codespace port 6080 private ==="
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        gh codespace ports visibility 6080:private -c "$CODESPACE_NAME" ||
            echo "WARNING: Set port 6080 visibility to Private in the Codespaces Ports tab."
    else
        echo "WARNING: Set port 6080 visibility to Private in the Codespaces Ports tab."
    fi
fi

# 8. Start public Cloudflare browser tunnel
CF_BIN="$(command -v cloudflared || true)"
if [ -z "$CF_BIN" ] && [ -x /usr/local/bin/cloudflared ]; then
    CF_BIN=/usr/local/bin/cloudflared
fi
if [ -z "$CF_BIN" ]; then
    echo "ERROR: cloudflared is not installed; cannot create a public browser link."
    exit 1
fi
: > /tmp/cloudflared.log
nohup "$CF_BIN" tunnel --url http://127.0.0.1:6080 </dev/null > /tmp/cloudflared.log 2>&1 &
TUNNEL_URL=""
for _ in $(seq 1 30); do
    TUNNEL_URL="$(grep -oE 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' /tmp/cloudflared.log 2>/dev/null | tail -n 1)"
    [ -n "$TUNNEL_URL" ] && break
    sleep 1
done
if [ -z "$TUNNEL_URL" ]; then
    echo "ERROR: Cloudflare tunnel did not provide a public URL. See /tmp/cloudflared.log."
    exit 1
fi

# Wait briefly for Cloudflare edge tunnel registration & health readiness before publishing link
for _ in $(seq 1 15); do
    if grep -q "Registered tunnel connection" /tmp/cloudflared.log 2>/dev/null; then
        if curl --silent --fail --max-time 4 "${TUNNEL_URL}/api/health" >/dev/null 2>&1; then
            break
        fi
    fi
    sleep 1
done

# 9. Print status & browser URL
echo "=========================================================="
echo "Cloudix Linux Desktop is ready."
DESKTOP_URL="${TUNNEL_URL}/vnc.html?autoconnect=true&resize=scale&quality=2&compression=1"
echo "🌐 Browser link: $DESKTOP_URL"
printf 'Cloudix browser link:\n%s\nUsername: %s\n' \
    "$DESKTOP_URL" "$AUTH_USERNAME" > "$REPO_DIR/DESKTOP_LINK.txt"
printf 'Codespace: %s\n' "${CODESPACE_NAME:-unknown}" >> "$REPO_DIR/DESKTOP_LINK.txt"
printf 'Setup required: no\n' >> "$REPO_DIR/DESKTOP_LINK.txt"

if ! command -v gh >/dev/null 2>&1 || ! gh auth status >/dev/null 2>&1; then
    echo "ERROR: GitHub CLI is not authenticated; cannot publish DESKTOP_LINK.txt."
    exit 1
fi
GITHUB_REPOSITORY="$(gh repo view --json nameWithOwner --jq .nameWithOwner)" || {
    echo "ERROR: Could not identify the Codespace repository."
    exit 1
}
DESKTOP_LINK_PATH="repos/${GITHUB_REPOSITORY}/contents/DESKTOP_LINK.txt"
DESKTOP_LINK_CONTENT="$(base64 -w0 "$REPO_DIR/DESKTOP_LINK.txt")"
DESKTOP_LINK_SHA="$(gh api "$DESKTOP_LINK_PATH" --jq .sha 2>/dev/null || true)"
GH_API_ARGS=(
    --method PUT "$DESKTOP_LINK_PATH"
    -f "message=Update Cloudix desktop link"
    -f "content=${DESKTOP_LINK_CONTENT}"
    -f "branch=main"
)
if [ -n "$DESKTOP_LINK_SHA" ]; then
    GH_API_ARGS+=(-f "sha=${DESKTOP_LINK_SHA}")
fi
if ! gh api "${GH_API_ARGS[@]}" >/dev/null; then
    echo "ERROR: Could not publish the current DESKTOP_LINK.txt to GitHub."
    exit 1
fi
echo "=========================================================="
