# PARSEBOX_KIOSK_START
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ] && [ ! -f "$HOME/.no-kiosk" ]; then
  exec startx "$HOME/.xinitrc" -- :0 vt1 -keeptty
fi
# PARSEBOX_KIOSK_END
