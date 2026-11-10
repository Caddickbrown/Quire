PROJECT = Quire.xcodeproj
SCHEME = Quire
.PHONY: project core build build-mac build-ios test uitest open
# The simulator the UI tests drive; override with `make uitest UITEST_DESTINATION=…`.
UITEST_DESTINATION ?= platform=iOS Simulator,name=iPhone 17 Pro
project:
	python3 gen_pbxproj.py
core:
	./build-core.sh
build: core project
	$(MAKE) build-mac build-ios
build-mac:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
build-ios:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
test: core project
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
# XCUITest over the writing page, in a simulator (never on the Mac itself).
uitest: core project
	xcodebuild -project $(PROJECT) -scheme QuireUITests -configuration Debug -destination '$(UITEST_DESTINATION)' -only-testing:QuireUITests test
open: core project
	open $(PROJECT)
