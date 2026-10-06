# SandFlix custom update pipeline

This project packages official stable NuvioTV releases with Camron's SandFlix branding and the existing SandFlix signing key. The app keeps Nuvio's updater, but redirects it to this project's GitHub releases. The TV can only install an APK signed with the same SandFlix certificate.

## What happens on an update

1. The workflow checks daily for a new official stable release. It can also be run manually for a specific stable tag. Existing releases, including drafts awaiting testing, are skipped.
2. Verify the official APK's published SHA256 before editing it.
3. Apply the versioned branding assets and redirect the updater to this repository.
4. Preserve all packaged native player libraries byte for byte.
5. Sign with the existing SandFlix key and validate package, version, alignment, branding, and certificate.
6. Create a **draft** release. Test on the TV, including one 4K HDR stream, playback seek, remote shortcuts, and settings access.
7. Publish the tested release. It then becomes available through the in-app updater, with Android's normal installation confirmation.

Drafts never appear as TV updates. A failed or unrecognized customization stops the build. These checks protect the packaging process; they cannot guarantee that a new upstream version has no runtime bugs.

## Hosting

The release repository must be public for the TV to read its release API and download APKs without embedding a GitHub credential. Only stable official releases are supported. The TV's Beta channel still reads this repository and cannot fetch official unbranded builds.

## Secrets

Configure `SANDFLIX_KEYSTORE_BASE64`, `SANDFLIX_STORE_PASSWORD`, and `SANDFLIX_KEY_PASSWORD` as GitHub Actions secrets. The key alias is `sandflix-nuvio`. The expected certificate SHA256 is `e8ddfa16260fa5651b7b56b954c5eb7024f87ac9cf6368993600f433c12a3b79`.

Keep an independent private backup of the signing key and password. Losing the key means future builds cannot update the installed app in place. Never add keys or passwords to this repository.

## Local build

Requires PowerShell 7, Java 17, and Android SDK build-tools 35.0.0. Ripgrep is used when available; a built-in search works otherwise. Set the signing-password environment variables, then run:

```powershell
./tests/Test-Patches.ps1
./Build-SandFlix.ps1 -Version 1.0.0 -ReleaseRepository sandycoon/SandFlix -KeystorePath /private/path/sandflix-nuvio-signing.jks
```

The output is `artifacts/app-full-armeabi-v7a-release.apk`, plus `build-report.json`. This project currently targets the HS89 T19-2's 32-bit Android installation. Other CPU architectures require a separately reviewed build path.

Custom version codes use `1,000,000 + upstream versionCode`, keeping them increasing independently of the old manually branded APK. The first updater-enabled build needs one installation over the existing app; subsequent higher stable versions can use the app updater.

## Upstream and license

NuvioTV source and license: https://github.com/NuvioMedia/NuvioTV. Each build report records the exact upstream tag and checksum. Retain upstream attribution and GPL-3.0 terms. The packaging modifications are in `SandFlix.Patches.psm1` and `Build-SandFlix.ps1`; branding assets are in `branding/`. This is a compiled-release customization pipeline, not a replacement for Nuvio's full Kotlin source tree.

## Recovery

Save the previous tested APK before updating. Android may refuse a lower version code, and old versions may not understand newly migrated app data. Do not uninstall or clear app data as a rollback shortcut. Prepare a forward-version recovery build with the same key if a promoted version needs to be reverted.
