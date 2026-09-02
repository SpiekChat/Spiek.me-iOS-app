# Changelog — Spiek for iOS

All notable changes to the iOS app. Marketing version and build number track
the release number since v16 (v17 = 1.17.0, build 17); earlier builds shipped
as 1.0 (build 1) regardless of the delivery number.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Full build notes, design decisions and the on-device test matrix live in
[BUILD.md](BUILD.md).

---

## [1.21.1] — 2026-09-02 (build 23) — build fix

### Fixed

- **CI (`swift test`) was red on 1.21.0.** Fourteen assertions in
  `TrustSafetyTests.swift` placed `await` inside an `XCTAssert*` autoclosure,
  which Swift rejects. Every async result is now bound to a `let` first and
  asserted afterwards; the assertions themselves are unchanged. No behaviour
  change.

---

## [1.21.0] — 2026-09-01 (build 22) — store-readiness round 2

### Added

- **Trust & Safety (P0.2).** Report a person, message, image or group in nine
  categories (child safety/CSAE included) to the moderation service: a
  structured bundle, message text only with explicit consent, never a group
  key or your own keys. Reports have a real status (received → in review →
  closed, or appealed) that the app polls with a capability token; "received"
  is shown only after the service answered. E-mail remains a visible fallback
  and says so ("no receipt"). Versioned Terms & Community Standards must be
  accepted before the first post. The operator's **signed moderation feed**
  is enforced by default with three levels — `soft_hide` (shown on request),
  `policy_block` (never shown), `legal_block` (never shown, never fetched) —
  verified like an SNS answer under a pinned key; a failed, expired or older
  feed is ignored and never releases an existing block. Blocked or listed
  senders are not rendered, not counted as unread, not notified about, and
  their media is not downloaded.
- **Just-in-time disclosures (P0.3).** One specific warning before the first
  public-group post and before the first image: permanent, public, on the
  blockchain.
- **Wallet-bound storage (P0.5).** The store records a domain-separated
  fingerprint of the wallet's public key. A store of another wallet is
  quarantined under an opaque random name — journaled, resumed after a crash,
  never rendered, only deletable from *You → Orphaned data*. A store from an
  older build is adopted only when its contents prove the wallet. The cached
  plaintext of own encrypted sends is now sealed under a wallet-derived key.
- **Transaction cost (P0.1).** Costs are shown as *network fee + service fee =
  total*; onboarding explains the transaction model. "No server" wording
  replaced by "no central message database; replaceable endpoints".
- **Storage protection (P0.6).** The whole Spiek folder — database, WAL/SHM,
  any cache or export beside them — is excluded from backups and sealed with
  `completeUntilFirstUserAuthentication` (background polling after a reboot
  must keep working, which `complete` would break). Applied at open and again
  on every foreground; a failure is a hard error, never ignored.
- **Forget this device (P0.8)** is a guarded flow: re-authentication, a
  confirmation that the recovery phrase is written down, and — with funds —
  the balance, the address and a typed FORGET. It never signs or broadcasts.
- **Secret surfaces (P0.9).** `RevealBox` has a sensitive mode without text
  selection (keyed invites, recovery phrase, WIF) and `.privacySensitive()`.
- Tests: `StorageProtectionTests` (3) and `TrustSafetyTests` (4: feed
  canonical bytes + signature + refusals + levels, store ownership rules,
  opaque journaled quarantine) — 176 XCTests.
- CI (P0.7a): an `xcodebuild archive` job on Xcode 26 / the iOS 26 SDK
  (unsigned build proof; `swift test` alone does not prove the upload
  requirement), recording bundle id, version and dSYMs; actions pinned.

### Changed

- Documentation: macOS Sequoia 15.6 / Xcode 26 requirements.

---

## [1.20.1] — 2026-09-01 (build 21) — keyed invites handled as secrets

### Security

- **A keyed group invite is the group key, and is now treated as one.**
  Copying it (created sheet, chat header, chat list) uses the sensitive
  pasteboard path — local only, so it never rides Universal Clipboard, and
  it expires after a minute — and the chat list no longer prints a keyed
  group's code as its preview line. Sharing through the share sheet is
  unchanged: that is the deliberate act the key is for.

### Fixed

- The optimistic pending bubble now shows the lock a message will get
  (encrypted DM, note, keyed group) instead of appearing unencrypted for a
  second.
- Documentation: the App Store section still said 1.17.0/build 17 and "Data
  Not Collected"; BUILD.md still said groups are not encrypted; the
  requirements said Xcode 16 (uploads need Xcode 26 since 28 April 2026);
  the README claimed `spiek:` codes open the app directly (no URL scheme is
  registered, on purpose). All corrected; "serverless" clarified and the
  encryption claim scoped.

---

## [1.20.0] — 2026-08-23 (build 20) — encrypted groups, BSV21 balances, fuzzing

Builds 18 and 19 were internal steps toward this release and never shipped;
build 20 carries the whole round, keeping the version in step with the web
build (v20) and Android (1.21.0).

### Added

- **Encrypted groups.** A group created on 1.20 receives a random 32-byte key
  and the key travels in the invite: `spiek:group:<channel-id>:<64-hex-key>`.
  Every group record except `open` — messages, media, reactions, edits,
  withdrawals — is sealed with AES-256-GCM under that key inside the existing
  `emsg` envelope; the on-chain format did not change. Joining with a keyed
  code stores the key, and loading the fuller code for a group you already
  follow adopts it, opening earlier records. A keyless code still joins a
  public group, exactly as before. This is group privacy, not end-to-end
  secrecy: the invite *is* the key.
- **Group golden vectors.** `SpiekCore/Tests/…/Resources/group_vectors.json` —
  8 positive and 4 negative vectors produced by an implementation independent
  of all three clients (Node/OpenSSL), shared verbatim with the web and
  Android suites, checked by `GroupVectorTests` (decrypt + inner-record
  compare + own-seal round trip; negatives must fail).
- **Fuzz suite.** `FuzzTests` — thousands of deterministic mutations (bit
  flips, truncation, lying pushdata length prefixes, random byte soup,
  corrupted Base58 addresses, malformed invite codes, mutated group
  ciphertexts) against the real decoders. A decoder either rejects or returns
  a fully valid result; it never crashes and never accepts a ref-carrying
  record without its ref.
- **BSV21 token balances.** New endpoint row *You → BSV21 token index* (the
  shared Spiek indexer base, `…/bsv21/v1`; empty = no token section). The
  wallet shows a Tokens section fetched from
  `{base}/address/{address}/balance`: amounts stay strings and are scaled in
  integer math (nothing rounded), a non-`valid` status is shown, and an
  unreachable index reads *token index unreachable — balances hidden, nothing
  is lost*. Display-only; coin selection has always skipped 1-sat outputs, so
  token UTXOs are never spent as ordinary coins.
- **Optimistic send echo.** The bubble appears the moment send is tapped
  (status *pending*) and is replaced by the real record on the next reload —
  a poll holding the engine can no longer delay your own message's
  appearance. A failed send clears the synthetic row.

### Fixed

- **The keyboard closes again.** `composerFocused` was set on focus but never
  cleared, so the on-screen keyboard stayed up forever. Send now drops focus,
  and a tap between the bubbles dismisses the keyboard too (scroll already
  did, interactively).

### Changed

- **Honest wording.** The chat-header remove control arms as *Remove?* and
  its accessibility label says what it does — removes the chat from this
  device, the chain keeps its history. The group subheader reads *encrypted
  group · everyone with the invite can read* or *public group · permanently
  stored on-chain*, and the new-chat and group-created sheets explain that a
  keyed invite carries the group key.

### Security

- Group encryption reuses the audited path end to end: the same canonical
  inner envelope, the same `emsg` outer record, the same `AESGCM`
  implementation — only the key source differs (invite key instead of ECDH).
  A record we hold no key for renders as unreadable, exactly like a foreign
  DM. The group key is stored locally in the channel row and never touches
  the chain.

---

## [1.17.0] — 2026-08-14 (build 17) — pre-release review

Every finding from the full-codebase review fixed, wallet correctness first.

### Security

- **Address version byte enforced.** `Address.hash160(from:)` now requires
  the mainnet P2PKH version byte. A BTC P2SH "3…", a Litecoin "L…" or a
  testnet address — all valid Base58Check with 20-byte payloads — used to be
  accepted and paid as mainnet P2PKH, burning the coins.
- **The device lock now guards the key, not just the screen.** Enabling it
  moves the keychain account item behind `SecAccessControl`
  (`WhenUnlockedThisDeviceOnly` + `.userPresence`); disabling migrates back.
  Crash-safe migration via a scratch copy; the lock screen's `LAContext` is
  passed into the keychain read so unlocking costs one prompt.
- **Sign-out empties the store.** A different phrase imported on the same
  phone no longer inherits the previous account's chats or cached plaintext;
  the per-account cursor, UTXO snapshot and prev-pointer meta keys are
  namespaced by wallet hash.
- **Secrets on the clipboard are local-only and expire after a minute.**
- **Privacy shield** over the scene the moment it goes inactive, so the
  app-switcher snapshot never shows a conversation.
- Endpoints saved in own-node mode must be https (ATS would refuse them
  later anyway).

### Fixed

- **Fee-aware coin selection.** Inputs are selected until they cover the
  amount *plus the real fee of the transaction they produce*; the fee model
  counts the real varint length of large output scripts. The old fixed-guess
  selection failed a wallet full of small coins and reported the selected
  subtotal as "your balance".
- **Amount cap.** Nothing may move more than the coin supply; a twenty-digit
  amount used to overflow UInt64 arithmetic and crash.
- **Malformed UTXO entries are skipped**, not fatal — a negative output index
  from an endpoint used to trap and crash every sync.
- **Unread is honest**: history pulled in by the chain walkers no longer
  counts as unread, and neither does a message arriving in the open chat.
- Edits and withdrawals whose target sits outside the loaded page are
  persisted onto the stored message instead of dropped.
- The operator's service-fee output no longer inflates displayed Sent
  amounts; the onboarding quiz asks three words as documented.

### Added

- **Block & report** (App Review guideline 1.2): any sender can be blocked
  (long-press → Block sender, or from the chat details sheet; managed under
  *You → Blocked*); "Report a problem" opens a prefilled mail to
  hello@spiek.me carrying the channel id and recent txids, never message
  text.
- **Bare payments show in Activity.** Wallet → Send records the payment in a
  reserved local-only channel.

### Changed

- **Honest notification docs.** No background refresh task exists and none
  is claimed: notifications fire only while the app runs, last of all at
  the moment of backgrounding.
- Version 1.17.0 (build 17).

### Tests

- The deterministic-signature vectors are signed over the double SHA-256
  (Bitcoin's digest — the single hash never reproduced them).
- The built-transaction verification test matches vector UTXOs to inputs by
  outpoint instead of by array position.

### Still open

- The keychain access-control change cannot be exercised in XCTest or fully
  in the simulator; the seven-step on-device matrix in BUILD.md §12 is a
  release requirement.
- Native UI/Keychain flows have no XCTests yet; the 159 tests cover
  `SpiekCore` only.

## [1.16.0] — 2026-08-08 (build 16) — service fees

### Added

- **Service fees.** One extra P2PKH output per user-initiated transaction,
  to the operator address hardcoded in `ServiceFee.swift`: 3 sats per text
  message, 10 sats per image, 10 sats per payment (in-chat or to a bare
  address). Protocol overhead — opens, reactions, edits, withdrawals,
  profile publishes — is not charged. Both send sheets and the image
  composer state the fee before anything is broadcast, and the payment
  sheet counts it into its affordability check.

### Fixed

- **429s are retried, then reported readably.** The REST adapter backs off
  and retries twice (1.2 s, then 2.5 s) on a 429 before giving up; an HTTP
  error surfaces as one readable line instead of a raw nginx page.
- **Cancelled requests no longer show as errors.** Leaving the app while a
  refresh was in flight used to put the bare word "cancelled" in an error
  bar over the chat list.

### Changed

- Version set to 1.16.0, build 16 (was 1.0, build 1).

## [v15]

### Fixed

- **Every scrolling sheet has a close button.** Sheets are dismissed by
  dragging them down, which broke wherever something else claimed that
  drag; `SheetHeader` gained an `onClose`.
- **Wallet → Names reloads with a button, not pull-to-refresh.**
  `.refreshable` claimed the same downward drag that dismisses the sheet,
  so the screen had become a trap.

## [v14]

### Security

- **The peer key is pinned.** An incoming `open` is only believed when the
  key it announces is the key that signed the record, and only when the
  chat does not already have a peer — without both, one transaction was
  enough for a stranger to take over a conversation. A refusal is shown in
  the chat rather than swallowed, and `getTx` answers are bound to the txid
  that was requested.

### Fixed

- **One reaction per person per emoji.** Every reaction is its own
  transaction and nothing on chain marks one as a repeat, so they used to
  stack.

## [v13]

### Added

- **Your own profile.** Name, one-line bio and a picture under **You**; the
  name and bio publish to the chain on request, the picture never leaves
  the phone.
- **BSV price in dollars**, fetched from WhatsOnChain and refreshed every
  minute (`PriceFeed.swift`); screens show plain sats when no rate newer
  than 30 minutes is in hand.
- **OpNS names throughout.** The wallet's **Send** sheet takes a name too,
  and **Wallet → Names** / **You → Keys** list the names this address holds.

### Fixed

- **Unsettled-message pin.** The bar appears from the moment the broadcast
  is accepted; the old two-minute `Date()` comparison was invisible to
  SwiftUI and often never fired.
- **Lenient OpNS index decoding.** Only fields a payment cannot proceed
  without may fail a decode; one cosmetic string field had been failing
  every OpNS lookup.

## [v12] — baseline

The native port: encryption by default, BIP-39 recovery, 1Sat Ordinal
images, replies, encrypted notes, safety numbers, device lock,
notifications, QR codes, onboarding quiz, wipe, mirror broadcasts and SNS
name verification (see [BUILD.md](BUILD.md) §6 for the full account).
