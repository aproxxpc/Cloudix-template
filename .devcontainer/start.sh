#!/usr/bin/env bash
# cloudix-template-v6

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
pkill -9 -x x11vnc 2>/dev/null || true
pkill -9 -x Xtigervnc 2>/dev/null || true
pkill -9 -f websockify 2>/dev/null || true
pkill -9 -f xfce4 2>/dev/null || true
pkill -9 -x xfce4-panel 2>/dev/null || true
pkill -9 -x xfdesktop 2>/dev/null || true
pkill -9 -x xfsettingsd 2>/dev/null || true
pkill -9 -x xfwm4 2>/dev/null || true
pkill -9 -x xfconfd 2>/dev/null || true
pkill -9 -x Xvfb 2>/dev/null || true
pkill -9 -f cloudflared 2>/dev/null || true
pkill -9 -f audio_streamer.py 2>/dev/null || true
sudo nginx -s stop -c "$REPO_DIR/.devcontainer/nginx.conf" 2>/dev/null || true
sudo pkill -9 nginx 2>/dev/null || true
sleep 1

# 1.5 Fix DBus machine-id & X11 Unix socket permissions (Prevents Black Screen & D-Bus crash)
sudo dbus-uuidgen --ensure=/etc/machine-id 2>/dev/null || true
sudo mkdir -p /var/lib/dbus 2>/dev/null || true
sudo dbus-uuidgen --ensure=/var/lib/dbus/machine-id 2>/dev/null || true
sudo rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 /tmp/cloudix_boot_error.txt 2>/dev/null || true
sudo mkdir -p /tmp/.X11-unix 2>/dev/null || true
sudo chmod 1777 /tmp/.X11-unix 2>/dev/null || true

check_port_rfb() {
    python3 - <<'PY'
import socket
try:
    with socket.create_connection(("127.0.0.1", 5900), timeout=1.0) as s:
        s.settimeout(1.0)
        raise SystemExit(0 if s.recv(12).startswith(b"RFB ") else 1)
except OSError:
    raise SystemExit(1)
PY
}

# 2. Start 24-bit X display at 960x540 so desktop UI scales cleanly on mobile (prefer Xtigervnc, fallback to Xvfb + x11vnc)
export DISPLAY=:1
USING_TIGERVNC=0
if command -v Xtigervnc >/dev/null 2>&1; then
    : > /tmp/xtigervnc.log
    setsid nohup Xtigervnc :1 -geometry 960x540 -depth 24 -rfbport 5900 \
        -SecurityTypes None -interface 127.0.0.1 </dev/null > /tmp/xtigervnc.log 2>&1 &
    for _ in $(seq 1 12); do
        if [ -S /tmp/.X11-unix/X1 ] && check_port_rfb; then
            USING_TIGERVNC=1
            echo "=== [Cloudix] Xtigervnc X11+VNC server active on :1 (127.0.0.1:5900) ==="
            break
        fi
        sleep 1
    done
    if [ "$USING_TIGERVNC" -ne 1 ]; then
        echo "WARNING: Xtigervnc did not start cleanly, falling back to Xvfb. Log:"
        cat /tmp/xtigervnc.log 2>/dev/null || true
        pkill -9 -x Xtigervnc 2>/dev/null || true
        sleep 1
        sudo rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 2>/dev/null || true
    fi
fi

if [ "$USING_TIGERVNC" -ne 1 ]; then
    : > /tmp/xvfb.log
    setsid nohup Xvfb :1 -screen 0 960x540x24 -ac +extension GLX +render -noreset </dev/null > /tmp/xvfb.log 2>&1 &
    XVFB_READY=0
    for _ in $(seq 1 15); do
        if [ -S /tmp/.X11-unix/X1 ]; then
            XVFB_READY=1
            break
        fi
        sleep 1
    done
    if [ "$XVFB_READY" -ne 1 ]; then
        echo "WARNING: Xvfb failed to start on :1. Log output:"
        cat /tmp/xvfb.log 2>/dev/null || true
        tail -n 10 /tmp/xvfb.log > /tmp/cloudix_boot_error.txt 2>/dev/null || echo "Xvfb failed to start" > /tmp/cloudix_boot_error.txt
    fi
fi

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

# 4. Ensure Ubuntu UI/UX packages & panel config are ready before starting XFCE
if ! dpkg -s yaru-theme-gtk >/dev/null 2>&1 || ! dpkg -s xfce4-whiskermenu-plugin >/dev/null 2>&1 || ! command -v xrandr >/dev/null 2>&1; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        yaru-theme-gtk yaru-theme-icon fonts-ubuntu xfce4-whiskermenu-plugin \
        mousepad ristretto evince xfce4-screenshooter x11-xserver-utils desktop-file-utils >/dev/null 2>&1 || true
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ubuntu-wallpapers-noble >/dev/null 2>&1 || true
fi

XFCE_XML_DIR="${HOME}/.config/xfce4/xfconf/xfce-perchannel-xml"
PANEL_XML="${XFCE_XML_DIR}/xfce4-panel.xml"
PANEL_DIR="${HOME}/.config/xfce4/panel"
mkdir -p "$XFCE_XML_DIR" \
    "${PANEL_DIR}/launcher-17" "${PANEL_DIR}/launcher-18" \
    "${PANEL_DIR}/launcher-19" "${PANEL_DIR}/launcher-20"

VSCODE_PANEL_ICON=vscode
if [ -f /usr/share/code/resources/app/resources/linux/code.png ]; then
    VSCODE_PANEL_ICON=/usr/share/code/resources/app/resources/linux/code.png
fi
cat > "${PANEL_DIR}/launcher-17/17940020141.desktop" <<'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Google Chrome
Exec=/usr/bin/google-chrome-stable --no-sandbox --enable-webgl --enable-unsafe-swiftshader --disable-background-networking --disable-component-update --disable-sync --no-first-run %U
Icon=google-chrome
Terminal=false
StartupNotify=true
Categories=Utility;
EOF
cat > "${PANEL_DIR}/launcher-18/17940020142.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Visual Studio Code
Exec=/usr/share/code/code --no-sandbox --unity-launch %F
Icon=${VSCODE_PANEL_ICON}
Terminal=false
StartupNotify=true
Categories=Utility;
EOF
cat > "${PANEL_DIR}/launcher-19/17940020143.desktop" <<'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=File Manager
Exec=thunar
Icon=system-file-manager
Terminal=false
StartupNotify=true
Categories=Utility;
EOF
cat > "${PANEL_DIR}/launcher-20/17940020144.desktop" <<'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Terminal
Exec=/usr/bin/xfce4-terminal --disable-server
Icon=org.xfce.terminal
Terminal=false
StartupNotify=true
Categories=Utility;
EOF
chmod +x "${PANEL_DIR}"/launcher-{17,18,19,20}/*.desktop 2>/dev/null || true

if [ ! -s "$PANEL_XML" ] || ! grep -q 'whiskermenu' "$PANEL_XML" 2>/dev/null || ! grep -q 'panel-2' "$PANEL_XML" 2>/dev/null; then
    cat > "$PANEL_XML" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>

<channel name="xfce4-panel" version="1.0">
  <property name="configver" type="int" value="2"/>
  <property name="panels" type="array">
    <value type="int" value="1"/>
    <value type="int" value="2"/>
    <property name="dark-mode" type="bool" value="true"/>
    <property name="panel-1" type="empty">
      <property name="position" type="string" value="p=6;x=0;y=0"/>
      <property name="length" type="uint" value="100"/>
      <property name="position-locked" type="bool" value="true"/>
      <property name="icon-size" type="uint" value="22"/>
      <property name="size" type="uint" value="32"/>
      <property name="plugin-ids" type="array">
        <value type="int" value="1"/>
        <value type="int" value="2"/>
        <value type="int" value="3"/>
        <value type="int" value="4"/>
        <value type="int" value="5"/>
        <value type="int" value="6"/>
      </property>
    </property>
    <property name="panel-2" type="empty">
      <property name="autohide-behavior" type="uint" value="1"/>
      <property name="position" type="string" value="p=10;x=0;y=0"/>
      <property name="length" type="uint" value="1"/>
      <property name="length-adjust" type="bool" value="true"/>
      <property name="mode" type="uint" value="0"/>
      <property name="position-locked" type="bool" value="true"/>
      <property name="size" type="uint" value="42"/>
      <property name="icon-size" type="uint" value="32"/>
      <property name="plugin-ids" type="array">
        <value type="int" value="17"/>
        <value type="int" value="18"/>
        <value type="int" value="19"/>
        <value type="int" value="20"/>
      </property>
    </property>
  </property>
  <property name="plugins" type="empty">
    <property name="plugin-1" type="string" value="whiskermenu">
      <property name="show-button-title" type="bool" value="true"/>
      <property name="button-title" type="string" value="Applications"/>
      <property name="show-button-icon" type="bool" value="true"/>
      <property name="button-icon" type="string" value="start-here"/>
    </property>
    <property name="plugin-2" type="string" value="tasklist">
      <property name="flat-buttons" type="bool" value="true"/>
      <property name="show-handle" type="bool" value="false"/>
    </property>
    <property name="plugin-3" type="string" value="separator">
      <property name="expand" type="bool" value="true"/>
      <property name="style" type="uint" value="0"/>
    </property>
    <property name="plugin-4" type="string" value="systray">
      <property name="show-frame" type="bool" value="false"/>
      <property name="size-max" type="uint" value="22"/>
    </property>
    <property name="plugin-5" type="string" value="clock">
      <property name="mode" type="uint" value="2"/>
    </property>
    <property name="plugin-6" type="string" value="actions"/>
    <property name="plugin-17" type="string" value="launcher">
      <property name="items" type="array">
        <value type="string" value="17940020141.desktop"/>
      </property>
    </property>
    <property name="plugin-18" type="string" value="launcher">
      <property name="items" type="array">
        <value type="string" value="17940020142.desktop"/>
      </property>
    </property>
    <property name="plugin-19" type="string" value="launcher">
      <property name="items" type="array">
        <value type="string" value="17940020143.desktop"/>
      </property>
    </property>
    <property name="plugin-20" type="string" value="launcher">
      <property name="items" type="array">
        <value type="string" value="17940020144.desktop"/>
      </property>
    </property>
  </property>
</channel>
XML
fi

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
setsid nohup xfce4-session </dev/null > /tmp/xfce4-session.log 2>&1 &

for _ in $(seq 1 12); do
    if xfconf-query -c xsettings -l >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
for _ in $(seq 1 4); do
    if pgrep -u "$USER" -x xfdesktop >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

xfconf-query -c xfwm4 --create -p /general/use_compositing -t bool -s false 2>/dev/null || true
if ! pgrep -u "$USER" -x xfdesktop >/dev/null 2>&1; then
    setsid nohup xfdesktop </dev/null > /tmp/xfdesktop.log 2>&1 &
    sleep 1
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
xfconf-query -c xfce4-desktop --create -p /desktop-icons/single-click -t bool -s true
xfconf-query -c xfce4-desktop --create -p /desktop-icons/file-icons/show-home -t bool -s true
xfconf-query -c xfce4-desktop --create -p /desktop-icons/file-icons/show-trash -t bool -s true
xfconf-query -c xfce4-desktop --create -p /desktop-icons/file-icons/show-filesystem -t bool -s true
xfconf-query -c xfce4-panel --create -p /plugins/plugin-1 -t string -s whiskermenu
xfconf-query -c xfce4-panel --create -p /plugins/plugin-1/show-button-title -t bool -s true
xfconf-query -c xfce4-panel --create -p /plugins/plugin-1/button-title -t string -s Applications
xfconf-query -c xfce4-panel --create -p /plugins/plugin-1/show-button-icon -t bool -s true
xfconf-query -c xfce4-panel --create -p /plugins/plugin-1/button-icon -t string -s start-here

WALLPAPER="$(find /usr/share/backgrounds -maxdepth 2 -type f -iname 'Numbat_wallpaper_light*' -print -quit)"
if [ -z "$WALLPAPER" ]; then
    WALLPAPER="$(find /usr/share/backgrounds -maxdepth 2 -type f \( -iname '*.png' -o -iname '*.jpg' \) ! -iname '*xfce*' -print -quit)"
fi
if [ -z "$WALLPAPER" ]; then
    WALLPAPER=/usr/share/backgrounds/xfce/xfce-blue.jpg
fi

MONITOR_KEYS=("monitorVNC-0" "monitorscreen" "monitor0" "monitorVirtual1" "monitorHDMI-1" "monitorDP-1")
if command -v xrandr >/dev/null 2>&1; then
    while IFS= read -r out_name; do
        [ -n "$out_name" ] && MONITOR_KEYS+=("monitor${out_name}")
    done < <(xrandr --query 2>/dev/null | awk '/ connected/{print $1}')
fi
while IFS= read -r existing_mon; do
    [ -n "$existing_mon" ] && MONITOR_KEYS+=("$existing_mon")
done < <(xfconf-query -c xfce4-desktop -l 2>/dev/null | sed -n 's|^/backdrop/screen0/\([^/]*\)/.*|\1|p' | sort -u)

declare -A SEEN_MONITORS=()
for mon in "${MONITOR_KEYS[@]}"; do
    [ -n "$mon" ] || continue
    if [ -n "${SEEN_MONITORS[$mon]:-}" ]; then
        continue
    fi
    SEEN_MONITORS["$mon"]=1
    xfconf-query -c xfce4-desktop --create \
        -p "/backdrop/screen0/${mon}/image-path" -t string -s "$(dirname "$WALLPAPER")" 2>/dev/null || true
    for workspace in 0 1 2 3; do
        xfconf-query -c xfce4-desktop --create \
            -p "/backdrop/screen0/${mon}/workspace${workspace}/last-image" \
            -t string -s "$WALLPAPER" 2>/dev/null || true
        xfconf-query -c xfce4-desktop --create \
            -p "/backdrop/screen0/${mon}/workspace${workspace}/image-style" \
            -t int -s 5 2>/dev/null || true
    done
done

bash "$REPO_DIR/.devcontainer/update_desktop.sh"
xfce4-panel --restart 2>/dev/null || setsid nohup xfce4-panel </dev/null >/dev/null 2>&1 &
xfdesktop --reload 2>/dev/null || true
sleep 2

check_vnc_ready() {
    python3 - <<'PY'
import socket, time
for _ in range(15):
    try:
        with socket.create_connection(("127.0.0.1", 5900), timeout=1.0) as s:
            s.settimeout(1.0)
            banner = s.recv(12)
            if banner.startswith(b"RFB "):
                raise SystemExit(0)
    except OSError:
        pass
    time.sleep(1)
raise SystemExit(1)
PY
}

# 5. Ensure VNC server is running on IPv4 loopback port 5900
if [ "$USING_TIGERVNC" -ne 1 ]; then
    : > /tmp/x11vnc.log
    setsid nohup x11vnc -display :1 -rfbport 5900 -listen 127.0.0.1 -nopw -forever -shared -loop500 \
        -noxfixes -noxdamage -noxrecord -noshm -repeat -nowf -wait 10 -defer 10 </dev/null > /tmp/x11vnc.log 2>&1 &
fi
if ! check_vnc_ready; then
    echo "WARNING: primary VNC check did not answer RFB on 127.0.0.1:5900. Retrying safe x11vnc..."
    cat /tmp/x11vnc.log 2>/dev/null || true
    cat /tmp/xtigervnc.log 2>/dev/null || true
    pkill -9 -x x11vnc 2>/dev/null || true
    pkill -9 -x Xtigervnc 2>/dev/null || true
    sleep 1
    : > /tmp/x11vnc.log
    setsid nohup x11vnc -display :1 -rfbport 5900 -listen 127.0.0.1 -nopw -forever -shared -loop500 \
        -noxdamage -noxrecord -noshm -noxfixes -noxinerama </dev/null > /tmp/x11vnc.log 2>&1 &
    if ! check_vnc_ready; then
        echo "WARNING: VNC server is not responding on 127.0.0.1:5900."
        tail -n 10 /tmp/x11vnc.log /tmp/xtigervnc.log /tmp/xvfb.log > /tmp/cloudix_boot_error.txt 2>/dev/null || echo "VNC port 5900 not responding" > /tmp/cloudix_boot_error.txt
    fi
fi

# 6. Start Real-time Audio Streamer on port 6081
setsid nohup python3 "$REPO_DIR/.devcontainer/audio_streamer.py" </dev/null > /tmp/audio_streamer.log 2>&1 &
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

# 7. Start Websockify (explicit IPv4 127.0.0.1:5900) and Unified Nginx Proxy on port 6080
if ! command -v nginx >/dev/null 2>&1; then
    echo "ERROR: nginx is required to serve the desktop web interface."
    exit 1
fi
: > /tmp/websockify.log
setsid nohup websockify 127.0.0.1:6082 127.0.0.1:5900 </dev/null > /tmp/websockify.log 2>&1 &
if ! sudo nginx -c "$REPO_DIR/.devcontainer/nginx.conf"; then
    echo "ERROR: Could not start nginx proxy."
    exit 1
fi
sleep 2

# Confirm nginx and audio/health API are serving 200, and verify websockify + VNC listeners via kernel table.
PROXY_STATUS="$(curl --silent --output /dev/null --write-out '%{http_code}' \
    http://127.0.0.1:6080/vnc.html)"
HEALTH_STATUS="$(curl --silent --output /dev/null --write-out '%{http_code}' \
    http://127.0.0.1:6080/api/health)"
if [ "$PROXY_STATUS" != 200 ] || [ "$HEALTH_STATUS" != 200 ]; then
    echo "ERROR: Local proxy check failed (vnc=$PROXY_STATUS, health=$HEALTH_STATUS); refusing to start tunnel."
    exit 1
fi
if ! python3 - <<'PY'
from pathlib import Path
import time

def listening(port):
    target_hex = f":{port:04X}"
    for p in ("/proc/net/tcp", "/proc/net/tcp6"):
        try:
            for line in Path(p).read_text(encoding="ascii").splitlines()[1:]:
                cols = line.split()
                if len(cols) >= 4 and cols[1].endswith(target_hex) and cols[3] == "0A":
                    return True
        except OSError:
            pass
    return False

for _ in range(10):
    if listening(5900) and listening(6082):
        raise SystemExit(0)
    time.sleep(1)
raise SystemExit(1)
PY
then
    echo "WARNING: Port 5900 or 6082 not listening yet; continuing to start tunnel with diagnostics."
    tail -n 10 /tmp/websockify.log /tmp/x11vnc.log /tmp/xtigervnc.log > /tmp/cloudix_boot_error.txt 2>/dev/null || true
else
    rm -f /tmp/cloudix_boot_error.txt 2>/dev/null || true
    echo "=== [Cloudix] VNC (5900) & Websockify (6082) listeners verified active ==="
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
setsid nohup "$CF_BIN" tunnel --url http://127.0.0.1:6080 </dev/null > /tmp/cloudflared.log 2>&1 &
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

GH_READY=0
for _ in $(seq 1 5); do
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        GH_READY=1
        break
    fi
    sleep 2
done
if [ "$GH_READY" -ne 1 ]; then
    echo "ERROR: GitHub CLI is not authenticated; cannot publish DESKTOP_LINK.txt."
    exit 1
fi
GITHUB_REPOSITORY="$(gh repo view --json nameWithOwner --jq .nameWithOwner)" || {
    echo "ERROR: Could not identify the Codespace repository."
    exit 1
}
DESKTOP_LINK_PATH="repos/${GITHUB_REPOSITORY}/contents/DESKTOP_LINK.txt"
DESKTOP_LINK_CONTENT="$(base64 -w0 "$REPO_DIR/DESKTOP_LINK.txt")"
PUBLISHED_LINK=0
for _ in $(seq 1 3); do
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
    if gh api "${GH_API_ARGS[@]}" >/dev/null; then
        PUBLISHED_LINK=1
        break
    fi
    sleep 2
done
if [ "$PUBLISHED_LINK" -ne 1 ]; then
    echo "ERROR: Could not publish the current DESKTOP_LINK.txt to GitHub."
    exit 1
fi
echo "=========================================================="
