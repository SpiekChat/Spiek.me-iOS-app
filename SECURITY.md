# Security Policy

## Reporting a vulnerability

Please report security issues privately first. Do not open a public issue for
anything that could move funds, expose a key or recovery phrase, or read a
message that was meant to be encrypted.

**Preferred channel:** [GitHub private vulnerability reporting](https://github.com/SpiekChat/Spiek.me-iOS-app/security/advisories/new)
— the "Report a vulnerability" button on the Security tab of this repository.
This opens a private advisory only the maintainers can see. If you cannot use
GitHub, email **hello@spiek.me** with the subject `SECURITY`.

Please include what the issue is, which file and line, how to reproduce it, and what an
attacker gains.

## What to expect

- **Acknowledgement:** within 3 working days.
- **Assessment:** within 10 working days, with a severity.
- **Fix:** anything that can move funds, expose a key or recovery phrase, or
  decrypt a direct message is prioritised over everything else.
- **Credit:** we will name you in the release notes unless you prefer otherwise.

We do not currently operate a bug bounty.

## Threat model

Spiek is a non-custodial, on-chain messenger and wallet: every message is a
Bitcoin SV transaction, the account is a key, and history is read back from
a public chain. The boundaries that carry the weight:

1. **The key never leaves the Keychain unasked.** The account item is stored
   `WhenUnlockedThisDeviceOnly` (no iCloud, no backup extraction) and, with
   the device lock on, behind `SecAccessControl` with user presence. Any path
   that reads the key without the device owner — or writes it to disk, the
   clipboard beyond its one-minute expiry, or a screenshot — is a
   vulnerability.
2. **Chain data is hostile input.** Everything the engine reads back from
   the endpoints (transactions, UTXO lists, index answers) is parsed as
   untrusted bytes: a peer key is pinned only when it signed the record that
   announces it, `getTx` answers are bound to the txid requested, malformed
   UTXO entries are skipped. A way to make the app pay the wrong script,
   accept a stranger's key as the peer, or crash on a crafted record is a
   vulnerability.
3. **A name is a payment only after it is proved.** SNS answers must carry a
   valid signature from the pinned resolver key and the holder outpoint is
   proved unspent before paying; OpNS answers are cross-checked against the
   locking script on chain. Any way to pay a name to an address the chain
   does not currently bind it to is a vulnerability.

Out of scope: the public BSV network itself and its miners, availability of
the public data sources (the `spiek.me` endpoints, WhatsOnChain, the SNS and
OpNS indexes), social-engineering scenarios, and the other
Spiek clients (report those against their own repositories, see the README).

## Known limitations (documented, deliberate)

- All cryptography is implemented in-repo with no external crypto
  dependencies and is locked to golden vectors shared across the three
  clients. Vectors prove compatibility, **not** the absence of side
  channels: parts of the AES and secp256k1 code are not constant-time. An
  independent audit is planned before Spiek is marketed as a "secure
  messenger"; until then treat it as a low-balance messaging wallet.
- Direct messages are encrypted once the peer's key is known. **Groups
  created on the current generation are encrypted** under a 32-byte key that
  travels in the invite (`spiek:group:<id>:<64-hex-key>`) — group privacy,
  not end-to-end secrecy: everyone who ever holds the invite reads
  everything, there is no member revocation, and the key is static for the
  life of the group. Keyless invites and pre-existing groups remain **public
  groups**, stored on-chain in the clear; the app says which kind you are in.
- There is no forward secrecy: one long-term key protects a conversation's
  whole history, and one group key protects a group's whole history. Key
  rotation is under design as a protocol revision, together with the
  independent audit.
- The chain is permanent: edits and withdrawals change what clients display,
  never what is on-chain.

## Running the tests

```bash
cd SpiekCore && swift test
# -> Executed 159 tests, with 0 failures
```
