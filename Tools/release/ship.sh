#!/bin/bash
# QotaFolio release lane. Each step is one sentence; `ship` runs them in order.
#
#   ship.sh health                 Says whether everything the lane needs is present.
#   ship.sh ship                   archive → export → verify → notarize+staple the app → package → notes → appcast → draft
#   ship.sh <step>                 Runs one step against the current output directory.
#   ship.sh triage <crash-file>    Reads a crash against the kept dSYMs, or prints the last notary log.
#
# `--method development` rehearses the mechanics with the local development
# certificate; notarize, staple and draft refuse under it. The default is
# developer-id, which signs through the cloud-managed certificate. An App Store
# Connect API key cannot cloud-sign a Developer ID identity, so that export
# authenticates with the Apple ID signed into Xcode and the key notarizes only.
#
# Nothing here creates a repository, pushes a commit, or publishes a release:
# `draft` writes go.sh and stops. That file runs on the owner's word alone.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
METHOD="developer-id"

# Who signs the app and where it publishes are facts about a Mac, not about the source,
# so they live outside the repository. `ship.env.example` beside this script shows the
# shape; every step but health and triage refuses to run until the real file is there.
SETTINGS="$HOME/.config/qotafolio/ship.env"
KEY_PATH= KEY_ID= ISSUER= TEAM= SPARKLE_ACCOUNT= REPO_SLUG=
if [ -f "$SETTINGS" ]; then
    # shellcheck source=/dev/null
    . "$SETTINGS"
fi

VERSION=$(awk '/MARKETING_VERSION:/ {gsub(/"/,""); print $2; exit}' "$ROOT/project.yml")
BUILD=$(awk '/CURRENT_PROJECT_VERSION:/ {gsub(/"/,""); print $2; exit}' "$ROOT/project.yml")
OUT="$ROOT/.artifacts/release/$VERSION-$BUILD"
DERIVED="$OUT/DerivedData"
ARCHIVE="$OUT/QotaFolio.xcarchive"
APP="$OUT/export/QotaFolio.app"
DMG="$OUT/QotaFolio-$VERSION.dmg"
ZIP="$OUT/QotaFolio-$VERSION.zip"
AUTH=(-authenticationKeyPath "$KEY_PATH" -authenticationKeyID "$KEY_ID" -authenticationKeyIssuerID "$ISSUER")

# The settings a step cannot proceed without; health reports them instead of refusing.
unset_settings() {
    local name
    for name in KEY_PATH KEY_ID ISSUER TEAM SPARKLE_ACCOUNT REPO_SLUG; do
        [ -n "${!name}" ] || printf '%s ' "$name"
    done
}
require_settings() {
    [ -f "$SETTINGS" ] \
        || fail "this Mac has no release settings: copy Tools/release/ship.env.example to $SETTINGS and fill it in"
    local unset_names; unset_names="$(unset_settings)"
    [ -z "$unset_names" ] || fail "$SETTINGS does not set ${unset_names% }"
}

say()  { printf '%s\n' "== $*"; }
fail() { printf '%s\n' "FAIL: $*" >&2; exit 1; }
log()  { mkdir -p "$OUT/logs"; printf '%s\n' "$OUT/logs/$1.log"; }

# --- health: says whether everything the lane needs is present and consistent.
health() {
    local ok=0 warn=0 bad=0
    check() { # status key message
        case "$1" in ok) ok=$((ok+1));; warn) warn=$((warn+1));; fail) bad=$((bad+1));; esac
        printf 'STATUS|%s|%s|%s\n' "$2" "$1" "$3"
    }
    printf 'INFO|version|%s (%s)\n' "$VERSION" "$BUILD"
    local unset_names; unset_names="$(unset_settings)"
    if [ ! -f "$SETTINGS" ]; then
        check fail settings "This Mac has no release settings; copy Tools/release/ship.env.example to $SETTINGS."
    elif [ -n "$unset_names" ]; then
        printf 'DETAIL|settings|unset: %s\n' "${unset_names% }"
        check fail settings "The release settings do not name everything the lane needs."
    else
        check ok settings "The release settings for this Mac are in place."
    fi
    if [ "$bad" -ne 0 ]; then
        # Every check below reads those settings, so without them there is one thing wrong,
        # not five.
        printf 'SUMMARY|ok=%d|warn=%d|fail=%d\n' "$ok" "$warn" "$bad"
        return 1
    fi
    [ -f "$KEY_PATH" ] && check ok asc_key "The App Store Connect key is in place." \
        || check fail asc_key "The App Store Connect key file is missing."
    security find-generic-password -l "Private key for signing Sparkle updates" -a "$SPARKLE_ACCOUNT" >/dev/null 2>&1 \
        && check ok sparkle_key "The update-signing key is in the Keychain." \
        || check fail sparkle_key "The update-signing key is not in the Keychain."
    local pub declared
    pub=$(sparkle_tool generate_keys -p --account "$SPARKLE_ACCOUNT" 2>/dev/null || true)
    declared=$(plist_value "$ROOT/Sources/Info.plist" SUPublicEDKey)
    if [ -n "$pub" ] && [ "$pub" = "$declared" ]; then
        check ok key_match "The app's update key matches the signing key."
    else
        printf 'DETAIL|key_match|keychain=%s info_plist=%s\n' "${pub:-unreadable}" "$declared"
        check fail key_match "The app's update key does not match the signing key."
    fi
    security find-identity -p codesigning -v 2>/dev/null | grep "Developer ID Application" >/dev/null \
        && check ok dev_id "A local Developer ID identity exists." \
        || check warn dev_id "No local Developer ID identity; the export signs through the cloud and needs the Apple ID signed into Xcode once."
    command -v xcodegen >/dev/null && check ok xcodegen "The project generator is installed." \
        || check fail xcodegen "xcodegen is missing."
    command -v gh >/dev/null && gh auth status >/dev/null 2>&1 \
        && check ok github "GitHub is signed in for the day the draft goes up." \
        || check warn github "GitHub is not reachable; the draft commands will need it on go-day."
    [ -z "$(git -C "$ROOT" status --porcelain)" ] && check ok git_clean "Every change is committed." \
        || check warn git_clean "Uncommitted changes exist; the release should build from a committed tree."
    printf 'SUMMARY|ok=%d|warn=%d|fail=%d\n' "$ok" "$warn" "$bad"
    [ "$bad" -eq 0 ]
}

# --- archive: archives Release for macOS with the project's own settings.
archive() {
    say "archiving $VERSION ($BUILD)"
    (cd "$ROOT" && xcodegen generate --no-env --spec project.yml --project . --project-root . >/dev/null)
    xcodebuild -project "$ROOT/QotaFolio.xcodeproj" -scheme QotaFolio -configuration Release \
        -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" \
        -archivePath "$ARCHIVE" -allowProvisioningUpdates "${AUTH[@]}" archive \
        > "$(log archive)" 2>&1 || fail "archive did not build; read $OUT/logs/archive.log"
    say "archived: $ARCHIVE"
}

# --- export: signs the app for direct distribution and lays it in export/.
export_app() {
    say "exporting with method $METHOD"
    /usr/libexec/PlistBuddy -c "Clear dict" -c "Add method string $METHOD" \
        -c "Add signingStyle string automatic" -c "Add teamID string $TEAM" \
        -c "Add destination string export" "$OUT/ExportOptions.plist" >/dev/null 2>&1 || true
    local extra=()
    # The cloud-managed Developer ID answers to the signed-in Apple ID; handing the API
    # key here makes Xcode use it instead, and the key cannot cloud-sign (FB16835802).
    [ "$METHOD" = development ] && extra=("${AUTH[@]}")
    rm -rf "$OUT/export"
    xcodebuild -exportArchive -archivePath "$ARCHIVE" \
        -exportOptionsPlist "$OUT/ExportOptions.plist" -exportPath "$OUT/export" \
        -allowProvisioningUpdates ${extra[0]+"${extra[@]}"} \
        > "$(log export)" 2>&1 || fail "export did not sign; read $OUT/logs/export.log"
    say "exported: $APP"
}

# --- verify: reads the exported app back and refuses anything a friend should not receive.
verify() {
    say "verifying the exported app"
    local expect="Developer ID Application"
    [ "$METHOD" = development ] && expect="Apple Development"
    codesign --verify --deep --strict "$APP" || fail "the signature does not verify"
    for object in \
        "$APP" \
        "$APP/Contents/Frameworks/Sparkle.framework" \
        "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" \
        "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" \
        "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" \
        "$APP/Contents/Frameworks/QotaFolioKit.framework" \
        "$APP/Contents/Frameworks/QotaFolioCoreXcode.framework" \
        "$APP/Contents/PlugIns/QotaFolioWidgets.appex" \
        "$APP/Contents/MacOS/qota"; do
        codesign -dvv "$object" 2>&1 | grep "Authority=$expect" >/dev/null \
            || fail "$(basename "$object") is not signed by $expect"
    done
    local group
    group="$TEAM.group.$(plist_value "$APP/Contents/Info.plist" CFBundleIdentifier)"
    codesign -d --entitlements - "$APP" 2>/dev/null | grep -F "$group" >/dev/null \
        || fail "the App Group entitlement $group did not survive the export"
    codesign -d --entitlements - "$APP" 2>/dev/null | grep "get-task-allow" >/dev/null \
        && fail "a debug entitlement is in the shipped app"
    [ -e "$APP/Contents/embedded.provisionprofile" ] && fail "a provisioning profile is embedded and none belongs"
    [ -d "$APP/Contents/Resources/Metadata.appintents" ] || fail "the App Intents metadata is missing"
    find "$APP/Contents/Frameworks/Sparkle.framework" -name "Downloader.xpc" | grep . >/dev/null \
        && fail "the pruned Sparkle downloader is back"
    local v b
    v=$(plist_value "$APP/Contents/Info.plist" CFBundleShortVersionString)
    b=$(plist_value "$APP/Contents/Info.plist" CFBundleVersion)
    [ "$v ($b)" = "$VERSION ($BUILD)" ] || fail "the app says $v ($b), the project says $VERSION ($BUILD)"
    codesign -dv "$APP" 2>&1 | grep "flags=.*(runtime)" >/dev/null || fail "hardened runtime is off"
    if [ "$METHOD" = "developer-id" ]; then
        codesign -dvv "$APP" 2>&1 | grep "Timestamp=" >/dev/null || fail "no secure timestamp on the app"
    fi
    say "verified: $expect, entitlements intact, versions agree"
}

# --- notarize: submits the app to Apple, staples its ticket, and hears Gatekeeper's ruling.
notarize() {
    [ "$METHOD" = "developer-id" ] || fail "a $METHOD build is not notarizable; this step needs the real export"
    say "submitting the app to Apple"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/QotaFolio-app.zip"
    xcrun notarytool submit "$OUT/QotaFolio-app.zip" --key "$KEY_PATH" --key-id "$KEY_ID" --issuer "$ISSUER" \
        --wait --output-format json > "$OUT/notarization-app.json" 2> "$(log notarize-app)" \
        || fail "the app submission failed; read $OUT/logs/notarize-app.log"
    local id status
    id=$(python3 -c "import json;print(json.load(open('$OUT/notarization-app.json'))['id'])")
    status=$(python3 -c "import json;print(json.load(open('$OUT/notarization-app.json'))['status'])")
    xcrun notarytool log "$id" --key "$KEY_PATH" --key-id "$KEY_ID" --issuer "$ISSUER" \
        > "$OUT/notarization-app-log.json" 2>/dev/null || true
    [ "$status" = "Accepted" ] || fail "Apple answered $status for the app; read $OUT/notarization-app-log.json"
    rm -f "$OUT/QotaFolio-app.zip"
    xcrun stapler staple "$APP" > "$(log staple-app)" 2>&1 || fail "stapling the app failed"
    xcrun stapler validate "$APP" >/dev/null || fail "the app's stapled ticket does not validate"
    syspolicy_check distribution "$APP" > "$(log syspolicy)" 2>&1 \
        || fail "syspolicy_check refuses the app; read $OUT/logs/syspolicy.log"
    say "app notarized ($id), stapled, and Gatekeeper-clean"
}

# --- package: seals the stapled app in the one container Gatekeeper answers for offline.
#
# A disk image would be prettier, and it cannot be honest here: a cloud-managed team holds
# no local Developer ID key, `codesign` has no cloud path, and an unsigned
# image is refused by Gatekeeper on download — measured, not assumed. The app inside carries
# its own stapled ticket, so a zip needs no signature of its own and never did.
package() {
    say "packaging the stapled app"
    rm -f "$ZIP"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
    local staged="$OUT/zip-check"
    rm -rf "$staged"; mkdir -p "$staged"
    ditto -x -k "$ZIP" "$staged"
    xcrun stapler validate "$staged/QotaFolio.app" >/dev/null \
        || fail "the app in the zip carries no stapled ticket"
    # spctl says nothing on success and speaks only to refuse, so the exit code is the answer.
    spctl --assess --type exec "$staged/QotaFolio.app" > "$(log gatekeeper)" 2>&1 \
        || fail "Gatekeeper refuses the app in the zip; read $OUT/logs/gatekeeper.log"
    spctl --assess --type exec -vv "$staged/QotaFolio.app" > "$(log gatekeeper)" 2>&1 || true
    rm -rf "$staged"
    say "packaged: $ZIP ($(du -h "$ZIP" | cut -f1 | tr -d ' ')), Gatekeeper-accepted from the archive"
}

# --- dmg: lays the stapled app and an Applications shortcut on a compressed disk image.
dmg() {
    say "building the disk image"
    local stage="$OUT/dmg-stage"
    rm -rf "$stage" "$DMG"
    mkdir -p "$stage"
    cp -R "$APP" "$stage/QotaFolio.app"
    ln -s /Applications "$stage/Applications"
    hdiutil create -volname "QotaFolio" -srcfolder "$stage" -ov -format UDZO "$DMG" \
        > "$(log dmg)" 2>&1 || fail "hdiutil did not build the image"
    rm -rf "$stage"
    say "built: $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
}

# --- staple: submits the image to Apple and fixes its ticket, so the download answers offline.
staple() {
    [ "$METHOD" = "developer-id" ] || fail "nothing to staple on a $METHOD build"
    say "submitting the image to Apple"
    xcrun notarytool submit "$DMG" --key "$KEY_PATH" --key-id "$KEY_ID" --issuer "$ISSUER" \
        --wait --output-format json > "$OUT/notarization.json" 2> "$(log notarize)" \
        || fail "the image submission failed; read $OUT/logs/notarize.log"
    local id status
    id=$(python3 -c "import json;print(json.load(open('$OUT/notarization.json'))['id'])")
    status=$(python3 -c "import json;print(json.load(open('$OUT/notarization.json'))['status'])")
    xcrun notarytool log "$id" --key "$KEY_PATH" --key-id "$KEY_ID" --issuer "$ISSUER" \
        > "$OUT/notarization-log.json" 2>/dev/null || true
    [ "$status" = "Accepted" ] || fail "Apple answered $status for the image; read $OUT/notarization-log.json"
    xcrun stapler staple "$DMG" > "$(log staple)" 2>&1 || fail "stapling the image failed; read $OUT/logs/staple.log"
    xcrun stapler validate "$DMG" >/dev/null || fail "the image's stapled ticket does not validate"
    say "image notarized ($id), stapled, and validated"
}

# --- appcast: signs the update feed with the EdDSA key and proves the signature.
appcast() {
    say "generating the appcast"
    local cast_dir="$OUT/appcast"
    rm -rf "$cast_dir"; mkdir -p "$cast_dir"
    ln "$ZIP" "$cast_dir/" 2>/dev/null || cp "$ZIP" "$cast_dir/"
    [ -f "$OUT/notes.md" ] && cp "$OUT/notes.md" "$cast_dir/QotaFolio-$VERSION.md"
    sparkle_tool generate_appcast --account "$SPARKLE_ACCOUNT" \
        --download-url-prefix "https://github.com/$REPO_SLUG/releases/download/v$VERSION/" \
        --link "https://github.com/$REPO_SLUG" --embed-release-notes \
        -o "$OUT/appcast.xml" "$cast_dir" > "$(log appcast)" 2>&1 \
        || fail "generate_appcast failed; read $OUT/logs/appcast.log"
    verify_appcast_signature
    say "appcast signed and verified against the published key"
}

# The enclosure's EdDSA signature, checked against the public key the app ships with.
verify_appcast_signature() {
    local sig pub
    sig=$(sed -n 's/.*edSignature="\([^"]*\)".*/\1/p' "$OUT/appcast.xml" | head -1)
    pub=$(plist_value "$ROOT/Sources/Info.plist" SUPublicEDKey)
    [ -n "$sig" ] || fail "the appcast carries no EdDSA signature"
    python3 - "$sig" "$pub" "$ZIP" <<'PY' || fail "the appcast signature does not verify against SUPublicEDKey"
import base64, subprocess, sys, tempfile
sig, pub, archive = sys.argv[1:]
spki = bytes.fromhex("302a300506032b6570032100") + base64.b64decode(pub)
with tempfile.NamedTemporaryFile(suffix=".der") as key, tempfile.NamedTemporaryFile() as raw:
    key.write(spki); key.flush()
    raw.write(base64.b64decode(sig)); raw.flush()
    sys.exit(subprocess.run(["openssl", "pkeyutl", "-verify", "-pubin", "-inkey", key.name,
                             "-keyform", "DER", "-rawin", "-in", archive, "-sigfile", raw.name],
                            capture_output=True).returncode)
PY
}

# --- notes: renders the release notes and the release-page text beside the artifacts.
notes() {
    say "writing the notes"
    sed -e "s/{{VERSION}}/$VERSION/g" -e "s/{{BUILD}}/$BUILD/g" \
        "$ROOT/docs/release/RELEASE_NOTES.template.md" > "$OUT/notes.md"
    sed -e "s/{{VERSION}}/$VERSION/g" -e "s/{{SHA256}}/$(shasum -a 256 "$ZIP" | cut -d' ' -f1)/g" \
        "$ROOT/docs/release/RELEASE-PAGE.md" > "$OUT/release-page.md"
    say "written: notes.md, release-page.md"
}

# --- draft: writes the go-day commands and stops, because the word is the owner's.
#
# The push runs from the primary checkout, whose branch is `main` — a public repository
# should lead with main, not with the branch a stage happened to be built on. The main
# working tree is asked for rather than named, so the file is right on any machine.
#
# Everything go-day needs is written here rather than added to the file afterwards. A
# generated file that has to be edited by hand loses that edit the next time it is
# generated, and the next time is the next release.
draft() {
    say "writing go.sh (nothing runs today)"
    local primary
    primary=$(git -C "$ROOT" worktree list --porcelain | sed -n '1s/^worktree //p')
    cat > "$OUT/go.sh" <<GO
#!/bin/bash
# QotaFolio $VERSION ($BUILD) — the commands that publish this release, in order.
# Run from the primary checkout, on main, with the release committed and tagged and
# origin pointing at $REPO_SLUG.
set -euo pipefail
cd "$primary"
test "\$(git rev-parse --abbrev-ref HEAD)" = main || { echo "not on main"; exit 1; }
test -z "\$(git status --porcelain)" || { echo "the tree is not clean"; exit 1; }
git push origin main
git push origin v$VERSION

# Drafted first so every asset is in place before anyone is told the release exists.
gh release create v$VERSION --draft --title "QotaFolio $VERSION" --notes-file "$OUT/release-page.md" \\
    "$ZIP" "$OUT/appcast.xml" "$OUT/dSYMs.zip"
gh release edit v$VERSION --draft=false
GO
    chmod +x "$OUT/go.sh"
    (cd "$ARCHIVE/dSYMs" && ditto -c -k --sequesterRsrc . "$OUT/dSYMs.zip")
    say "prepared: $OUT/go.sh"
    sed -n '5,99p' "$OUT/go.sh"
}

# --- triage: reads a crash with the kept dSYMs, or shows the last notary log.
triage() {
    if [ $# -ge 1 ] && [ -f "$1" ]; then
        exec xcsym crash --format=summary --dsym-paths "$ARCHIVE/dSYMs" "$1"
    fi
    [ -f "$OUT/notarization-log.json" ] && exec cat "$OUT/notarization-log.json"
    [ -f "$OUT/notarization-app-log.json" ] && exec cat "$OUT/notarization-app-log.json"
    fail "give me a crash file, or run notarize first for a log to read"
}

# --- helpers
plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null; }
sparkle_tool() {
    local tool="$1"; shift
    local bin
    bin=$(find "$DERIVED/SourcePackages/artifacts/sparkle" -name "$tool" -type f 2>/dev/null | head -1)
    [ -n "$bin" ] || bin=$(find "$HOME/Library/Developer/Xcode/DerivedData" -path "*artifacts/sparkle*" -name "$tool" -type f 2>/dev/null | head -1)
    [ -n "$bin" ] || fail "Sparkle's $tool is not on disk; run archive once to resolve packages"
    "$bin" "$@"
}

ship() {
    archive; export_app; verify
    if [ "$METHOD" = "developer-id" ]; then
        notarize; package; notes; appcast; draft
    else
        say "rehearsal: notarization, packaging and the draft wait for the developer-id export"
        notes; appcast
    fi
}

main() {
    local cmd="${1:-health}"; shift || true
    while [ $# -gt 0 ]; do
        case "$1" in
            --method) METHOD="$2"; shift 2;;
            *) break;;
        esac
    done
    mkdir -p "$OUT"
    case "$cmd" in
        health) health;;
        triage) triage "$@";;
        export) require_settings; export_app "$@";;
        archive|verify|package|dmg|notarize|staple|appcast|notes|draft|ship)
            require_settings; "$cmd" "$@";;
        *) fail "unknown step: $cmd (health archive export verify notarize package appcast notes draft ship triage; dmg and staple build an optional disk image)";;
    esac
}
main "$@"
