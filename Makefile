Baguette:
	./build.sh

test-release:
	./build.sh
	node scripts/test-websocket-release.mjs

test-web:
	node --test 'Tests/Web/**/*.test.js'

# Regenerate docs/commands.md, docs/README.md and the baguette skill references (never edit those by hand)
docs:
	swift build
	python3 scripts/gen-docs.py .build/debug/Baguette

# Report docs against docs/documentation-design/ (links, budgets, changelog)
check-docs:
	python3 scripts/check-docs.py

# What unit coverage leaves out: codecov.yml's one list, and Internal/System/ kept thin
check-coverage:
	python3 scripts/check-coverage.py

# Release-time changelog scripts: extract → promote → rollover
test-changelog:
	scripts/test-changelog-release.sh

clean:
	swift package clean 2>/dev/null || true
	rm -f Baguette

.PHONY: Baguette clean test-release test-web docs check-docs check-coverage test-changelog
