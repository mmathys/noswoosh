# Releasing noswoosh

Tagging `vX.Y.Z` runs [`.github/workflows/release.yml`](.github/workflows/release.yml),
which builds the binary, assembles `noswoosh.app`, and attaches both to a GitHub
Release. CI runs on `macos-latest`, which has a full Xcode; locally, the Command Line
Tools are enough (`codesign`, `notarytool` and `stapler` all ship with them). Signing and notarization are skipped automatically when the secrets below
are absent, so the workflow is safe to run before any of this is set up.

## Why signing matters

macOS ties the Accessibility (TCC) grant to the binary's code signature. An ad-hoc
signature — what `swiftc` produces — changes on every rebuild, so the permission is
revoked on every upgrade. A stable Developer ID signature keeps the grant across
upgrades, which is the whole point of shipping a signed build.

## One-time setup

### 1. Developer ID Application certificate

Xcode is **not** required — `codesign`, `notarytool` and `stapler` all ship with the
Command Line Tools. Create the certificate from the CLI plus the developer portal:

```sh
# 1. private key + certificate signing request
openssl req -new -newkey rsa:2048 -nodes \
    -keyout devid.key -out devid.csr \
    -subj "/emailAddress=you@example.com/CN=Your Name/C=CH"
```

2. Go to [developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates/list)
   → "+" → **Developer ID Application** → upload `devid.csr` → download
   `developerID_application.cer`.

   > Individual accounts are limited to a small number of Developer ID certificates
   > and they cannot be freely revoked and reissued. Keep `devid.key` and the
   > resulting `.p12` backed up somewhere safe.

```sh
# 3. bundle key + certificate (plus Apple's intermediate) into a .p12
curl -sO https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer
openssl x509 -inform DER -in developerID_application.cer -out devid.pem
openssl x509 -inform DER -in DeveloperIDG2CA.cer -out intermediate.pem
# NOTE: the legacy PBE flags are required — macOS `security` cannot read
# OpenSSL 3's default PKCS#12 encryption and fails with "MAC verification failed".
openssl pkcs12 -export -out devid.p12 \
    -inkey devid.key -in devid.pem -certfile intermediate.pem \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

# 4. import into the login keychain so local signing works
security import devid.p12 -k ~/Library/Keychains/login.keychain-db \
    -T /usr/bin/codesign

# 5. confirm, and note the identity string
security find-identity -v -p codesigning
# -> "Developer ID Application: Your Name (TEAMID)"

# 6. encode for the CI secret
base64 -i devid.p12 | pbcopy
```

Store `devid.key`, `devid.p12` and the `.p12` password in a password manager. The
private key cannot be regenerated — losing it means burning another Developer ID slot.

### 2. App Store Connect API key (for notarization)

App Store Connect → Users and Access → Integrations → App Store Connect API →
"+", role **Developer**. Download the `.p8` (one-time download), and note the Key ID
and Issuer ID.

```sh
base64 -i AuthKey_XXXXXXXX.p8 | pbcopy
```

### 3. Repository secrets

Add all seven under Settings → Secrets and variables → Actions in `mmathys/noswoosh`:

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_CERT_P12_BASE64` | base64 of the `.p12` |
| `DEVELOPER_ID_CERT_PASSWORD` | password set during the `.p12` export |
| `CI_KEYCHAIN_PASSWORD` | any random string; unlocks the ephemeral CI keychain |
| `DEVELOPER_ID_SIGN_IDENTITY` | `Developer ID Application: Your Name (TEAMID)` |
| `ASC_API_KEY_ID` | App Store Connect key ID |
| `ASC_API_ISSUER_ID` | App Store Connect issuer ID |
| `ASC_API_KEY_P8_BASE64` | base64 of the `.p8` |

Signing turns on as soon as `DEVELOPER_ID_CERT_P12_BASE64` is present; notarization
and stapling need the three `ASC_*` secrets as well.

## Cutting a release

1. Bump `noswooshVersion` in `noswoosh.swift` (the workflow fails if it disagrees
   with the tag).
2. `git tag vX.Y.Z && git push origin vX.Y.Z`
3. Wait for the workflow. The Release gets `noswoosh-X.Y.Z-macos.zip` (raw signed
   binary, for scripting or manual installs) and `noswoosh-X.Y.Z.app.zip` (signed,
   notarized, stapled bundle, used by the Cask).
4. Update the Cask in [`mmathys/homebrew-tap`](https://github.com/mmathys/homebrew-tap):
   set `version` and `sha256` (the workflow prints both checksums in its
   "Package artifacts" step), then commit and push.

## Verifying a signed release

```sh
codesign -dv --verbose=4 noswoosh.app          # expect TeamIdentifier, not "adhoc"
spctl -a -vvv -t install noswoosh.app          # expect "accepted / Notarized Developer ID"
xcrun stapler validate noswoosh.app
```

The real end-to-end test: install, grant Accessibility once, then `brew upgrade --cask
noswoosh` and confirm Ctrl+←/→ still works **without** re-granting.

## Building a bundle locally

```sh
./scripts/make-app-bundle.sh --out build                       # unsigned
./scripts/make-app-bundle.sh --out build --sign "Developer ID Application: ..."
NOSWOOSH_SIGN_IDENTITY="Developer ID Application: ..." ./install.sh
```
