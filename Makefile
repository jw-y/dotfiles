.PHONY: install update upgrade-nvim gitconfig dry-run help

help:
	@echo "Targets:"
	@echo "  make install        Full setup (brew bundle on Mac, apt + nvim download on Linux)"
	@echo "  make update         Sync configs to \$$HOME"
	@echo "  make upgrade-nvim   Force re-download latest nvim (Linux only)"
	@echo "  make gitconfig      Add include.path to ~/.gitconfig (opt-in)"
	@echo "  make dry-run        Preview install + update without changing anything"
	@echo ""
	@echo "Env vars:"
	@echo "  DRY_RUN=true        Preview mode for any target"
	@echo "  WITH_GITCONFIG=true Also wire up gitconfig during install"
	@echo "  UPGRADE_NVIM=true   Force nvim re-download during install"

install:
	@./install.sh

update:
	@./update.sh

upgrade-nvim:
	@UPGRADE_NVIM=true ./install.sh

gitconfig:
	@WITH_GITCONFIG=true ./install.sh

dry-run:
	@echo "=== DRY RUN ==="
	@echo "--- install.sh ---"
	@DRY_RUN=true ./install.sh || true
	@echo ""
	@echo "--- update.sh ---"
	@DRY_RUN=true ./update.sh || true
