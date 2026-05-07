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

.PHONY: Baguette clean smoke-mac
