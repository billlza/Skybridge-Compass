# Cloud Terminal Bootstrap

This workspace now includes a hardened cloud-terminal deployment profile for
Wayland/portal-based Ubuntu terminals.

## Key runtime pieces

- User service: `packaging/linux/systemd/user/skybridge-compass.service`
- Example config: `packaging/linux/production.toml.example`
- Portal bootstrap command: `skybridge-compass --portal-bootstrap`
- Portal runtime validation: `skybridge-compass --portal-validate-runtime`
- Golden manifest: `packaging/linux/cloud-terminal-golden-manifest.toml`
- GNOME session hardening: `packaging/linux/dconf/skybridge-cloud-terminal.ini`
- Unattended-upgrades blacklist:
  `packaging/linux/apt/51-skybridge-cloud-terminal-unattended-upgrades`

## What changed

- `SKYBRIDGE_SETTINGS_PATH` can point the app at a dedicated JSON or TOML
  settings file. This is intended for user-service deployment where the cloud
  terminal should not reuse local/lab defaults.
- Portal restore state is encrypted on disk at
  `~/.local/state/compass/portal_state.json.enc`.
- The encryption key is expected via systemd credentials as
  `portal_state_key`.
- Wayland capture now consumes a real PipeWire stream from the shared portal
  session and fails closed if the first frame never arrives or if the stream
  stalls.
- Wayland clipboard is fail-closed until a portal-native clipboard path lands.
- HEVC send capability is no longer inferred from decode support; the encoder
  path resolves to a production-safe codec before advertising or initializing a
  session.

## Bootstrap flow

1. Install the example unit and production config for the target user.
2. Provision `/etc/skybridge/credentials/portal_state_key` with a 32-byte key
   (raw bytes, 64-char hex, or base64-encoded 32 bytes).
3. In a real Wayland session, run:

   ```bash
   SKYBRIDGE_SETTINGS_PATH="$HOME/.config/compass/production.toml" \
   systemd-run --user --collect --wait /usr/bin/skybridge-compass --portal-bootstrap
   ```

4. Confirm the bootstrap summary prints a valid session, node id, and
   `restore_token_present=true`.
5. Disconnect the temporary bootstrap GUI channel, then validate persistent
   output from the same `skybridge` user session:

   ```bash
   SKYBRIDGE_SETTINGS_PATH="$HOME/.config/compass/production.toml" \
   systemd-run --user --collect --wait /usr/bin/skybridge-compass \
     --portal-validate-runtime --portal-validate-secs 300 --portal-validate-input
   ```

6. Confirm the runtime validation summary reports:
   - `frames > 0`
   - `non_black_frames > 0`
   - `max_gap_ms <= 500`
   - `input_smoke_ran=true`

7. Validate the host against the golden AMI manifest:

   ```bash
   python3 /usr/share/skybridge/scripts/validate_cloud_terminal_manifest.py \
     --manifest /usr/share/skybridge/packaging/linux/cloud-terminal-golden-manifest.toml
   ```

8. Apply the dedicated GNOME session hardening profile once for the
   `skybridge` graphical user:

   ```bash
   dconf load / < /usr/share/skybridge/packaging/linux/dconf/skybridge-cloud-terminal.ini
   ```

9. Install the unattended-upgrades blacklist on production images:

   ```bash
   sudo install -m 0644 \
     /usr/share/skybridge/packaging/linux/apt/51-skybridge-cloud-terminal-unattended-upgrades \
     /etc/apt/apt.conf.d/51-skybridge-cloud-terminal-unattended-upgrades
   ```

10. Enable the user unit:

   ```bash
   systemctl --user daemon-reload
   systemctl --user enable --now skybridge-compass.service
   ```

## Current guardrails

- Wayland capture no longer reports success without a real portal session,
  PipeWire FD, and first frame.
- Runtime validation is designed for the post-bootstrap phase where the GUI
  bootstrap channel has already been disconnected.
- Production cloud terminals should keep `clipboard_policy = "disabled"` until
  the clipboard implementation is upgraded from shell-command helpers to a
  portal-native path.
- Cloud terminal networking is expected to stay relay-only against the existing
  `api.nebula-technologies.net` signaling/TURN deployment; media should not open
  direct inbound ports on the Ubuntu terminal host.
