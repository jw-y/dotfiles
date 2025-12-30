.PHONY: install update dry-run help

help:
	@echo "Available targets:"
	@echo "  make install    - Run full installation"
	@echo "  make update     - Update existing configs"
	@echo "  make dry-run    - Show what would be installed/updated"
	@echo "  make help       - Show this help message"

install:
	@echo "Running installation..."
	@./install.sh

update:
	@echo "Updating configurations..."
	@./update.sh

dry-run:
	@echo "=== DRY RUN MODE ==="
	@echo "Install script:"
	@DRY_RUN=true ./install.sh || true
	@echo ""
	@echo "Update script:"
	@DRY_RUN=true ./update.sh || true

