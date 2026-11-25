#!/usr/bin/env bash

echo "=== [Cloudix] Updating Desktop Shortcuts ==="

# Create the standard Linux folders used by the file manager and sidebar.
if command -v xdg-user-dirs-update >/dev/null 2>&1; then
    xdg-user-dirs-update
fi
mkdir -p "$HOME/Desktop" "$HOME/Documents" "$HOME/Downloads" \
    "$HOME/Music" "$HOME/Pictures" "$HOME/Videos"
GTK_BOOKMARKS="${XDG_CONFIG_HOME:-$HOME/.config}/gtk-3.0/bookmarks"
mkdir -p "$(dirname "$GTK_BOOKMARKS")"
touch "$GTK_BOOKMARKS"
for folder in Documents Downloads Music Pictures Videos; do
    bookmark="file://${HOME}/${folder} ${folder}"
    if ! grep -Fqx "$bookmark" "$GTK_BOOKMARKS"; then
        printf '%s\n' "$bookmark" >> "$GTK_BOOKMARKS"
    fi
done

# Use the actual app artwork where the installed applications provide it.
GODOT_ICON_NAME=applications-games
GODOT_ICON_SOURCE=/usr/share/code/resources/app/extensions/theme-modern-icons/fileicons/images/godot.svg
GODOT_ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps"
GODOT_ICON_PATH="${GODOT_ICON_DIR}/cloudix-godot.png"
if [ -f "$GODOT_ICON_SOURCE" ] && command -v rsvg-convert >/dev/null 2>&1; then
    mkdir -p "$GODOT_ICON_DIR"
    sed 's/currentColor/#478CBF/g' "$GODOT_ICON_SOURCE" |
        rsvg-convert --width 256 --height 256 --output "$GODOT_ICON_PATH"
    GODOT_ICON_NAME="$GODOT_ICON_PATH"
fi

VSCODE_ICON=vscode
if [ -f /usr/share/code/resources/app/resources/linux/code.png ]; then
    VSCODE_ICON=/usr/share/code/resources/app/resources/linux/code.png
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ANTIGRAVITY_ICON=applications-development
ANTIGRAVITY_ASAR="${HOME}/Downloads/Antigravity-x64/resources/app.asar"
ANTIGRAVITY_ICON_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/512x512/apps"
ANTIGRAVITY_ICON_PATH="${ANTIGRAVITY_ICON_DIR}/cloudix-antigravity.png"
if [ -f "$ANTIGRAVITY_ASAR" ]; then
    mkdir -p "$ANTIGRAVITY_ICON_DIR"
    if python3 - "$ANTIGRAVITY_ASAR" "$ANTIGRAVITY_ICON_PATH" <<'PY'
import json
import struct
import sys
from pathlib import Path

archive_path = Path(sys.argv[1])
icon_path = Path(sys.argv[2])
with archive_path.open("rb") as archive:
    _, header_size, _, json_size = struct.unpack("<4I", archive.read(16))
    header = json.loads(archive.read(json_size))
    icon = header["files"]["icon.png"]
    archive.seek(16 + header_size + int(icon["offset"]) - 8)
    contents = archive.read(int(icon["size"]))

if not contents.startswith(b"\x89PNG\r\n\x1a\n"):
    raise SystemExit("Antigravity's packaged icon is not a PNG image.")
icon_path.write_bytes(contents)
PY
    then
        ANTIGRAVITY_ICON="$ANTIGRAVITY_ICON_PATH"
    else
        echo "WARNING: Could not extract the Antigravity app icon."
    fi
fi

if [ "$ANTIGRAVITY_ICON" = "applications-development" ] && [ -f "${SCRIPT_DIR}/icons/antigravity.png" ]; then
    mkdir -p "$ANTIGRAVITY_ICON_DIR"
    cp -f "${SCRIPT_DIR}/icons/antigravity.png" "$ANTIGRAVITY_ICON_PATH"
    sudo cp -f "${SCRIPT_DIR}/icons/antigravity.png" /usr/share/pixmaps/cloudix-antigravity.png 2>/dev/null || true
    ANTIGRAVITY_ICON="$ANTIGRAVITY_ICON_PATH"
fi

# Target desktop folder (both ~/Desktop and /home/codespace/Desktop)
TARGET_DIRS=()
if [ -d "${HOME}/Desktop" ] || [ -d "${HOME}" ]; then
    mkdir -p "${HOME}/Desktop"
    TARGET_DIRS+=("${HOME}/Desktop")
fi
if [ -d "/home/codespace/Desktop" ] || [ -d "/home/codespace" ]; then
    mkdir -p "/home/codespace/Desktop"
    TARGET_DIRS+=("/home/codespace/Desktop")
fi

for DESK in "${TARGET_DIRS[@]}"; do
    echo "Configuring icons in: $DESK"

    # 1. Google Chrome
    cat << 'EOF' > "$DESK/google-chrome.desktop"
[Desktop Entry]
Version=1.0
Type=Application
Name=Google Chrome
Comment=Access the Internet
Exec=/usr/bin/google-chrome-stable --no-sandbox --enable-webgl --enable-unsafe-swiftshader --disable-background-networking --disable-component-update --disable-sync --no-first-run %U
Icon=google-chrome
Terminal=false
StartupNotify=false
Categories=Network;WebBrowser;
EOF

    # 2. Google Antigravity
    cat << EOF > "$DESK/Google_Antigravity.desktop"
[Desktop Entry]
Version=1.0
Type=Application
Name=Google Antigravity
Comment=Google Antigravity AI Studio
Exec=/usr/local/bin/anti
Icon=${ANTIGRAVITY_ICON}
Terminal=false
StartupNotify=false
Categories=Development;
EOF

    # 3. VS Code
    cat << EOF > "$DESK/code.desktop"
[Desktop Entry]
Version=1.0
Type=Application
Name=Visual Studio Code
Comment=Code Editing. Redefined.
Exec=/usr/share/code/code --no-sandbox --unity-launch --reuse-window %F
Icon=${VSCODE_ICON}
Terminal=false
StartupNotify=false
Categories=Development;IDE;
EOF

    # 4. Terminal (Fixed with --disable-server)
    cat << 'EOF' > "$DESK/xfce4-terminal.desktop"
[Desktop Entry]
Version=1.0
Type=Application
Name=Terminal Emulator
Comment=Use the command line
Exec=/usr/bin/xfce4-terminal --disable-server
Icon=org.xfce.terminal
Terminal=false
StartupNotify=false
Categories=System;TerminalEmulator;
EOF

    # 4.5 Fallback Direct XTerm
    cat << 'EOF' > "$DESK/xterm.desktop"
[Desktop Entry]
Version=1.0
Type=Application
Name=Terminal (Direct)
Comment=Standalone XTerm
Exec=xterm -fa 'Monospace' -fs 12 -bg black -fg white
Icon=terminal
Terminal=false
StartupNotify=false
Categories=System;TerminalEmulator;
EOF

    # 5. File Manager (Thunar)
    cat << 'EOF' > "$DESK/thunar.desktop"
[Desktop Entry]
Version=1.0
Type=Application
Name=File Manager
Comment=Browse the file system
Exec=thunar %F
Icon=system-file-manager
Terminal=false
StartupNotify=false
Categories=System;FileTools;
EOF

    # 6. Task Manager (RAM & CPU Monitor)
    cat << 'EOF' > "$DESK/xfce4-taskmanager.desktop"
[Desktop Entry]
Version=1.0
Type=Application
Name=Task Manager
Comment=Easy to use task manager
Exec=xfce4-taskmanager
Icon=org.xfce.taskmanager
Terminal=false
StartupNotify=false
Categories=System;
EOF

    # Remove Web Games shortcut
    rm -f "$DESK/web_games.desktop"

    # 7. Godot Engine (2D & 3D Game Maker)
    cat << EOF > "$DESK/godot.desktop"
[Desktop Entry]
Version=1.0
Type=Application
Name=Godot Engine
Comment=Free and open source 2D and 3D game engine
Exec=/usr/local/bin/godot
Icon=${GODOT_ICON_NAME}
Terminal=false
StartupNotify=false
Categories=Development;IDE;
EOF

    # 8. Remove obsolete shortcuts that do not belong in the Ubuntu-style desktop
    rm -f "$DESK/backup.desktop" "$DESK/xterm.desktop"

    # 9. Register custom apps in the XFCE Applications menu
    APP_DIR="${HOME}/.local/share/applications"
    mkdir -p "$APP_DIR"
    cat << 'EOF' > "$APP_DIR/google-chrome.desktop"
[Desktop Entry]
Version=1.0
Type=Application
Name=Google Chrome
Comment=Browse the web
Exec=/usr/bin/google-chrome-stable --no-sandbox --enable-webgl --enable-unsafe-swiftshader --disable-background-networking --disable-component-update --disable-sync --no-first-run %U
Icon=google-chrome
Terminal=false
StartupNotify=true
Categories=Network;WebBrowser;
EOF
    cat << 'EOF' > "$APP_DIR/com.microsoft.VSCode.desktop"
[Desktop Entry]
Version=1.0
Type=Application
Name=Visual Studio Code
Comment=Code Editing. Redefined.
Exec=/usr/share/code/code --no-sandbox --unity-launch --reuse-window %F
Icon=/usr/share/code/resources/app/resources/linux/code.png
Terminal=false
StartupNotify=true
Categories=Development;IDE;
EOF
    rm -f "$APP_DIR/code.desktop"
    cat << EOF > "$APP_DIR/cloudix-godot.desktop"
[Desktop Entry]
Version=1.0
Type=Application
Name=Godot Engine
Comment=Create 2D and 3D games
Exec=/usr/local/bin/godot
Icon=${GODOT_ICON_NAME}
Terminal=false
StartupNotify=false
Categories=Development;IDE;
EOF
    cat << EOF > "$APP_DIR/cloudix-antigravity.desktop"
[Desktop Entry]
Version=1.0
Type=Application
Name=Google Antigravity
Comment=Open Google Antigravity
Exec=/usr/local/bin/anti
Icon=${ANTIGRAVITY_ICON}
Terminal=false
StartupNotify=false
Categories=Development;IDE;
EOF

    chmod +x "$DESK"/*.desktop
done

# Desktop launchers need to be trusted before XFCE will run them with one click.
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    XFCE_DESKTOP_PID="$(pgrep -n -x xfdesktop || true)"
    if [ -n "$XFCE_DESKTOP_PID" ] && [ -r "/proc/${XFCE_DESKTOP_PID}/environ" ]; then
        DBUS_SESSION_BUS_ADDRESS="$(
            tr '\0' '\n' < "/proc/${XFCE_DESKTOP_PID}/environ" |
                sed -n 's/^DBUS_SESSION_BUS_ADDRESS=//p'
        )"
        export DBUS_SESSION_BUS_ADDRESS
    fi
fi
if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    for DESK in "${TARGET_DIRS[@]}"; do
        for launcher in "$DESK"/*.desktop; do
            gio set "$launcher" metadata::trusted true ||
                echo "WARNING: Could not mark $launcher as a trusted launcher."
        done
    done
fi

# Replace XFCE's generic dock placeholders with launchers for installed apps.
PANEL_DIR="${HOME}/.config/xfce4/panel"
write_launcher() {
    local plugin_id="$1" launcher_file="$2" name="$3" command="$4" icon="$5"
    local launcher_dir="${PANEL_DIR}/launcher-${plugin_id}"
    mkdir -p "$launcher_dir"
    cat > "${launcher_dir}/${launcher_file}" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=${name}
Exec=${command}
Icon=${icon}
Terminal=false
StartupNotify=true
Categories=Utility;
EOF
}

write_launcher 17 17940020141.desktop "Google Chrome" \
    "/usr/bin/google-chrome-stable --no-sandbox --enable-webgl --enable-unsafe-swiftshader --disable-background-networking --disable-component-update --disable-sync --no-first-run %U" google-chrome
write_launcher 18 17940020142.desktop "Visual Studio Code" \
    "/usr/share/code/code --no-sandbox --unity-launch %F" \
    "/usr/share/code/resources/app/resources/linux/code.png"
write_launcher 19 17940020143.desktop "File Manager" "thunar" system-file-manager
write_launcher 20 17940020144.desktop "Terminal" \
    "/usr/bin/xfce4-terminal --disable-server" org.xfce.terminal
chmod +x "$PANEL_DIR"/launcher-{17,18,19,20}/*.desktop
if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    for launcher in "$PANEL_DIR"/launcher-{17,18,19,20}/*.desktop; do
        gio set "$launcher" metadata::trusted true ||
            echo "WARNING: Could not trust dock launcher $launcher."
    done
fi

# Refresh icon theme cache and reload XFCE Desktop when an X display is active
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor" >/dev/null 2>&1 || true
fi
export DISPLAY="${DISPLAY:-:1}"
if [ -S "/tmp/.X11-unix/X${DISPLAY#:}" ] || xset q >/dev/null 2>&1; then
    if pgrep -x xfdesktop >/dev/null; then
        xfdesktop --reload 2>/dev/null || true
    else
        setsid nohup xfdesktop </dev/null >/dev/null 2>&1 &
        sleep 1
    fi
fi

echo "=========================================================="
echo "🎉 ALL DESKTOP SHORTCUTS SUCCESSFULLY CREATED & RELOADED!"
echo "=========================================================="
