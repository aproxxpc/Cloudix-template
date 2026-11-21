# Cloudix Linux Workstation Template

This public GitHub template contains only the Codespaces environment needed
for a Cloudix Linux desktop. It does not contain the Cloudix mobile app.

The Cloudix app creates a private repository from this template and starts a
GitHub Codespace. The Codespace installs the desktop, Chrome, VS Code, Godot,
audio streaming, and authenticated browser access.

## Important

- Codespaces availability, machine sizes, quotas, and billing are controlled by
  GitHub and depend on the account.
- The desktop is exposed through a temporary Cloudflare tunnel protected by
  HTTP Basic Authentication. Choose a unique password during first setup.
- `DESKTOP_LINK.txt` is generated per Codespace and is ignored by Git. Never
  commit or publish live links, setup codes, credentials, or tokens.
- The Codespace Stop action in the app stops the Codespace; closing the app
  alone does not stop it.

## Contents

- `.devcontainer/devcontainer.json`: Codespaces lifecycle and private port setup.
- `.devcontainer/setup.sh`: installs the desktop and applications.
- `.devcontainer/start.sh`: starts the desktop, audio, authentication, and tunnel.
- `.devcontainer/audio_streamer.py` and `browser_audio.js`: browser audio support.
- `.devcontainer/nginx.conf`: authenticated web desktop and local service proxy.
- `.devcontainer/update_desktop.sh`: desktop shortcuts and appearance.
