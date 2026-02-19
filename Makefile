PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
TARGET ?= brew-upgrade
SRC ?= brew-upgrade.sh
CONFIG_SAMPLE ?= .brew-upgrade.conf.example
CONFIG_DEST ?= $(HOME)/.brew-upgrade.conf

.PHONY: install uninstall

install:
	mkdir -p "$(BINDIR)"
	install -m 700 "$(SRC)" "$(BINDIR)/$(TARGET)"
	@if [ ! -f "$(CONFIG_DEST)" ]; then \
		install -m 600 "$(CONFIG_SAMPLE)" "$(CONFIG_DEST)"; \
		echo "Seeded config at $(CONFIG_DEST)"; \
	else \
		echo "Config already exists at $(CONFIG_DEST) (left unchanged)"; \
	fi
	@echo "Installed $(TARGET) to $(BINDIR)/$(TARGET)"

uninstall:
	rm -f "$(BINDIR)/$(TARGET)"
	@echo "Removed $(BINDIR)/$(TARGET)"
