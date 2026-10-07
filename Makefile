# Build and run Curtain from the command line.
#
#   make          build the .app into build/Curtain.app
#   make run      build, then (re)launch it from the build folder
#   make install  build, copy to /Applications, launch from there
#   make stop     quit a running instance
#   make test     run the unit tests
#   make clean    delete build output
#
# `swift build` produces a bare executable. macOS wants a menu bar app to live
# in a .app bundle (that is where Info.plist's "no Dock icon" flag is read
# from), so the `build` target wraps the executable in one by hand. The bundle
# is ad-hoc signed so macOS does not complain when launching it.

APP := build/Curtain.app
BIN := .build/release/Curtain
SRC := Sources/Curtain
# The Command Line Tools ship Swift Testing (the `Testing` module) but SwiftPM
# does not look in the folders they put it in, so `make test` points it there.
FW  := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
TL  := /Library/Developer/CommandLineTools/Library/Developer/usr/lib

.PHONY: build run install stop test clean

build:
	swift build -c release
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BIN) $(APP)/Contents/MacOS/Curtain
	cp $(SRC)/Info.plist $(APP)/Contents/Info.plist
	cp $(SRC)/Shaders.metal $(APP)/Contents/Resources/Shaders.metal
	codesign --force --sign - $(APP)
	@echo "Built $(APP)"

# Launch Services sometimes refuses (error -600) to relaunch an app that has
# only just quit, so launching retries for a few seconds.
define launch
	@for i in 1 2 3 4 5 6; do open "$(1)" 2>/dev/null && exit 0; sleep 1; done; \
	 echo "could not launch $(1)"; exit 1
endef

run: build stop
	$(call launch,$(APP))

install: build stop
	rm -rf /Applications/Curtain.app
	cp -R $(APP) /Applications/Curtain.app
	$(call launch,/Applications/Curtain.app)
	@echo "Installed /Applications/Curtain.app"

stop:
	@pkill -x Curtain || true
	@while pgrep -x Curtain >/dev/null; do sleep 0.1; done   # `open` fails if the old one is still exiting

test:
	swift test --disable-xctest --enable-swift-testing \
	  -Xswiftc -F$(FW) -Xlinker -F$(FW) \
	  -Xlinker -rpath -Xlinker $(FW) -Xlinker -rpath -Xlinker $(TL)

clean:
	rm -rf .build build
