PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
TARGET ?= brew-upgrade
SRC ?= brew-upgrade.sh
CONFIG_SAMPLE ?= .brew-upgrade.conf.example
CONFIG_DEST ?= $(HOME)/.brew-upgrade.conf

LAUNCHAGENT_TEMPLATE ?= launchagent/com.homebrew.upgrade.plist
LAUNCHAGENT_LABEL ?= com.homebrew.upgrade
LAUNCHAGENT_DEST ?= $(HOME)/Library/LaunchAgents/$(LAUNCHAGENT_LABEL).plist

.PHONY: help install uninstall launchagent-install launchagent-uninstall

help: ## Show available targets
	@awk 'BEGIN { FS = ":.*##" } /^[a-zA-Z_-]+:.*##/ { printf "  %-24s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

install: ## Install script and seed user config
	mkdir -p "$(BINDIR)"
	install -m 700 "$(SRC)" "$(BINDIR)/$(TARGET)"
	@if [ ! -f "$(CONFIG_DEST)" ]; then \
		install -m 600 "$(CONFIG_SAMPLE)" "$(CONFIG_DEST)"; \
		echo "Seeded config at $(CONFIG_DEST)"; \
	else \
		echo "Config already exists at $(CONFIG_DEST) (left unchanged)"; \
	fi
	@echo "Installed $(TARGET) to $(BINDIR)/$(TARGET)"

uninstall: ## Remove installed script
	rm -f "$(BINDIR)/$(TARGET)"
	@echo "Removed $(BINDIR)/$(TARGET)"

launchagent-install: ## Install and load the LaunchAgent (scheduled daily run)
	@mkdir -p "$(HOME)/Library/LaunchAgents"
	sed 's|__HOME__|$(HOME)|g' "$(LAUNCHAGENT_TEMPLATE)" > "$(LAUNCHAGENT_DEST)"
	@echo "Installed LaunchAgent to $(LAUNCHAGENT_DEST)"
	launchctl bootout gui/$$(id -u) "$(LAUNCHAGENT_DEST)" 2>/dev/null || true
	launchctl bootstrap gui/$$(id -u) "$(LAUNCHAGENT_DEST)"
	@echo "LaunchAgent loaded ($(LAUNCHAGENT_LABEL))"

launchagent-uninstall: ## Unload and remove the LaunchAgent
	-launchctl bootout gui/$$(id -u) "$(LAUNCHAGENT_DEST)" 2>/dev/null
	rm -f "$(LAUNCHAGENT_DEST)"
	@echo "Removed $(LAUNCHAGENT_DEST)"
