# Fresh Pi Setup (Kiosk Baseline)

This is the active setup guide for bringing up a fresh Raspberry Pi as a web kiosk baseline.

The previous version has been preserved as archive notes:

- [Archived Setup Notes](/guide/setup.old)

## 0) Flash the SD card

1. Use Raspberry Pi Imager: <https://www.raspberrypi.com/software/>
2. Select Raspberry Pi OS Lite.
3. In the imager advanced/customize settings, set hostname, user, password, locale, and network.
4. Flash and eject.

## 1) Pre-boot SD card edits (on your computer)

With the flashed SD card still mounted, edit:

1. `config.txt`
2. `cmdline.txt`

For SPI display support, ensure these are present:

```text
dtparam=spi=on
dtoverlay=piscreen,speed=16000000
```

For console output on the small display during boot (optional), append this token to the existing single line in `cmdline.txt`:

```text
fbcon=map:10
```

## 2) First boot and prepare remote control

1. Boot the Pi.
2. Ensure SSH is enabled and reachable from your workstation.
3. Clone this repo on your workstation (not on the Pi) if you have not already.

```bash
git clone https://github.com/parsehex/ParseBox.rPi.git
cd ParseBox.rPi
```

## 3) Run remote system setup script

The script handles:

- system update + full upgrade
- base package install
- Node.js install (NodeSource LTS)
- ParseBox power-control sudoers setup for kiosk user (`systemctl reboot/poweroff`)
- Xorg framebuffer config for SPI display
- touch calibration config
- boot config updates (SPI + overlay)
- optional tty1 autologin via raspi-config

Run from your workstation:

```bash
PI_HOST=parsebox.local PI_USER=pi bash scripts/pi/setup-system.sh
```

Optional behavior flags:

```bash
PI_HOST=parsebox.local PI_USER=pi ENABLE_FBCON_MAP=1 bash scripts/pi/setup-system.sh
PI_HOST=parsebox.local PI_USER=pi INSTALL_NODE=0 bash scripts/pi/setup-system.sh
PI_HOST=parsebox.local PI_USER=pi ENABLE_TTY_AUTOLOGIN=0 bash scripts/pi/setup-system.sh
PI_HOST=parsebox.local PI_USER=pi ENABLE_PARSEBOX_POWER_CONTROLS=0 bash scripts/pi/setup-system.sh
```

Optional remote options:

```bash
PI_HOST=parsebox.local PI_PORT=22 SSH_OPTS='-o ConnectTimeout=5' bash scripts/pi/setup-system.sh
```

## 4) Run remote kiosk-user setup script

This script creates/updates:

- `~/.profile` login hook for tty1 kiosk start
- `~/.xinitrc` with Chromium kiosk launch
- `~/.parsebox/config.json` runtime config consumed by ParseBox Node server

Run from your workstation:

```bash
PI_HOST=parsebox.local PI_USER=pi bash scripts/pi/setup-kiosk-user.sh
```

Set a custom app URL:

```bash
PI_HOST=parsebox.local PI_USER=pi APP_URL=http://127.0.0.1:5000/ bash scripts/pi/setup-kiosk-user.sh
```

Set a custom ParseBox runtime config file path:

```bash
PI_HOST=parsebox.local PI_USER=pi PARSEBOX_CONFIG_FILE=/home/pi/.parsebox/config.json bash scripts/pi/setup-kiosk-user.sh
```

## 4b) Install a target app repo (generic orchestration)

Use this when you want ParseBox to install and wire a specific app repo, instead of manually setting `APP_URL`.

```bash
PI_HOST=parsebox.local PI_USER=pi bash scripts/pi/install-app.sh
```

Behavior:

- prompts you to pick an app or repo URL
- clones/pulls that repo on the Pi
- if `.env.example` exists and `.env` is missing, creates `.env` automatically
- prompts for missing `.env` values (empty entries) during install
- runs repo-defined installer hooks when present, otherwise falls back to npm/static build heuristics
- if splash is enabled on ParseBox, installs app splash from repo assets when present
- auto-detects static output directory and configures kiosk HTTP service + Chromium URL

Repo installer hook lookup order:

- `parsebox/install.sh`
- `scripts/parsebox-install.sh`
- `scripts/pi/install.sh`

Repo splash asset lookup order (only when ParseBox splash is enabled):

- `parsebox/splash.svg`
- `parsebox/splash.png`
- `parsebox/splash.webp`
- `parsebox/splash.jpg`
- `parsebox/splash.jpeg`

## 4c) Enable ParseBox boot splash (optional but recommended)

This installs and configures Plymouth on the Pi, sets a default ParseBox splash theme for fb1, and writes an enable marker used by `install-app.sh` to decide whether app splash hooks should run.

Run from your workstation:

```bash
PI_HOST=parsebox.local PI_USER=pi bash scripts/pi/setup-splash.sh
```

Optional values:

```bash
PI_HOST=parsebox.local PI_USER=pi THEME_ID=parsebox FRAMEBUFFER=/dev/fb1 bash scripts/pi/setup-splash.sh
```

Enable marker written on the Pi:

```text
/etc/parsebox/splash-enabled
```

If this marker exists, app installs can apply repo-provided splash hooks automatically.

## 5) Reboot and validate

```bash
sudo reboot
```

Confirm:

- tty1 autologin works (if enabled)
- X starts from tty1
- Chromium launches in kiosk mode
- display output is correct
- touch direction is correct

## 6) Temporary kiosk disable switch

Disable kiosk launch:

```bash
touch ~/.no-kiosk
```

Re-enable kiosk launch:

```bash
rm ~/.no-kiosk
```

## Troubleshooting

### No display output in X/Chromium

1. Verify SPI lines in boot config.
2. Verify `/etc/X11/xorg.conf.d/99-fbdev.conf` points to `/dev/fb1`.
3. Reboot and re-test.

### Touch is inverted/flipped

1. Check `/etc/X11/xorg.conf.d/98-touch-calibration.conf` exists.
2. Tune the `CalibrationMatrix` values for your panel if needed.

### Kiosk does not auto-start

1. Confirm `~/.profile` kiosk block exists.
2. Confirm `~/.xinitrc` is executable.
3. Confirm `~/.no-kiosk` does not exist.
