# Building miOS so the hooks actually work on a sideloaded IPA (theos-jailed)

## ⚠️ Use ElleKit as the bundled Substrate (required for device spoof in IG account settings)

On-device testing proved that the Substrate shim being bundled implements **`MSHookMessageEx`
(ObjC hooks work) but NOT `MSHookFunction` (inline C function hooks are a NO-OP)**. The self-test
line confirms it:

```
[miOS-iso] SELFTEST MGCopyAnswer(via dlsym) ProductType=iPhone17,1  (dlsym-hook NOT firing — still real)
```

Consequences with a shim that lacks `MSHookFunction`:
- `sysctl`/`uname`/keychain/FS still work (those go through **fishhook**, not Substrate), so the
  User-Agent, containers, etc. spoof fine;
- BUT IG reads the model for its **login/telemetry** via `MGCopyAnswer` resolved through `dlsym`,
  which only an **inline function hook** can intercept. fishhook can't rebind `dlsym` on arm64e,
  and `MSHookFunction` is dead — so the real model reaches the server and shows in
  **Settings → Account → device list**.

**Fix: bundle [ElleKit](https://github.com/evelyneee/ellekit) as the `CydiaSubstrate.framework`.**
ElleKit is the modern Substrate replacement and fully implements `MSHookFunction` on sideload
(arm64 + arm64e). With ElleKit, miOS's existing inline hook of `MGCopyAnswer`
(`miosInstallMGCopyAnswerHook`) takes effect and the `dlsym` self-test flips to
`(dlsym-hook WORKS — dlsym spoofed)` — no code change in miOS is needed.

### Getting ElleKit as the bundled substrate

Pick whichever matches your flow:

- **Sideloadly** — use the **latest** Sideloadly: its tweak-injection ("Cydia Substrate" /
  "inject .dylibs") bundles **ElleKit** as `CydiaSubstrate.framework`. Add `miOS.dylib` as the
  injected dylib and let Sideloadly add the substrate. Do **not** also bundle a second substrate.
  If an older Sideloadly injected a minimal shim (MSHookFunction NO-OP), updating Sideloadly is the
  whole fix.
- **theos-jailed** — replace the substrate submodule it bundles with ElleKit's
  `CydiaSubstrate.framework`: build ElleKit (`make` in the ellekit repo produces
  `CydiaSubstrate.framework`) and drop it into the injected app's `Frameworks/`, keeping the
  dylib's load command `@rpath/CydiaSubstrate.framework/CydiaSubstrate`. Then re-sign.
- **Manual inject (patch-ipa.sh)** — copy ElleKit's `CydiaSubstrate.framework` into
  `Payload/Instagram.app/Frameworks/` before re-signing, so `@rpath` resolves to it.

### Verify ElleKit took (one self-test line)

Launch IG in a spoof container, filter Console by `miOS-iso`, and look ~3 s after launch:

```
[miOS-iso] SELFTEST MGCopyAnswer(via dlsym) ProductType=<spoofed>  (dlsym-hook WORKS — dlsym spoofed)
[miOS-iso] MGCopyAnswer public inline-hook attempted @0x…
```

`WORKS — dlsym spoofed` → `MSHookFunction` is live → the telemetry/account-settings device is now
spoofed. If it still says `NOT firing — still real`, the bundled substrate is still not ElleKit.

---

## Why this is needed

miOS hooks two different ways:

- **ObjC methods** (`%hook`) via `MSHookMessageEx` — UIDevice, NSUserDefaults, NSFileManager…
- **C functions** via `MSHookFunction` — `sysctlbyname`, `MGCopyAnswer` (device model / iOS),
  `SecItem*` (keychain isolation), `NSHomeDirectory`/`NSSearchPathForDirectoriesInDomains`…

Both only take effect at runtime **if a working Substrate shim is loaded in the app**. On a plain
Theos build the shim is a jailbreak-only path (`/Library/MobileSubstrate/DynamicLibraries`) that
does not exist on a sideloaded (non‑jailbroken) device, so on sideload the **C hooks silently do
nothing**. That is precisely the symptoms we hit:

- device spoof shows the **real** phone (IG reads model/iOS via `sysctl`/`MGCopyAnswer`, both C),
- containers don't isolate / the session leaks (keychain `SecItem*` + FS C-hooks don't fire).

Blaze avoids this by **bundling `CydiaSubstrate.framework` into the app** and linking it via
`@rpath` (`otool -L` on BlazeUniversal.dylib shows `@rpath/CydiaSubstrate.framework/CydiaSubstrate`).
`theos-jailed` does exactly this for us: it packages the Substrate shim (+ fishhook) **inside** the
output app so `MSHookFunction`/`MSHookMessageEx` work without a jailbreak.

## One-time setup (on the Mac)

```bash
# 1. Theos must already be installed ($THEOS set).
# 2. Install theos-jailed (note: --recursive pulls its submodules, incl. the Substrate shim):
git clone --recursive https://github.com/kabiroberai/theos-jailed.git
cd theos-jailed
./install
# 3. ios-deploy (only needed if you want `make install` to push to a device; optional):
npm install -g ios-deploy
```

## Build the injected IPA

You need a **decrypted** Instagram IPA (the same one you sideload today).

```bash
cd /path/to/mios-instagram          # this project
# Point theos-jailed at the decrypted IPA and build a self-contained, injected IPA:
IPA=/path/to/Instagram-decrypted.ipa make package FINALPACKAGE=1
```

What you get in `packages/` is an IPA that already contains:

- `Payload/Instagram.app/Frameworks/miOS.dylib` (our tweak),
- `Payload/Instagram.app/Frameworks/CydiaSubstrate.framework` (the shim — this is the missing piece),
- the main binary patched to load both.

### Signing / installing it

The produced IPA still needs a signature. Two options:

- **Keep using Sideloadly** (recommended, matches your current flow): drop this IPA into
  Sideloadly and sign as usual. **Do NOT also enable Sideloadly's "inject tweak / Cydia
  Substrate"** for it — the Substrate framework is already bundled; a second one can conflict.
  Sideloadly only needs to re-sign.
- Or let theos-jailed sign with a free provisioning profile:
  `make package install PROFILE=<your.bundle.id or path/to.mobileprovision>`.

## Confirm it worked

Open Console.app (or `idevicesyslog`), filter `miOS-iso`, launch Instagram with a spoof container
active, and look for the self-test line ~3 s after launch:

```
[miOS-iso] SELFTEST sysctl hw.machine=<spoofed>  want=<spoofed>  (C-hook WORKS)
[miOS-iso] MGCopyAnswer_internal hooked @0x… model/iOS spoof active
```

- `C-hook WORKS` → MSHookFunction now fires → device spoof + keychain/FS isolation are live.
- `C-hook NOT firing` → the Substrate shim still isn't loading; check the two bullet points under
  "Signing / installing it" (don't double-inject Substrate), or fall back to the in-dylib fishhook
  conversion.

## Notes

- `ARCHS = arm64 arm64e` and `TARGET … 14.0` already cover iOS 15.7–16.7 devices.
- `miOS_USE_FISHHOOK = 1` in the Makefile enables theos-jailed's fishhook addon as an extra safety
  net for C-function interception.
- The old `patch-ipa.sh` flow still works for a quick dylib-only inject, but it does **not** bundle
  a Substrate shim, so prefer the theos-jailed build when you need the C hooks (device spoof,
  keychain) to actually run on sideload.
