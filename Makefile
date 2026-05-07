Baguette:
	./build.sh

clean:
	swift package clean 2>/dev/null || true
	rm -f Baguette

# End-to-end smoke for the macOS app path (mac list / screenshot /
# describe-ui / input + serve routes) against a running TextEdit.
# Requires Screen Recording + Accessibility TCC grants on ./Baguette;
# see scripts/smoke-mac.sh's header for setup.
smoke-mac: Baguette
	./scripts/smoke-mac.sh

# Install the locally built binary as `baguette` on PATH. Defaults to
# Apple-Silicon Homebrew's prefix (/opt/homebrew/bin) since that's
# where `brew install tddworks/tap/baguette` would normally land —
# installing here shadows the brewed version with this branch's
# build. Override with `PREFIX=…` for /usr/local or ~/bin.
#
# Two pieces ship together: the binary itself, and the SPM-generated
# `Baguette_Baguette.bundle` that holds Resources/Web/. WebRoot.swift's
# fallback chain looks for the bundle as a sidecar next to the
# executable, so both must land in the same dir.
PREFIX ?= /opt/homebrew
BUNDLE := Baguette_Baguette.bundle

install: Baguette
	install -m 755 ./Baguette "$(PREFIX)/bin/baguette"
	rm -rf "$(PREFIX)/bin/$(BUNDLE)"
	cp -R ".build/release/$(BUNDLE)" "$(PREFIX)/bin/$(BUNDLE)"
	@echo "→ installed $(PREFIX)/bin/baguette + $(BUNDLE) (run 'baguette --version' to verify)"

uninstall:
	rm -f "$(PREFIX)/bin/baguette"
	rm -rf "$(PREFIX)/bin/$(BUNDLE)"

.PHONY: Baguette clean smoke-mac install uninstall
