# Getting Started

ParseBox.rPi is designed to get you to a visible, touchable result quickly on real Pi hardware.

This repository gives you:

1. A VitePress docs site
2. A separate kiosk-facing page (`kiosk/index.html`)

## 1) Run docs locally

```bash
npm install
npm run docs:dev
```

## 2) Build your first Pi baseline

Use the full guide:

- [Fresh Pi Setup (Kiosk Baseline)](/guide/pi-fresh-setup)

That guide walks through:

- fresh OS prep
- minimal package install
- Xorg to SPI framebuffer
- kiosk browser autostart on boot
- troubleshooting checks

## 3) Validate kiosk output with this repo

On the Pi, you can serve the local kiosk test page:

```bash
cd /path/to/ParseBox.rPi
python3 -m http.server 4174 --directory kiosk
```

Then point Chromium kiosk mode to:

```text
http://127.0.0.1:4174/
```

Once this is stable, replace the target URL with your app service URL.

## Commands

- `npm run docs:dev` - run docs locally
- `npm run docs:build` - build static docs output
- `npm run docs:preview` - preview built docs output
