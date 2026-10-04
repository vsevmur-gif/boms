ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:14.0

# Build a rootless jailbreak .deb by default. For IPA injection you only need the built
# .dylib (see docs/INJECTION.md) — THEOS_PACKAGE_SCHEME is irrelevant there.
THEOS_PACKAGE_SCHEME ?= rootless

INSTALL_TARGET_PROCESSES = Instagram

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = miOS
miOS_FILES = \
    Tweak/Tweak.x \
    Tweak/fishhook.c \
    Tweak/MiOSContainer.m \
    Tweak/MiOSDeviceDB.m \
    Tweak/MiOSCrypt.m \
    Tweak/MiOSTheme.m \
    Tweak/MiOSDesign.m \
    Tweak/MiOSUI.m
miOS_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
miOS_FRAMEWORKS = Foundation CoreFoundation UIKit CoreLocation MapKit \
                  Security CoreTelephony SystemConfiguration CoreMotion \
                  QuartzCore MessageUI WebKit SafariServices AVFoundation
miOS_PRIVATE_FRAMEWORKS =

# --- Jailed (sideload / no-JB) build via theos-jailed -------------------------------------
# Our MSHookFunction (inline C) and MSHookMessageEx (ObjC) hooks only FIRE at runtime if a
# working Substrate shim is present in the resigned app. On a plain Theos build that shim is a
# jailbreak path (/Library/MobileSubstrate/...) that does not exist on a sideloaded device, so
# the C-level hooks (device spoof via sysctl/MGCopyAnswer, keychain, FS) silently do nothing —
# which is exactly the "IG shows my real phone / session leaks" symptom.
#
# Building through theos-jailed bundles CydiaSubstrate.framework (+ fishhook) INTO the app and
# links it via @rpath, exactly like Blaze (@rpath/CydiaSubstrate.framework/CydiaSubstrate), so
# the hooks actually run on a sideloaded IPA. See docs/JAILED-BUILD.md for the full steps.
# This flag is read by theos-jailed; a plain Theos build ignores it.
miOS_USE_FISHHOOK = 1

# Bake the sideloaded-IPA install path into LC_ID_DYLIB so it matches the LC_LOAD_DYLIB
# the patcher inserts into Instagram. Some signers (AltStore / Sideloadly) reject a
# dylib whose own install name does not match the loader path, which was silently
# leaving the dylib unloaded on resign.
miOS_LDFLAGS = -Wl,-install_name,@executable_path/Frameworks/miOS.dylib

include $(THEOS_MAKE_PATH)/tweak.mk
