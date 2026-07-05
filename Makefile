# Jibber — build helpers.
# The Xcode project is generated from gen_pbxproj.py; never hand-edit the pbxproj.

PROJECT = Jibber.xcodeproj
SCHEME  = Jibber

.PHONY: project icon check build-mac build-ios build open clean

project:            ## Regenerate Jibber.xcodeproj/project.pbxproj
	python3 gen_pbxproj.py

icon:               ## Re-render the app icon (concept: lines) at all sizes
	swift tools/make_icon.swift lines

check:              ## Run the JournalParser verification (jnl parity)
	@mkdir -p /tmp/jibber-check
	cp Tests/ParserChecks.swift /tmp/jibber-check/main.swift
	xcrun swiftc Jibber/Models/Entry.swift Jibber/Models/JournalParser.swift \
		/tmp/jibber-check/main.swift -o /tmp/jibber-check/run
	/tmp/jibber-check/run

build-mac: project  ## Build for macOS (unsigned)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build

build-ios: project  ## Build for the iOS Simulator (unsigned)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build

build: build-mac build-ios

open: project       ## Open the project in Xcode
	open $(PROJECT)

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean
