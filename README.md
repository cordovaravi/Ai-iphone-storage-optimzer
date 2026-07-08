# OffloadPro

*See what's eating your iPhone, and move it to storage YOU own — one tap, no monthly rent.*

Native iOS app (Swift 5.10, SwiftUI, iOS 16+) implementing the OffloadPro PRD v1.0
and Technical Specification v1.0: an on-device media space scanner plus a
transfer → verify → delete offload engine targeting Google Drive and external
drives (pendrive/SSD), with a one-time-purchase Pro unlock via RevenueCat.

## Getting started (on a Mac)

The Xcode project is generated from `project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen)
so the repo stays merge-friendly:

```bash
brew install xcodegen
xcodegen generate
open OffloadPro.xcodeproj
```

Then:

1. Set your development team in Signing & Capabilities.
2. Replace the placeholders in `OffloadPro/App/OffloadProApp.swift` → `Secrets`
   (RevenueCat public API key, Google OAuth client ID, optional Sentry DSN).
   For CI, inject via an `.xcconfig` instead of editing source.
3. Build & run on a device (PhotoKit + external-drive flows need real hardware).

## Architecture

MVVM + a service layer of actors, strict Swift concurrency. Persistence is
SQLite via GRDB (`Core/Database/AppDatabase.swift`, migration `v1` — asset
index, transfer queue/history, pendrive manifest, offload meter, coach progress).

```
OffloadPro/
  App/            Composition root, BGTask registration, Secrets
  Core/           Models (GRDB records, state machine), Database, Logging
  Services/
    Scanner/      AssetProviding abstraction + PhotoKit provider, sizes,
                  classification, dHash, blur, incremental index
    Offload/      Export (stream+dual-hash), VerificationGate, Coordinator,
                  free-tier meter
    Destinations/ Google Drive (PKCE OAuth, resumable upload, md5 verify),
                  Local/external drive (bookmarks, FAT32 guard), Keychain
    Purchases/    RevenueCat wrapper — `pro` entitlement is the only gate
    Coach/        coach.json content model + remote override + progress
    Pendrive/     Drive marker UUID, incremental manifest diff
    Smart/        SmartPlanner (pure scoring/greedy), Before-Trip reminders
  Features/       One folder per screen (SwiftUI)
  Resources/      coach.json
OffloadProTests/  Unit tests (pure logic + in-memory GRDB)
OffloadProUITests/ Launch smoke + "no subscription wording" copy audit
```

### The golden rule (do not weaken)

An asset is **never** deleted until its checksum is verified at the destination.
`VerificationGate.markVerified` is the only code path that flips an item to
`verified`, and `OffloadCoordinator.deleteVerifiedBatch` is the only code path
that deletes assets — always through the system-confirmed PhotoKit batch dialog.
Degraded iCloud exports (`bytes < expected × 0.98`) are permanently barred from
deletion (PRD risk R1).

## Build order status (per tech spec §9)

| Step | Scope | Status |
|---|---|---|
| §0 | Scaffolding: project.yml, GRDB migration v1, logging | ✅ code complete |
| §1 | Scanner: permission, sizes, categories, dupes, junk, UI | ✅ code complete |
| §6 | RevenueCat shell + paywall | ✅ code complete (needs RC dashboard setup + StoreKit config file) |
| §2 | Offload: export+hash → Google Drive → local drive → deletion review | ✅ code complete (kill-resume persistence of Drive session URIs is in-memory per run; queue rows persist state) |
| §5 | Coach | ✅ code complete (step screenshots to be captured per iOS version) |
| §4 | Pendrive incremental | ✅ code complete |
| §3 | Smart Modes | ✅ code complete |
| §7/§8 | Hardening + full gate matrix | ⬜ requires devices, staging accounts, physical drives |

“Code complete” = written to spec with unit tests; on-device integration,
performance (20k-asset scan ≤ 90 s), and the 50 GB soak test (§2.3) must run on
real hardware before release. See `PRIVACY.md` for the privacy-label mapping.

## Testing

Unit tests cover the spec's §1.3/§2.3/§3.2/§5.2 unit items: migration
idempotency, size summation policy, classification fixtures (WhatsApp scorer,
screenshots), dHash distances, transfer state machine legality (full matrix +
random walks), `markVerified` refusals (mismatch/degraded/missing ref),
meter boundary math (exactly 5 GB + 1 byte), planner determinism/overshoot/
exclusions, coach decoding/version pinning/iOS filtering, pendrive incremental
diff. Run with ⌘U after `xcodegen generate`.

## App Review guardrails baked in

- No per-app storage claims anywhere; device totals only (`DeviceStorage`).
- Deletion only via system-confirmed PhotoKit batch request.
- No `App-prefs:` deep links; only `openSettingsURLString` for our own app.
- OAuth via `ASWebAuthenticationSession` (no embedded webviews).
- "One-time purchase"/"lifetime" copy — never "subscription" (UI test enforces).
- Restore Purchases button + price shown before purchase.
