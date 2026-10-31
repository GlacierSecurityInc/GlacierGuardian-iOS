#!/bin/sh
# Regenerates the Licenses pane shown under Glacier in iOS Settings (Settings > Licenses opens it).
# Run from the repo root after `pod install` or any Swift package change, then commit the result.
# Requires LicensePlist: `brew install licenseplist`.
#
# Libraries LicensePlist can't detect (vendored code, Go modules, binary SDKs with no
# license file) are listed by hand in Scripts/license_plist.yml.
set -euo pipefail

cd "$(dirname "$0")/.."

BUNDLE="Glacier/Resources/Settings.bundle"

rm -rf "${BUNDLE}/com.mono0926.LicensePlist" "${BUNDLE}/com.mono0926.LicensePlist.plist"

# Package licenses come from the GitHub API, whose unauthenticated rate limit runs out after
# about one run an hour. Use the gh CLI's token when there is one.
if [ -z "${LICENSE_PLIST_GITHUB_TOKEN:-}" ] && command -v gh >/dev/null 2>&1; then
  LICENSE_PLIST_GITHUB_TOKEN="$(gh auth token 2>/dev/null || true)"
  export LICENSE_PLIST_GITHUB_TOKEN
fi

# A license that fails to download fails the run rather than silently leaving the pane;
# `git checkout` the bundle to get the old pane back.
license-plist \
  --fail-if-missing-license \
  --output-path "${BUNDLE}" \
  --config-path Scripts/license_plist.yml \
  --pods-path Pods \
  --package-path Glacier.xcworkspace/xcshareddata/swiftpm/Package.resolved \
  --add-version-numbers \
  --suppress-opening-directory

# The run summary is for whoever ran the script, not for the app bundle.
rm -f "${BUNDLE}/com.mono0926.LicensePlist.latest_result.txt"
