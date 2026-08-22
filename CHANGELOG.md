# Changelog — Spiek for iOS

All notable changes to the iOS app. Marketing version and build number track
the release number since v16 (v17 = 1.17.0, build 17); earlier builds shipped
as 1.0 (build 1) regardless of the delivery number.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Full build notes, design decisions and the on-device test matrix live in
[BUILD.md](BUILD.md).

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
