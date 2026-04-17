# Fresh Pi Setup (Minimal OS)

This guide recreates a working ParsePlayer Pi from a brand-new SD card.

It is written for a minimal Raspberry Pi OS style install where you add only the GUI pieces needed for local kiosk display.

## Goal state

- ParsePlayer runs as a systemd service on port 5000
- SPI LCD works with Xorg on fb1
- Chromium launches in kiosk mode on boot
- USB import/sync workflow is available in the app UI

## Hardware reference material

Repo-side build reference assets live under `resources/ParsePlayer/`:

- `assembled-case.jpg` shows the assembled Pi case/display enclosure.
- `case-top-off.jpg` shows the display stack with the top removed.
- `rca-pearl.jpg` is the current clean reference shot of the motivating MP3 player.
- `Display booklet/` contains product-booklet photos for the third-party case/display hardware.

Those booklet images are assembly context for the off-the-shelf hardware, not ParsePlayer project documentation.

## 0) Flash and first boot

1. Use the official Raspberry Pi Imager: <https://www.raspberrypi.com/software/>
   - Select "OS → Raspberry Pi OS (other) → Raspberry Pi OS Lite"
   - Click "Customize" and set:
     - Hostname
     - Locale/timezone
     - Username and password
     - WiFi (if needed)
   - Before writing, open `/boot/config.txt` on your computer and add the following line to the bottom:

     ```text
     dtoverlay=piscreen,speed=16000000
     ```

   - Also, un-comment the
   - (TODO Convert SD card updates to a section, add Tip for displaying console output to screen with `fbcon=map:10)

   - Write to SD card
2. Boot the Pi and wait for yellow/green LED to settle before attempting SSH.
3. Update packages:

```bash
sudo apt update && sudo apt full-upgrade -y
```

## 1) Install base packages

After reboot (if needed):

```bash
sudo apt install -y \
  git curl \
  python3-venv python3-pip \
  xauth xinit xserver-xorg openbox unclutter x11-xserver-utils \
  chromium
```

## 2) Install Node.js v24+

ParsePlayer requires Node v24 or higher. The following command should work but is provided for convenience.

[See here for full instructions](https://gist.github.com/stonehippo/f4ef8446226101e8bed3e07a58ea512a#install-with-apt-using-nodesource-binary-distribution)

```bash
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash - &&\
sudo apt-get install -y nodejs
```

## 3) Force Xorg to the SPI framebuffer

Create Xorg config directory and file:

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

If your framebuffer mapping differs, replace `/dev/fb1` with the active LCD framebuffer.

Add touch calibration (confirmed working for inverted vertical touch):

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

## 4) Get ParsePlayer onto the Pi

Clone directly on Pi:

```bash
git clone https://github.com/parsehex/ParsePlayer
cd ~/ParsePlayer
```

## 5) Install ParsePlayer service

Run the installer script:

```bash
./scripts/install_pi_service.sh
./scripts/setup_safe_usb.sh
```

This script:

- installs frontend dependencies
- builds frontend assets
- installs Python dependencies
- installs and enables parseplayer.service
- starts the service

## 8) Enable tty1 autologin (raspi-config)

Run:

```bash
sudo raspi-config nonint do_boot_behaviour B2
```

Reboot after saving raspi-config changes:

```bash
sudo reboot
```

After reboot, verify autologin is active on local tty1.

## 9) Configure kiosk autostart

### 9.1 Login shell hook for tty1

Append to ~/.profile (or equivalent login shell startup file):

```sh
# ParsePlayer
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ] && [ ! -f "$HOME/.no-kiosk" ]; then
  exec startx "$HOME/.xinitrc" -- :0 vt1 -keeptty
fi
```

### 9.2 Create ~/.xinitrc

```bash
cat > ~/.xinitrc <<'EOF'
#!/usr/bin/env sh
xset -dpms
xset s off
xset s noblank
unclutter -idle 0.5 -root &

until curl -fsS http://127.0.0.1:5000/ >/dev/null; do
  sleep 1
done

sed -i 's/"exited_cleanly":false/"exited_cleanly":true/' ~/.config/chromium/'Local State'
sed -i 's/"exited_cleanly":false/"exited_cleanly":true/; s/"exit_type":"[^"]\+"/"exit_type":"Normal"/' ~/.config/chromium/Default/Preferences

exec chromium \
  --kiosk \
  --app=http://127.0.0.1:5000/ \
  --force-device-scale-factor=1 \
  --disable-infobars \
  --disable-gpu \
  --use-gl=swiftshader \
  --no-first-run \
  --disable-pinch \
  --overscroll-history-navigation=0 \
  --bgcolor='#9edd00' \
  --enable-features=OverlayScrollbar \
  --start-maximized
EOF
chmod +x ~/.xinitrc
```

### 9.3 Optional safety switch

Disable kiosk autostart temporarily:

```bash
touch ~/.no-kiosk
```

Re-enable kiosk autostart:

```bash
rm ~/.no-kiosk
```

## 10) Reboot and confirm end-to-end

```bash
sudo reboot
```

After reboot, confirm:

- ParsePlayer service is active
- Chromium kiosk opens on the LCD
- UI is reachable and usable

## 11) Boot splash (Plymouth)

This setup renders the ParsePlayer splash at boot on the SPI LCD framebuffer (fb1, 480x320).

### Install dependencies

```bash
sudo apt update
sudo apt install -y plymouth plymouth-themes imagemagick librsvg2-bin initramfs-tools
```

### Create theme directory

```bash
sudo rm -rf /usr/share/plymouth/themes/parseplayer
sudo mkdir -p /usr/share/plymouth/themes/parseplayer
```

### Build splash image

Copy the pre-rendered splash PNG to the theme directory:

```bash
cd ~/ParsePlayer

sudo mkdir -p /usr/share/plymouth/themes/parseplayer
sudo cp resources/parseplayer-splash.png /usr/share/plymouth/themes/parseplayer/splash.png
```

### Create theme definition file

```bash
sudo tee /usr/share/plymouth/themes/parseplayer/parseplayer.plymouth >/dev/null <<'EOF'
[Plymouth Theme]
Name=ParsePlayer
Description=ParsePlayer boot splash
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/parseplayer
ScriptFile=/usr/share/plymouth/themes/parseplayer/parseplayer.script
EOF
```

### Create theme script (centered placement)

```bash
sudo tee /usr/share/plymouth/themes/parseplayer/parseplayer.script >/dev/null <<'EOF'
screen_w = Window.GetWidth();
screen_h = Window.GetHeight();
img = Image("splash.png");
sprite = Sprite(img);
sprite.SetX((screen_w - img.GetWidth()) / 2);
sprite.SetY((screen_h - img.GetHeight()) / 2);
EOF
```

### Set theme as default

```bash
sudo update-alternatives --install /usr/share/plymouth/themes/default.plymouth default.plymouth /usr/share/plymouth/themes/parseplayer/parseplayer.plymouth 100
sudo update-alternatives --set default.plymouth /usr/share/plymouth/themes/parseplayer/parseplayer.plymouth
```

Verify selection:

```bash
sudo update-alternatives --display default.plymouth
```

### Configure Plymouth daemon for fb1

```bash
sudo tee /etc/plymouth/plymouthd.conf >/dev/null <<'EOF'
[Daemon]
Theme=parseplayer
DeviceTimeout=8
ShowDelay=0
Framebuffer=/dev/fb1
EOF
```

### Update boot command line

Edit `/boot/firmware/cmdline.txt` (keep on a single line):

```bash
sudo nano /boot/firmware/cmdline.txt
```

Ensure it includes:

```text
splash plymouth.ignore-serial-consoles
```

### Rebuild and reboot

```bash
sudo update-initramfs -u
sudo reboot
```

Plymouth should now display the ParsePlayer splash on the SPI LCD at boot.

### 12) Optional: clear LCD on shutdown/reboot

On this SPI setup, reboot/shutdown can leave the previous frame visible on the panel.

This service clears `/dev/fb1` during shutdown/reboot so the screen goes black cleanly.

Create clear script:

```bash
sudo tee /usr/local/bin/clear-fb1.sh >/dev/null <<'EOF'
#!/usr/bin/env sh
FB=/dev/fb1
SYS=/sys/class/graphics/fb1

if [ -e "$FB" ] && [ -r "$SYS/virtual_size" ] && [ -r "$SYS/bits_per_pixel" ]; then
  IFS=, read -r W H < "$SYS/virtual_size"
  BPP=$(cat "$SYS/bits_per_pixel")
  SIZE=$((W * H * BPP / 8))
  dd if=/dev/zero of="$FB" bs="$SIZE" count=1 status=none || true
fi
EOF

sudo chmod +x /usr/local/bin/clear-fb1.sh
```

Create shutdown service:

```bash
sudo tee /etc/systemd/system/clear-fb1-on-shutdown.service >/dev/null <<'EOF'
[Unit]
Description=Clear SPI framebuffer on shutdown/reboot
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/clear-fb1.sh

[Install]
WantedBy=shutdown.target reboot.target halt.target
EOF
```

Enable service:

```bash
sudo systemctl daemon-reload
sudo systemctl enable clear-fb1-on-shutdown.service
```

## Troubleshooting

### LCD shows console framebuffer but Xorg/Chromium does not display

- Confirm the dtoverlay line in /boot/firmware/config.txt is present and reboot.
- Try running `fbset -s` to query current framebuffer state.

### ParsePlayer service does not start

```bash
sudo journalctl -u parseplayer -n 200 --no-pager
```

Check that venv exists at ~/ParsePlayer/venv and dependencies installed.

### Kiosk does not launch at boot

- Confirm tty1 autologin is enabled for your user.
- Confirm ~/.profile hook exists and ~/.xinitrc is executable.
- Check if ~/.no-kiosk exists.
