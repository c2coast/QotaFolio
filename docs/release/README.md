# Releasing QotaFolio

One script does the whole lane:

```bash
Tools/release/ship.sh health   # is this Mac ready?
Tools/release/ship.sh ship     # archive → … → draft
```

[`ship.sh`](../../Tools/release/ship.sh) names its steps in its own header, one sentence each, and says where the artifacts land. Who signs and where it publishes are facts about a Mac, not about the source, so they live in `~/.config/qotafolio/ship.env`; [`ship.env.example`](../../Tools/release/ship.env.example) is that file with each setting explained. The version is `project.yml`'s `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` — bump them there and nowhere else. This page is the why behind those steps.

**Nothing publishes itself.** The last step writes `go.sh` and stops; a person runs it.

## Cloud-managed signing

The team's Developer ID certificate stays at Apple. No private key sits on this Mac, which is the point — a lost laptop cannot sign anything as QotaFolio. Xcode asks Apple to sign at export time, authenticating as the Apple ID signed into it. An App Store Connect API key cannot cloud-sign a Developer ID identity, so the key in `ship.env` notarizes and nothing else. That is why the lane needs both credentials and uses each for one job.

## Why a zip and not a disk image

A disk image would be prettier, and it cannot be honest here. Gatekeeper checks the outermost container it is given, so an image has to carry a signature of its own — and `codesign` has no cloud path, so this lane cannot make one. A zip needs no signature: Gatekeeper looks through it to the app inside, which carries its own stapled ticket, and answers offline for the exact bytes that were downloaded. The lane proves that on every run by unsealing the archive it just made and re-assessing the app inside it.

If the drag-to-Applications window is ever wanted, the `dmg` and `staple` steps build one — but it needs a traditional Developer ID Application certificate, which only the team's Account Holder can create and which puts a private key on this Mac. That is a product decision, not a build step.

## What notarizing and stapling prove

Notarizing sends the signed app to Apple, which scans it and records that this exact binary passed. It is not review: nobody looks at the app, and an approval says only that Apple found no malware and that the signature is a valid Developer ID one. Stapling then writes Apple's ticket into the app bundle, so the Mac that opens it can check the ruling without asking the network. Without the staple, a first launch offline is refused. With it, the person who downloads the zip sees one dialog — *downloaded from the internet, Apple checked it for malicious software* — and clicks **Open**.

## The appcast

The appcast is the update feed Sparkle reads: an XML file listing each version, its download URL, its length and its signature. The app ships `SUPublicEDKey` in its `Info.plist`; the matching private EdDSA key lives in the login Keychain of the Mac that releases, and it never travels. Sparkle refuses any download whose signature that public key does not verify, so an update cannot be substituted even by whoever controls the download host. Publishing an update is therefore: bump the version, run the lane, and attach the new zip and `appcast.xml` to the release — the app's feed URL reads the latest release's appcast asset.
