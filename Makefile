# Nook — build helpers.
# The Xcode project is generated from gen_pbxproj.py; never hand-edit the pbxproj.

PROJECT = Nook.xcodeproj
SCHEME  = Nook

.PHONY: project icon check build-mac build-ios build open clean

project:            ## Regenerate Nook.xcodeproj/project.pbxproj
	python3 gen_pbxproj.py

icon:               ## Re-render the app icon (concept: ribbon, light + iOS dark) at all sizes
	swift tools/make_icon.swift ribbon

check:              ## Run the JournalParser verification (jnl parity)
	@mkdir -p /tmp/nook-check
	cp Tests/ParserChecks.swift /tmp/nook-check/main.swift
	xcrun swiftc Nook/Models/Entry.swift Nook/Models/JournalParser.swift \
		Nook/Models/Media.swift Nook/Models/SearchQuery.swift \
		Nook/Models/ListContinuation.swift \
		/tmp/nook-check/main.swift -o /tmp/nook-check/run
	/tmp/nook-check/run

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
