.PHONY: test check smoke tui install setup linux migrate fmt

# The core and the terminal app (the default workspace members).
test:
	cargo test

# The desktop app too when this machine can build it (libwebkit2gtk-4.1-dev).
check:
	cargo clippy -p quire-core -p quire-tui -- -D warnings
	@if pkg-config --exists webkit2gtk-4.1 2>/dev/null; then \
		cargo clippy -p quire-desktop -- -D warnings; \
	else \
		echo "skipping quire-desktop: no webkit2gtk-4.1 (see linux/README.md)"; \
	fi

# Drive every screen of the terminal app in a pseudo-terminal, twice: a roomy
# window in Cinema and a small one in Marathon. 20/20 each or it fails.
smoke: tui-debug
	@rm -rf target/smoke-a target/smoke-b && cp -r sample target/smoke-a && cp -r sample target/smoke-b
	python3 -I tools/drive_tui.py target/debug/quire target/smoke-a 100 30 cinema
	python3 -I tools/drive_tui.py target/debug/quire target/smoke-b 80 24 marathon

tui-debug:
	cargo build -p quire-tui

tui:
	cargo build --release -p quire-tui
	@echo "→ target/release/quire and target/release/jnl"

# Installs both names into ~/.cargo/bin.
install:
	cargo install --path tui --force

# The full installer: finds jnl / Nook / Wander, installs Quire, sets it up.
setup:
	./install.sh

# Needs libwebkit2gtk-4.1-dev and the rest of linux/README.md's list.
linux:
	cd linux && npm install && npx tauri build

# Fold a journal's inbox.md into inbox/ and .nook/ into .quire/ (dry run).
migrate:
	@test -n "$(DIR)" || (echo "usage: make migrate DIR=~/path/to/journal" && exit 2)
	python3 -I tools/migrate_journal.py "$(DIR)"

fmt:
	cargo fmt --all
