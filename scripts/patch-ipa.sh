#!/usr/bin/env bash
# patch-ipa.sh — inject miOS.dylib into an Instagram IPA and emit a patched IPA.
#
# usage:
#   patch-ipa.sh <Instagram.ipa> <miOS.dylib> [output.ipa]
#
# Produces an IPA with:
#   Payload/Instagram.app/Instagram                 ← patched to LC_LOAD_DYLIB our dylib
#   Payload/Instagram.app/Frameworks/miOS.dylib     ← injected
#   Payload/Instagram.app/_CodeSignature/           ← wiped (sign with your cert / ldid)
#
# This script does NOT sign the IPA with your Apple Developer cert.
# Pass it through Sideloadly / AltStore / TrollStore for final signing. For a
# jailbroken device, run `ldid -S` on the binaries (also done here if ldid is
# available) and the IPA will install via TrollStore directly.
#
# Dependencies:
#   - unzip, zip (always present)
#   - insert_dylib (https://github.com/tyilo/insert_dylib) OR install_name_tool
#     (comes with Xcode on macOS)
#   - ldid (optional, used to self-sign for TrollStore / jailbreak install)
#
# On Linux you can get insert_dylib from https://github.com/Jhonsonlaid/insert_dylib
# and ldid from https://github.com/ProcursusTeam/ldid.

set -euo pipefail

IPA_IN="${1:-}"
DYLIB="${2:-}"
IPA_OUT="${3:-}"

if [[ -z "$IPA_IN" || -z "$DYLIB" ]]; then
    echo "usage: $0 <Instagram.ipa> <miOS.dylib> [output.ipa]" >&2
    exit 1
fi
[[ -f "$IPA_IN"  ]] || { echo "No such file: $IPA_IN"  >&2; exit 1; }
[[ -f "$DYLIB"   ]] || { echo "No such file: $DYLIB"   >&2; exit 1; }

if [[ -z "$IPA_OUT" ]]; then
    base="$(basename "$IPA_IN" .ipa)"
    IPA_OUT="${base}-miOS.ipa"
fi

# Which injector tool is available?
if command -v insert_dylib >/dev/null 2>&1; then
    INJECT_TOOL=insert_dylib
elif command -v install_name_tool >/dev/null 2>&1; then
    INJECT_TOOL=install_name_tool
else
    echo "Neither insert_dylib nor install_name_tool is on PATH." >&2
    echo "Install insert_dylib (https://github.com/tyilo/insert_dylib) and retry." >&2
    exit 1
fi

echo "[*] Unpacking $IPA_IN …"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
unzip -q -o "$IPA_IN" -d "$WORK"

# Find the .app and its executable (from CFBundleExecutable in Info.plist, else guess).
APP_DIR="$(find "$WORK/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
[[ -n "$APP_DIR" ]] || { echo "No .app bundle inside Payload/." >&2; exit 1; }
APP_NAME="$(basename "$APP_DIR" .app)"
PLIST="$APP_DIR/Info.plist"

EXE_NAME="$APP_NAME"
if command -v plutil >/dev/null 2>&1; then
    EXE_NAME="$(plutil -extract CFBundleExecutable raw "$PLIST" 2>/dev/null || echo "$APP_NAME")"
elif command -v PlistBuddy >/dev/null 2>&1; then
    EXE_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$PLIST" 2>/dev/null || echo "$APP_NAME")"
fi
EXE_PATH="$APP_DIR/$EXE_NAME"
[[ -f "$EXE_PATH" ]] || { echo "Executable not found: $EXE_PATH" >&2; exit 1; }

echo "[*] App bundle: $APP_DIR"
echo "[*] Executable: $EXE_PATH"

# Verify the IPA is for Instagram (hard-coded target of our dylib).
BID=""
if command -v plutil >/dev/null 2>&1; then
    BID="$(plutil -extract CFBundleIdentifier raw "$PLIST" 2>/dev/null || true)"
elif command -v PlistBuddy >/dev/null 2>&1; then
    BID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST" 2>/dev/null || true)"
fi
if [[ -n "$BID" && "$BID" != "com.burbn.instagram" ]]; then
    echo "[!] Warning: bundle id is '$BID', not com.burbn.instagram." >&2
    echo "    miOS.dylib's constructor only engages on com.burbn.instagram, so"
    echo "    injecting it into another app is a no-op (nothing bad will happen)."
fi

# Enable file sharing so diagnostic logs (Documents/miOS-diag.log, mios-loaded.txt) are
# visible in Finder / the Files app without a jailbreak. Harmless on a normal install; set
# MIOS_NO_FILESHARING=1 to skip. Needs plutil (macOS) or PlistBuddy; silently skipped otherwise.
if [[ "${MIOS_NO_FILESHARING:-0}" != "1" ]]; then
    if command -v plutil >/dev/null 2>&1; then
        plutil -replace UIFileSharingEnabled -bool true "$PLIST" 2>/dev/null \
            || plutil -insert UIFileSharingEnabled -bool true "$PLIST" 2>/dev/null || true
        plutil -replace LSSupportsOpeningDocumentsInPlace -bool true "$PLIST" 2>/dev/null \
            || plutil -insert LSSupportsOpeningDocumentsInPlace -bool true "$PLIST" 2>/dev/null || true
        echo "[*] Enabled UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace (for diag logs)."
    elif command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c 'Set :UIFileSharingEnabled true' "$PLIST" 2>/dev/null \
            || /usr/libexec/PlistBuddy -c 'Add :UIFileSharingEnabled bool true' "$PLIST" 2>/dev/null || true
        /usr/libexec/PlistBuddy -c 'Set :LSSupportsOpeningDocumentsInPlace true' "$PLIST" 2>/dev/null \
            || /usr/libexec/PlistBuddy -c 'Add :LSSupportsOpeningDocumentsInPlace bool true' "$PLIST" 2>/dev/null || true
        echo "[*] Enabled UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace (for diag logs)."
    fi
fi

# Drop the dylib into Frameworks/.
FW_DIR="$APP_DIR/Frameworks"
mkdir -p "$FW_DIR"
cp "$DYLIB" "$FW_DIR/miOS.dylib"
chmod 644 "$FW_DIR/miOS.dylib"

# Inject a load command. @executable_path is the folder of the app's main binary,
# so @executable_path/Frameworks/miOS.dylib resolves relative to Instagram's own
# install root at runtime, which is what the dyld sandbox allows.
DYLIB_RPATH="@executable_path/Frameworks/miOS.dylib"
echo "[*] Injecting LC_LOAD_DYLIB → $DYLIB_RPATH"

if [[ "$INJECT_TOOL" == "insert_dylib" ]]; then
    # Non-weak load so if signing strips the dylib the app fails loudly instead of
    # silently running without our hooks. Default behaviour of insert_dylib strips
    # the stale Mach-O code signature — we want that so the re-signer sees a clean
    # binary with no leftovers pointing at the pre-patch bytes.
    insert_dylib --inplace --all-yes \
        "$DYLIB_RPATH" "$EXE_PATH" >/dev/null
else
    # install_name_tool doesn't add new LC_LOAD_DYLIB commands outright, so we use
    # a two-step: add a placeholder via otool/awk is non-trivial, prefer insert_dylib.
    echo "install_name_tool cannot add new load commands; install insert_dylib." >&2
    exit 1
fi

# Bundle ElleKit as CydiaSubstrate.framework (so MSHookFunction actually works on sideload).
# The "Cydia Substrate" that Sideloadly/AltStore inject is often a legacy shim that implements
# MSHookMessageEx (ObjC hooks) but NOT MSHookFunction (inline C hooks) — which leaves the device
# spoof's MGCopyAnswer inline hook a no-op, so IG's telemetry still sends the real model. ElleKit
# (https://github.com/evelyneee/ellekit) implements MSHookFunction on arm64/arm64e.
#
# Point MIOS_ELLEKIT at a built ElleKit CydiaSubstrate.framework (a directory) to bundle it here.
# miOS.dylib must reference it via @rpath/CydiaSubstrate.framework/CydiaSubstrate (theos-jailed
# builds do; we also add an @executable_path/Frameworks rpath to the main binary below).
if [[ -n "${MIOS_ELLEKIT:-}" ]]; then
    if [[ -d "$MIOS_ELLEKIT" ]]; then
        echo "[*] Bundling ElleKit substrate from $MIOS_ELLEKIT"
        rm -rf "$FW_DIR/CydiaSubstrate.framework"
        cp -R "$MIOS_ELLEKIT" "$FW_DIR/CydiaSubstrate.framework"
        # Ensure @rpath resolves to the app's Frameworks/ dir.
        if command -v install_name_tool >/dev/null 2>&1; then
            if ! otool -l "$EXE_PATH" 2>/dev/null | grep -q "@executable_path/Frameworks"; then
                install_name_tool -add_rpath "@executable_path/Frameworks" "$EXE_PATH" 2>/dev/null \
                    && echo "[*] Added LC_RPATH @executable_path/Frameworks" || true
            fi
        fi
        if command -v ldid >/dev/null 2>&1; then
            ldid -S "$FW_DIR/CydiaSubstrate.framework/CydiaSubstrate" 2>/dev/null || true
        fi
        echo "[*] Verify after install:  strings .../CydiaSubstrate | grep -i ellekit   (should match)"
    else
        echo "[!] MIOS_ELLEKIT='$MIOS_ELLEKIT' is not a directory (expected CydiaSubstrate.framework) — skipping." >&2
    fi
else
    echo "[*] MIOS_ELLEKIT not set — relying on the signer's bundled substrate."
    echo "    If the device-spoof self-test shows 'MSHookFunction NO-OP', that substrate lacks"
    echo "    function hooking; re-run with MIOS_ELLEKIT=/path/to/ElleKit/CydiaSubstrate.framework."
fi

# Bundle Substitute (comex) so MGCopyAnswer can be inline-hooked WITHOUT ElleKit. miOS dlopens
# @loader_path/libsubstitute.0.dylib at runtime and calls substitute_hook_functions, which patches
# MGCopyAnswer's bytes in-process (works on sideload where the legacy substrate's MSHookFunction is
# a no-op). Point MIOS_SUBSTITUTE at the libsubstitute dylib (the .0.dylib or a fat libsubstitute.dylib).
# Default to the vendored copy next to this script if MIOS_SUBSTITUTE is unset.
if [[ -z "${MIOS_SUBSTITUTE:-}" ]]; then
    _vendored="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)/vendor/libsubstitute.0.dylib"
    [[ -f "$_vendored" ]] && MIOS_SUBSTITUTE="$_vendored" && echo "[*] Using vendored Substitute: $_vendored"
fi
if [[ -n "${MIOS_SUBSTITUTE:-}" ]]; then
    if [[ -f "$MIOS_SUBSTITUTE" ]]; then
        echo "[*] Bundling Substitute from $MIOS_SUBSTITUTE → Frameworks/libsubstitute.0.dylib"
        cp "$MIOS_SUBSTITUTE" "$FW_DIR/libsubstitute.0.dylib"
        chmod 644 "$FW_DIR/libsubstitute.0.dylib"
        if command -v ldid >/dev/null 2>&1; then
            ldid -S "$FW_DIR/libsubstitute.0.dylib" 2>/dev/null || true
        fi
        echo "[*] After install, device-spoof self-test should show 'dlsym-hook WORKS' and"
        echo "    '[miOS-iso] Substitute MGCopyAnswer inline-hook -> 0 (0=OK)'."
    else
        echo "[!] MIOS_SUBSTITUTE='$MIOS_SUBSTITUTE' is not a file — skipping." >&2
    fi
fi

# Strip app extensions / plug-ins (widgets, share/notification extensions, Watch app).
# On a free Apple ID these can't be signed properly (they need their own App IDs and
# app groups, which free accounts don't grant), so iOS kills them with a CODESIGNING
# "Invalid Page" fault — e.g. the lock-screen camera widget crashing on launch. miOS
# lives in the main binary, so removing them is safe. Set MIOS_KEEP_PLUGINS=1 to keep.
if [[ "${MIOS_KEEP_PLUGINS:-0}" != "1" ]]; then
    for d in PlugIns Plugins Watch com.apple.WatchPlaceholder Extensions; do
        if [[ -e "$APP_DIR/$d" ]]; then
            echo "[*] Removing app extensions: $d/"
            rm -rf "${APP_DIR:?}/$d"
        fi
    done
else
    echo "[*] MIOS_KEEP_PLUGINS=1 — leaving app extensions in place (must be signable)."
fi

# Wipe the old code signature — the signer (AltStore/Sideloadly/TrollStore) will
# generate a fresh one for the modified binaries and the new Frameworks/ entry.
echo "[*] Stripping old _CodeSignature …"
rm -rf "$APP_DIR/_CodeSignature"
# The embedded provisioning profile is signer-specific; strip it too so AltStore
# et al. don't try to reuse an expired one.
rm -f  "$APP_DIR/embedded.mobileprovision"

# If ldid is available, self-sign the dylib + the main binary so the IPA is
# TrollStore-installable without an Apple Developer account.
if command -v ldid >/dev/null 2>&1; then
    echo "[*] Self-signing with ldid (for TrollStore / jailbreak installs)…"
    ldid -S "$FW_DIR/miOS.dylib"
    # Preserve the app's existing entitlements if we can read them.
    if ldid -e "$EXE_PATH" >"$WORK/orig.entitlements" 2>/dev/null; then
        ldid -S"$WORK/orig.entitlements" "$EXE_PATH"
    else
        ldid -S "$EXE_PATH"
    fi
else
    echo "[*] ldid not found — skipping self-signing."
    echo "    For TrollStore install, run:  ldid -S $FW_DIR/miOS.dylib && ldid -S $EXE_PATH"
    echo "    For AltStore / Sideloadly, no signing step is needed here."
fi

# Sanity-check: confirm the LC_LOAD_DYLIB landed. We don't need otool for this — grep
# the raw binary for the path we injected.
if grep -q "$DYLIB_RPATH" "$EXE_PATH"; then
    echo "[*] Verified LC_LOAD_DYLIB → $DYLIB_RPATH is present in the executable."
else
    echo "[!] WARNING: $DYLIB_RPATH not found in $EXE_PATH after injection." >&2
    echo "    The signer may strip it; otool -L on the installed binary should still show it." >&2
fi

# Repack. Keep the top-level 'Payload/' prefix (iOS requires it).
echo "[*] Repacking → $IPA_OUT"
(cd "$WORK" && zip -q -r -X "$OLDPWD/$IPA_OUT" Payload)

echo "[✓] Done: $IPA_OUT"
echo
echo "If the floating miOS button does NOT appear after install, verify in order:"
echo "  1. On the device, look for Documents/mios-loaded.txt inside Instagram's data"
echo "     container (TrollStore → Open from Files). If missing, the dylib never loaded"
echo "     (signer stripped it, or ldid signature invalid — try reinstalling without AltStore)."
echo "  2. Run: otool -L $EXE_PATH | grep miOS   # confirms LC_LOAD_DYLIB is still there."
echo "  3. Check the installed app's bundle id — the dylib's ctor accepts any id containing"
echo "     'burbn' or 'instagram'. If AltStore renamed it to something exotic, let us know."
echo
echo "Install options:"
echo "  • TrollStore         — airdrop/open the IPA, no further signing."
echo "  • AltStore / Sideloadly — point them at this IPA; they handle signing."
echo "  • A Mac + Xcode      — resign with your dev cert and 'Devices and Simulators'."
