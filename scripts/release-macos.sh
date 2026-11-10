#!/bin/sh
# Build the macOS arm64 release archive for je.
#
# Required for a public release:
#   SIGN_IDENTITY   e.g. "Developer ID Application: Eric Hare (TEAMID)"
#   NOTARY_PROFILE  a notarytool keychain profile (see `notarytool store-credentials`)
# Local validation only:
#   ALLOW_ADHOC=1   ad-hoc sign instead; the archive must not be published
#   ALLOW_DIRTY=1   build from a dirty tree; the manifest records source_dirty
set -eu

cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*public static let current = "\([^"]*\)".*/\1/p' Sources/JECore/Version.swift)
[ -n "$VERSION" ] || { echo "could not read version" >&2; exit 1; }

if [ -n "$(git status --porcelain)" ] && [ "${ALLOW_DIRTY:-0}" != "1" ]; then
    echo "working tree is dirty; commit first or set ALLOW_DIRTY=1 for a local build" >&2
    exit 1
fi

SIGNING="Developer ID signed and notarized"
if [ -z "${SIGN_IDENTITY:-}" ]; then
    if [ "${ALLOW_ADHOC:-0}" = "1" ]; then
        SIGN_IDENTITY="-"
        SIGNING="ad-hoc signing for local validation; no Developer ID or notarization claim"
        echo "WARNING: ad-hoc build for local validation only. Do not publish." >&2
    else
        echo "SIGN_IDENTITY is required (or ALLOW_ADHOC=1 for a local build)" >&2
        exit 1
    fi
fi

swift build -c release --product je
swift build -c release --product je-secret-helper
swift build -c release --product je-foundation-helper
BIN_DIR=$(swift build -c release --show-bin-path)

STAGE="dist/stage-$VERSION"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp "$BIN_DIR/je" "$BIN_DIR/je-secret-helper" "$BIN_DIR/je-foundation-helper" LICENSE "$STAGE/"
strip -x "$STAGE/je" "$STAGE/je-secret-helper" "$STAGE/je-foundation-helper"

for bin in je je-secret-helper je-foundation-helper; do
    archs=$(lipo -archs "$STAGE/$bin")
    [ "$archs" = "arm64" ] || { echo "$bin has unexpected architectures: $archs" >&2; exit 1; }
    if [ "$SIGN_IDENTITY" = "-" ]; then
        codesign --force --identifier "io.jestats.$bin" --sign - "$STAGE/$bin"
    else
        codesign --force --timestamp --options runtime \
            --identifier "io.jestats.$bin" --sign "$SIGN_IDENTITY" "$STAGE/$bin"
    fi
    codesign --verify --strict "$STAGE/$bin"
done

if [ "$SIGN_IDENTITY" != "-" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
    # Loose CLI binaries cannot be stapled; the notarization ticket is
    # resolved online by hash when Gatekeeper assesses the signed binary.
    ditto -c -k "$STAGE" dist/notarize.zip
    xcrun notarytool submit dist/notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
    rm dist/notarize.zip
elif [ "$SIGN_IDENTITY" != "-" ]; then
    SIGNING="Developer ID signed; notarization skipped (NOTARY_PROFILE unset)"
    echo "WARNING: NOTARY_PROFILE unset; skipping notarization." >&2
fi

ARTIFACT="je-$VERSION-macos-arm64.tar.gz"
(cd "$STAGE" && COPYFILE_DISABLE=1 tar -czf "../$ARTIFACT" je je-secret-helper je-foundation-helper LICENSE)
SHA256=$(shasum -a 256 "dist/$ARTIFACT" | cut -d' ' -f1)
BYTES=$(stat -f%z "dist/$ARTIFACT")
printf '%s  %s\n' "$SHA256" "$ARTIFACT" > dist/SHA256SUMS

DIRTY=false
[ -n "$(git status --porcelain)" ] && DIRTY=true
python3 - "$VERSION" "$ARTIFACT" "$SHA256" "$BYTES" "$DIRTY" "$SIGNING" <<'PY'
import json, subprocess, sys
version, artifact, sha256, nbytes, dirty, signing = sys.argv[1:7]
manifest = {
    "version": version,
    "artifact": artifact,
    "sha256": sha256,
    "bytes": int(nbytes),
    "architecture": "arm64",
    "build_macos": subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip(),
    "swift": subprocess.check_output(["swift", "--version"], text=True).splitlines()[0],
    "source_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
    "source_dirty": dirty == "true",
    "signing": signing,
}
with open("dist/build-manifest.json", "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
PY

echo "built dist/$ARTIFACT"
echo "sha256 $SHA256"
echo "next: gh release create v$VERSION dist/$ARTIFACT dist/SHA256SUMS dist/build-manifest.json"
echo "then: point the homebrew-tap formula at v$VERSION with this sha256"
