#!/bin/bash
# Promote [Unreleased] section to a versioned release in CHANGELOG.md,
# then reset [Unreleased] to an empty section at the top.
# Usage: ./scripts/promote-changelog.sh <version> [date] [changelog_file]
# Example: ./scripts/promote-changelog.sh 0.1.2 2026-05-02

set -e

VERSION="${1#v}"
RELEASE_DATE="${2:-$(date +%Y-%m-%d)}"
CHANGELOG_FILE="${3:-CHANGELOG.md}"

if [ -z "$VERSION" ]; then
    echo "Usage: $0 <version> [date] [changelog_file]" >&2
    exit 1
fi

if [ ! -f "$CHANGELOG_FILE" ]; then
    echo "Error: $CHANGELOG_FILE not found" >&2
    exit 1
fi

if ! grep -q "^## \[Unreleased\]" "$CHANGELOG_FILE"; then
    echo "Error: No [Unreleased] section found in $CHANGELOG_FILE" >&2
    exit 1
fi

# Derive repo URL and previous version from the existing [Unreleased] reference link
# e.g. [Unreleased]: https://github.com/tddworks/baguette/compare/v0.1.1...HEAD
UNRELEASED_LINK=$(grep "^\[Unreleased\]:" "$CHANGELOG_FILE" || true)
REPO_URL=""
PREV_VERSION=""
if [ -n "$UNRELEASED_LINK" ]; then
    REPO_URL=$(echo "$UNRELEASED_LINK" | sed 's|\[Unreleased\]: ||' | sed 's|/compare/.*||' | sed 's|/releases/.*||')
    PREV_VERSION=$(echo "$UNRELEASED_LINK" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 | sed 's/^v//')
fi

TEMP_FILE=$(mktemp)
awk \
    -v version="$VERSION" \
    -v date="$RELEASE_DATE" \
    -v repo_url="$REPO_URL" \
    -v prev_version="$PREV_VERSION" '
    # Replace [Unreleased] header: leave an empty section, then open the versioned one
    /^## \[Unreleased\]/ {
        print "## [Unreleased]"
        print ""
        print "---"
        print ""
        print "## [" version "] - " date
        next
    }

    # Update reference link + insert new versioned link below it
    /^\[Unreleased\]:/ && repo_url != "" {
        print "[Unreleased]: " repo_url "/compare/v" version "...HEAD"
        if (prev_version != "") {
            print "[" version "]: " repo_url "/compare/v" prev_version "...v" version
        }
        next
    }

    { print }
' "$CHANGELOG_FILE" > "$TEMP_FILE"

mv "$TEMP_FILE" "$CHANGELOG_FILE"
echo "Promoted [Unreleased] → [$VERSION] - $RELEASE_DATE in $CHANGELOG_FILE"
