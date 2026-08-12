.PHONY: install minimal update upgrade-nvim gitconfig dry-run test help

help:
	@echo "Targets:"
	@echo "  make install        Full setup (shell + tools + nvm + uv + hf + Claude + Codex)"
	@echo "  make minimal        Shell config only (oh-my-zsh, plugins, tmux, dotfiles)"
	@echo "  make update         Sync configs to \$$HOME"
	@echo "  make upgrade-nvim   Force re-download latest nvim (Linux only)"
	@echo "  make gitconfig      Add include.path to ~/.gitconfig (opt-in)"
	@echo "  make dry-run        Preview install + update without changing anything"
	@echo "  make test           Run script tests (sandboxed, touches nothing real)"
	@echo ""
	@echo "Env vars:"
	@echo "  DRY_RUN=true        Preview mode for any target"
	@echo "  PROFILE=<name>      Which install profile to run: full (default) or minimal"
	@echo "  WITH_GITCONFIG=true Also wire up gitconfig during install"
	@echo "  UPGRADE_NVIM=true   Force nvim re-download during install"

install:
	@PROFILE=$(PROFILE) ./install.sh

minimal:
	@PROFILE=minimal ./install.sh

update:
	@./update.sh

upgrade-nvim:
	@UPGRADE_NVIM=true ./install.sh

gitconfig:
	@WITH_GITCONFIG=true ./install.sh

test:
	@for t in tests/*.test.sh; do bash "$$t" || exit 1; done

dry-run:
	@echo "=== DRY RUN ==="
	@echo "--- install.sh ---"
	@DRY_RUN=true ./install.sh
	@echo ""
	@echo "--- update.sh ---"
	@DRY_RUN=true ./update.sh
