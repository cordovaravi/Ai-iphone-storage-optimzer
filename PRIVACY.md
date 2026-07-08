# OffloadPro Privacy Notes (§7 mapping)

## Principle

Zero first-party servers touch user media. All library analysis is on-device.
Media leaves the device only to destinations the user explicitly connects
(their Google Drive, their pendrive). We operate no backend.

## App Privacy nutrition label mapping

| Data type | Collected? | Linked to identity? | Notes |
|---|---|---|---|
| Photos/Videos | Not collected by us | — | Read on-device; uploaded only to user-chosen destinations under the user's own accounts |
| Purchases | Yes (RevenueCat) | Not linked (RC anonymous app user ID) | Required for the lifetime unlock entitlement |
| Diagnostics | Yes (Sentry crash reports) | Not linked | `beforeSend` strips file paths, asset identifiers, URLs; only error domain/code + transfer state-machine state |
| Identifiers / Location / Contacts / Usage analytics | Not collected | — | No analytics SDK in v1 |

## Engineering rules that back the label

- OAuth tokens: Keychain only, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (`KeychainStore.swift`). Never in UserDefaults or logs.
- Logging: no filenames or asset identifiers at `.info` or above; asset detail only via `Logger.debugPrivate` (`.debug` + `.private`) — `Log.swift`.
- ATS fully enforced; `NSAllowsArbitraryLoads=false`.
- Network hosts contacted: RevenueCat, Sentry, and the user-chosen destination APIs (e.g. `googleapis.com`) — verified by the MITM-proxy release test (§7).
- Google Drive scope is `drive.file` (app-created files only).

## Release-gate checks

- MITM proxy run: only RC, Sentry, destination hosts observed.
- Log audit script: grep device logs during a full offload session for media filenames → zero hits.
- Copy audit: no user-facing "subscription" wording (it's a one-time purchase).
