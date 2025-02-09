install:
	@echo "Installing pass-cli plugin (sshkeys.bash)..."
	@mkdir -p ~/.password-store/.extensions/
	@cp sshkeys.bash ~/.password-store/.extensions/
	@chmod +x ~/.password-store/.extensions/sshkeys.bash
	@echo "Installation complete. You can now use 'pass-sshkeys'."