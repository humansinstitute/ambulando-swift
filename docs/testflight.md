# iPhone TestFlight distribution

Use the `Ambulando` scheme and Release configuration for the normal iPhone/iPad
app, bundle ID `studio.otherstuff.ambulando.native`. The `AmbulandoTest`, Mac
and Grandparent Chat schemes are separate products.

## Prepare and validate

Read `AGENTS.md`, preserve concurrent changes, and check the current version and
build in `Ambulando.xcodeproj/project.pbxproj`. Before selecting an upload build
number, inspect the exact app's existing builds and pending uploads in App Store
Connect. Never infer that a failed command means an upload did not arrive.

Keep signing configuration, credentials, archives and operational evidence under
verified ignored storage. Do not commit private account references or device
records. Use existing authorized Apple access; never accept legal agreements or
purchase membership as part of an automated release.

Run core tests and archive with the verified team supplied locally:

```sh
swift test --package-path AmbulandoCore
xcodebuild -project Ambulando.xcodeproj -scheme Ambulando \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$RELEASE_DIR/Ambulando.xcarchive" \
  -derivedDataPath "$RELEASE_DIR/DerivedData" \
  DEVELOPMENT_TEAM="$APPLE_TEAM" -allowProvisioningUpdates \
  -skipPackagePluginValidation -skipMacroValidation archive
```

The package-validation flags allow the repository's pinned secp256k1 build
plugin in unattended builds; review dependency changes before trusting plugins.
Verify the archived app's version, build, bundle ID and code signature. Export
using a private ExportOptions plist with `method=app-store-connect`,
`destination=export`, `signingStyle=automatic`, the verified team ID and
`manageAppVersionAndBuildNumber=false`. Supply existing authorized Xcode account
or API-key references locally. Check the exported distribution signature and
production APNs entitlement; an archive may initially use development signing.

```sh
xcodebuild -exportArchive -archivePath "$RELEASE_DIR/Ambulando.xcarchive" \
  -exportOptionsPlist "$RELEASE_DIR/ExportOptions.plist" \
  -exportPath "$RELEASE_DIR/export" -allowProvisioningUpdates
```

## Apple setup and external sharing

An explicit bundle ID registration is separate from an App Store Connect app
record. [Create the app record on Apple's website](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/)
before uploading. Apple's [Apps API](https://developer.apple.com/documentation/appstoreconnectapi/apps)
manages existing apps and does not create new app records. Use iOS, the exact
native bundle ID, an appropriate primary language and a unique SKU. If website
sign-in, two-factor authentication or an agreement requires the account holder,
report that exact step; preserve the prepared archive.

Upload through Xcode or Transporter using existing authorized access. Retain the
receipt privately and confirm the exact version/build in App Store Connect.
Wait for processing and resolve export-compliance questions with confirmed facts.
The app uses secp256k1 signing and encrypted identity storage, so do not assume
that its encryption consists only of operating-system HTTPS or invent exemption
answers.

For external testing, create or select a dedicated external group, add the exact
build, provide beta description, feedback contact, review contact, test notes and
any required working review access. Do not invent contact details or credentials
or grant reviewers access to a private workspace without authorization. Submit
TestFlight beta review where required, then enable the public invitation link
with the intended tester limit. Follow Apple's
[external tester instructions](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers).

Read back processing, beta review, group membership, public-link settings and
the invitation page before saying the app can be shared. A generated link alone
does not establish that a build is available. Record source commit/push, signed
archive, exported IPA, upload receipt, processing, review and availability as
separate states. Commit tested reusable changes and verify GitHub `main` contains
the delivered commit; source delivery does not establish a device installation.
