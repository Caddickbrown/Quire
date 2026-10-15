PROJECT = Quire.xcodeproj
SCHEME = Quire
.PHONY: project core build build-mac build-ios test open
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
open: core project
	open $(PROJECT)
