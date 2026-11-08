# Desktop releases

The public repository is `DiAndyW/InfoBank`. A `desktop-vX.Y.Z` tag builds NoteBank for Apple Silicon Macs and Windows x64, signs the updater packages, notarizes the Mac app and disk image, and publishes a GitHub release after all CI checks pass. Windows installers are not code signed, so SmartScreen may warn on first install.

## One-time setup

### 1. Keep the updater key safe

The updater key pair is already generated and its public key is in `desktop/src-tauri/tauri.conf.json`. Keep the private key and its password in your password manager with a recovery copy. Do not generate a replacement for routine releases. This key signs update packages on both platforms so installed apps can verify them.

### 2. Export the Mac signing certificate

1. Sign in to the Apple Developer account as the Account Holder. In Certificates, Identifiers & Profiles, create a **Developer ID Application** certificate. Follow Apple's certificate signing request instructions using Keychain Access on your Mac. This is for distributing outside the App Store.
2. Install the certificate in Keychain Access. Under My Certificates, confirm it expands to show its private key.
3. Export the certificate together with its private key as a `.p12` file. Choose a strong export password and save it in your password manager.
4. Copy its exact identity, such as `Developer ID Application: Your Name (TEAMID)`, for `APPLE_SIGNING_IDENTITY`.
5. Encode the `.p12` for the GitHub secret. On macOS, this copies it to the clipboard without printing it:

   ```sh
   base64 -i /path/to/DeveloperID.p12 | pbcopy
   ```

6. Paste into `APPLE_CERTIFICATE` in step 4 below. Clear the clipboard afterward. Keep the original and password in secure storage and remove temporary exports.

### 3. Create the notarization API key

1. In App Store Connect, open Users and Access, then Integrations and App Store Connect API. Request access if the account has not enabled it.
2. Create a team API key with the **Developer** role. This lets Apple's notarization service check the signed build.
3. Record the Issuer ID and Key ID. Download the `.p8` private key immediately; Apple lets you download it only once.
4. Save the key and IDs in your password manager. The whole `.p8` text, including its BEGIN and END lines, becomes `APPLE_API_PRIVATE_KEY`. The workflow writes it to a restricted temporary file and removes that file on exit.

### 4. Configure the GitHub Environment

In the repository, open Settings, Environments and create **`desktop-release`**. Under Deployment branches and tags, choose selected branches and tags. Add a branch rule for **`main`** and a separate tag rule for **`desktop-v*`**. The branch rule permits the dry run; the tag rule permits releases. Do not allow other refs. A second person's approval is not needed for this single-maintainer repository.

Add these as **Environment secrets**, not repository secrets:

| Exact secret name | Value |
| --- | --- |
| `TAURI_SIGNING_PRIVATE_KEY` | Complete existing Tauri updater private-key file contents |
| `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` | Password for that updater key |
| `APPLE_CERTIFICATE` | Base64 text of the Developer ID `.p12` |
| `APPLE_CERTIFICATE_PASSWORD` | `.p12` export password |
| `APPLE_SIGNING_IDENTITY` | Exact Developer ID Application identity from Keychain Access |
| `APPLE_API_ISSUER` | App Store Connect Issuer ID |
| `APPLE_API_KEY` | App Store Connect Key ID |
| `APPLE_API_PRIVATE_KEY` | Complete `.p8` file contents |

Only the build job uses this Environment. Windows receives only the two updater secrets. Review changes to release workflows carefully: code allowed to use signing keys can sign arbitrary software. Never print secrets, put them in URLs, or enable shell tracing while handling them.

### 5. Protect release tags

Under Settings, Rules, Rulesets, add a tag ruleset matching **`desktop-v*`**. Block updates and deletion, including routine administrator bypass. Restrict creation to the maintainer. Keep `main` protected with PRs and the required CI `checks` aggregate. Never reuse a release version or replace published assets.

## Dry run before the first release

1. Merge the workflow and version changes into `main`.
2. Open Actions, Desktop release, Run workflow. Select **main**. Other branches are rejected. This runs all CI checks, builds both platforms with the release signing configuration, and uploads artifacts. It does not create a GitHub release.
3. Download `desktop-macos-26` from the completed run and unzip it. Open the `.dmg`, copy NoteBank to `/Applications`, and launch it there. Confirm there is no Gatekeeper warning. The workflow checks both Apple's approval and stapled tickets for the app and DMG.
4. Exercise quick capture and the global hotkey. Confirm opening and returning to your previous app works. These manual checks are needed because the hardened runtime may affect native integration.
5. Download `desktop-windows-2025` on Windows and test its NSIS installer. Workflow artifacts in this public repository are downloadable by any signed-in GitHub user for the retention period. Do not treat them as private; they are not announced or offered to the updater.

## Cut a release

1. In a PR, set the same next unused `X.Y.Z` version in `desktop/src-tauri/tauri.conf.json`, the `[package]` entry of `desktop/src-tauri/Cargo.toml`, and `desktop/package.json`. Update the `notebank` entry in `Cargo.lock` and both root version entries in `package-lock.json` too. From `desktop/src-tauri`, `cargo update -p notebank --offline` updates the Rust package entry.
2. Run the version check from the repository root, using your chosen version:

   ```sh
   python3 deploy/desktop-release.py check-version desktop-v0.2.0
   ```

3. Merge the PR and wait for green CI. If the Server also changes, release the compatible Server first.
4. On your local `main`, verify you have the intended merged commit. You, the maintainer, create and push the tag. For the first release:

   ```sh
   git tag desktop-v0.2.0
   git push origin desktop-v0.2.0
   ```

5. Watch Actions, Desktop release. It validates all three versions and main ancestry, reruns CI, builds both platforms, uploads all assets to a draft, and only then publishes it as GitHub's latest release. A failed run does not publish an incomplete draft; investigate failures before taking further action. Do not replace assets on a published release.
6. Confirm the release contains the DMG, `NoteBank.app.tar.gz` and its `.sig`, the Windows `-setup.exe` and its `.sig`, and `latest.json`. In an older installed release, use Settings, Check for updates, then Restart to update. Confirm the new version and your saved content.

Installed apps read `https://github.com/DiAndyW/InfoBank/releases/latest/download/latest.json`. Its two platform entries point at assets under the specific `desktop-vX.Y.Z` release, so downloads cannot change when a newer release appears.

## Release rules

- Release the Server first when both Server and desktop change.
- Server releases must keep **`--latest=false`**. Desktop releases use `--latest=true`; changing the Server rule breaks the installed apps' update endpoint. See [Server updates](UPDATES.md).
- There are no automatic downgrades. Fix a bad desktop release by publishing a higher version.
- Ordinary local builds do not need signing secrets. The workflow alone passes `tauri.release.conf.json`, which enables signed updater artifacts.

## First install on each existing machine

The existing unsigned apps need one manual install to enter the signed update path.

On Windows, quit NoteBank and run the release's NSIS `-setup.exe` over the existing app. If prompted, choose Add/Reinstall components. Do not uninstall or delete application data. Existing data is kept. Windows may show SmartScreen because the installer is unsigned.

On Mac, quit NoteBank, open the release DMG and drag NoteBank to `/Applications`, replacing the old app. Launch it and answer the one Keychain prompt with **Always Allow**. This permits the new Developer ID identity to use the existing saved secret. Check that your notes are present. Future releases keep the same signing identity.

If the updater private key is lost, every installed app needs a manual reinstall containing the replacement public key. A new private key cannot sign updates accepted by the old public key. Keep the recovery copy safe.
