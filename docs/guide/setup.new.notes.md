# <!-- The old setup doc sucks pretty bad at this point but still contains the steps that have been working so I'm going to provide notes as I go through this. -->

Lose Goal State and Hardware Reference sections

`0)` needs split. First there's imaging the card.
Then, I've been doing a step that I want to replace:
	With the SD Card still plugged in, edit 2 files
		`/boot/config.txt`
			Uncomment the line: `dtparam=spi=on`
			Add at the end: `dtoverlay=piscreen,speed=16000000`
		`/boot/cmdline.txt`
			Add at the end of the line: ` fbcon=map:10`
That got me in with console output on the display.

Next is SSHing in for initial setup. Think this part could be lumped into a command that covers the above note too.
- system update
- enable auto-login
- base packages
- node
- spi xorg bit (both parts)
  - not specifying the `rotate` option leaves the display good for me, but that rotation flips touch input so the other step is needed
- this is where this project diverges, because we don't need a python app (installing it was fine)
  - we just need an http server to serve the kiosk folder
- setup .xinitrc
