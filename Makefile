.PHONY: test check smoke tui install setup linux migrate fmt bump

# The core and the terminal app (the default workspace members).
test:
	cargo test -p quire-core -p quire-tui -p quire-bindings

# The desktop app too when this machine can build it (libwebkit2gtk-4.1-dev).
check:
	python3 tools/validate_apple.py
	python3 tools/test_migrate_journal.py
	@if command -v node >/dev/null 2>&1; then node --check linux/src/app.js && node tools/check_media_library.js && node tools/check_linux_editor.js && node tools/check_search.js; else echo "skipping frontend checks: node is not installed"; fi
	cargo clippy -p quire-core -p quire-tui -- -D warnings
	cargo clippy -p quire-bindings --all-targets --all-features -- -D warnings
	@if pkg-config --exists webkit2gtk-4.1 2>/dev/null; then \
		cargo clippy -p quire-desktop -- -D warnings; \
	else \
		echo "skipping quire-desktop: no webkit2gtk-4.1 (see linux/README.md)"; \
	fi

# Drive every screen of the terminal app in a pseudo-terminal, twice: a roomy
# window in Cinema and a small one in Marathon. 23/23 each or it fails. The
# driver gives the app a scratch home (HOME, XDG_CONFIG_HOME, QUIRE_CONFIG_DIR),
# so the real settings are never read or written, on Linux or a Mac.
smoke: tui-debug
	@rm -rf target/smoke-a target/smoke-b target/smoke-a-scratch target/smoke-b-scratch && cp -r sample target/smoke-a && cp -r sample target/smoke-b
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

# One version number, everywhere it is written: the four fields release.yml
# checks against the tag, Cargo.lock, linux/package-lock.json, and the
# generated Xcode project (make check fails until that is regenerated).
# CHANGELOG.md, the commit and the tag stay yours: see Releases in CLAUDE.md.
bump:
	@test -n "$(V)" || (echo "usage: make bump V=x.y.z" && exit 2)
	python3 -I tools/bump_version.py "$(V)"
	$(MAKE) -C apple project
	cargo metadata --locked --format-version 1 >/dev/null
	@echo "→ $(V) in Cargo.toml, linux/ (3 files), both lock files and apple/Quire.xcodeproj"

.PHONY: apple apple-test
apple:
	$(MAKE) -C apple build

apple-test:
	$(MAKE) -C apple test
