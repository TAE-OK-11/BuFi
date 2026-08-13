# iOS 27 beta installation

GitHub Actions publishes an unsigned IPA because this repository has no Apple
distribution certificate or provisioning profile. An unsigned IPA is an input
for a signing service; it is not directly runnable on a physical iPhone.

Before installation, the IPA must be signed with a certificate and provisioning
profile that authorize the target device and the final bundle identifier. The
signing process must cover the application executable and all nested executable
content. The installed application should contain both `_CodeSignature` and an
`embedded.mobileprovision` file.

iOS 27 beta 4 can retain stale signing or enterprise-trust state for an existing
installation. For a pre-main launch failure:

1. Remove the existing BuFi application completely.
2. Re-sign the newest `ios27-beta4-unsigned` IPA with a valid profile.
3. Install the newly signed IPA and trust its developer identity if required.
4. If launch still fails, export the device crash report and console entries for
   `BuFi`, `amfid`, `installd`, and `runningboardd`.

Do not diagnose a `Code Signature Invalid`, provisioning-profile rejection, or
`dyld` failure as an application-state crash. Those failures occur before
SwiftUI or BuFi startup code executes.
