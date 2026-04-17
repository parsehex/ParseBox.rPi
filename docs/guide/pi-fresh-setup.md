# Fresh Pi Setup (Kiosk Baseline)

This guide captures a proven path from a brand-new SD card to a booting browser kiosk on Raspberry Pi OS Lite.

It is intentionally app-agnostic: use it as the baseline, then point kiosk mode at your own local service.

## Goal State

- Raspberry Pi boots to local tty1 autologin
- Xorg runs on the SPI framebuffer (`/dev/fb1`)
- Chromium launches in kiosk mode on boot
- Kiosk points to a local URL you control

## 0) Flash And First Boot

1. Use Raspberry Pi Imager: <https://www.raspberrypi.com/software/>
2. Select Raspberry Pi OS Lite
3. In advanced settings, configure hostname, user/password, locale/timezone, and optional Wi-Fi
4. Before first boot, add your SPI display overlay in `config.txt` if your hardware requires it
5. Boot the Pi and run:

```bash
sudo apt update && sudo apt full-upgrade -y
```

## 1) Install Base Packages

```bash
sudo apt install -y \
  git curl \
  xauth xinit xserver-xorg openbox unclutter x11-xserver-utils \
  chromium
```

## 2) Optional: Install Node.js For App Runtime

If your target app needs Node:

```bash
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
sudo apt-get install -y nodejs
node -v
npm -v
```

## 3) Force Xorg To SPI Framebuffer

Create Xorg config:

```bash
sudo mkdir -p /etc/X11/xorg.conf.d
sudo tee /etc/X11/xorg.conf.d/99-fbdev.conf >/dev/null <<'EOF'
Section "Device"
  Identifier  "SPI Display"
  Driver      "fbdev"
  Option      "fbdev" "/dev/fb1"
EndSection

Section "Screen"
  Identifier "Screen0"
  Device     "SPI Display"
EndSection
EOF
```

If your LCD uses a different framebuffer, replace `/dev/fb1` accordingly.

## 4) Optional: Touch Calibration Example

If touch is inverted or mirrored, add a calibration matrix:

```bash
sudo tee /etc/X11/xorg.conf.d/98-touch-calibration.conf >/dev/null <<'EOF'
Section "InputClass"
  Identifier "Touchscreen calibration"
  MatchIsTouchscreen "on"
  Driver "libinput"
  Option "CalibrationMatrix" "1 0 0 0 -1 1 0 0 1"
EndSection
EOF
```

## 5) Verify Browser Launch Manually

Use your app URL if available. Otherwise, use a temporary test URL.

```bash
xinit /usr/bin/chromium --app=http://127.0.0.1:4174/ --disable-gpu --use-gl=swiftshader -- :0 vt1
```

If this works on the target display, continue with autostart setup.

## 6) Enable tty1 Autologin

```bash
sudo raspi-config nonint do_boot_behaviour B2
sudo reboot
```

After reboot, confirm your user autologs in on local tty1.

## 7) Configure Kiosk Autostart

### 7.1 Add tty1 login hook

Append to `~/.profile`:

```sh
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ] && [ ! -f "$HOME/.no-kiosk" ]; then
  exec startx "$HOME/.xinitrc" -- :0 vt1 -keeptty
fi
```

### 7.2 Create `~/.xinitrc`

```bash
cat > ~/.xinitrc <<'EOF'
#!/usr/bin/env sh
xset -dpms
xset s off
xset s noblank
unclutter -idle 0.5 -root &

until curl -fsS http://127.0.0.1:4174/ >/dev/null; do
  sleep 1
done

sed -i 's/"exited_cleanly":false/"exited_cleanly":true/' ~/.config/chromium/'Local State' 2>/dev/null || true
sed -i 's/"exited_cleanly":false/"exited_cleanly":true/; s/"exit_type":"[^"]\+"/"exit_type":"Normal"/' ~/.config/chromium/Default/Preferences 2>/dev/null || true

exec chromium \
  --kiosk \
  --app=http://127.0.0.1:4174/ \
  --force-device-scale-factor=1 \
  --disable-infobars \
  --disable-gpu \
  --use-gl=swiftshader \
  --no-first-run \
  --disable-pinch \
  --overscroll-history-navigation=0 \
  --start-maximized
EOF

chmod +x ~/.xinitrc
```

Update `http://127.0.0.1:4174/` to your app URL when ready.

### 7.3 Safety switch

Disable kiosk startup:

```bash
touch ~/.no-kiosk
```

Re-enable kiosk startup:

```bash
rm ~/.no-kiosk
```

## 8) Reboot And Confirm

```bash
sudo reboot
```

After reboot, verify:

- display comes up consistently
- Chromium launches in kiosk mode
- kiosk URL is reachable and interactive

## 9) Troubleshooting

### Console appears, but Xorg/Chromium does not

- Verify SPI overlay and reboot
- Check framebuffer mapping (`/dev/fb1` vs another framebuffer)
- Review Xorg logs: `/var/log/Xorg.0.log`

### Kiosk does not auto-launch

- Confirm tty1 autologin is active
- Confirm `~/.profile` hook is present
- Confirm `~/.xinitrc` is executable
- Confirm `~/.no-kiosk` does not exist

### Chromium launches before app is ready

Increase startup wait robustness in `~/.xinitrc` and confirm your service starts before browser launch.
