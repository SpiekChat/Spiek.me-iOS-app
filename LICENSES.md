# Bundled third-party assets

## Fonts

The app bundles the following typefaces (in `Spiek/Resources/Fonts/`) under
the SIL Open Font License 1.1, which permits redistribution inside an
application. The full license texts, as shipped by the font authors, are in
[`third_party/`](third_party/):

- **IBM Plex Sans** and **IBM Plex Mono** — © 2017 IBM Corp.
  https://github.com/IBM/plex — [license](third_party/IBM-Plex-OFL.txt)
- **Space Grotesk** — © 2020 The Space Grotesk Project Authors.
  https://github.com/floriankarsten/space-grotesk —
  [license](third_party/Space-Grotesk-OFL.txt)

The OFL requires that the fonts are not sold on their own and that any modified
version is renamed. Neither applies here — they are shipped unmodified as part
of the app.

## Code

Everything under `SpiekCore/` and `Spiek/` was written for this project and has
no third-party dependencies. The cryptographic routines are implementations of
public standards: FIPS 180-4 (SHA-2), ISO/IEC 10118-3 (RIPEMD-160),
FIPS 197 / SP 800-38D (AES-GCM), SEC 2 (secp256k1), RFC 6979 (deterministic
ECDSA) and BIP-143 (transaction digests).
