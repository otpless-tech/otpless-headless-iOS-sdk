#!/usr/bin/env python3
"""
Regenerate PinConstants.swift from AWS KMS + Secrets Manager.

Usage:
    python3 scripts/src/create-pin-constants.py [--dry-run]

AWS credentials come from the standard boto3 chain (env vars,
~/.aws/credentials, SSO cache, instance profile). IAM permissions needed:
  - kms:GetPublicKey on both signer aliases
  - secretsmanager:GetSecretValue on both baseline-pin secrets

PinConstants.swift is a fully generated file — the entire contents are
rewritten on every successful run. Do NOT hand-edit it; edit this script
instead. Any non-generated pinning config lives in other files
(OtplessSslPinManager.swift owns manifestURL / timeouts / cache keys).
"""
from __future__ import annotations

import argparse
import base64
import re
import sys
from difflib import unified_diff
from pathlib import Path

import boto3

AWS_REGION = "ap-south-1"
PINNED_HOST = "sigma.otpless.app"

KMS_ALIASES = [
    "alias/sdk-pin-signer-primary-4096",
    "alias/sdk-pin-signer-backup-4096",
]

PIN_SECRET_NAMES = [
    "otpless-app/wildcard/4096-baseline-pin-current",
    "otpless-app/wildcard/4096-baseline-pin-backup",
]

# Hardcoded 16-byte salt — must byte-match the Kotlin task's SALT so blobs
# produced on either platform decode with the other's vault reader.
SALT = bytes.fromhex("9F3AC18D7E42B5601FE7248BD936A471")

REPO_ROOT = Path(__file__).resolve().parents[2]
TARGET_FILE = REPO_ROOT / "Sources" / "OtplessBM" / "network" / "pinning" / "PinConstants.swift"


def fetch_anchors(kms) -> list[str]:
    """Fetches the ECDSA P-256 signer public keys from AWS KMS as base64-encoded DER
    `SubjectPublicKeyInfo` strings.

    Iterates `KMS_ALIASES` in the same order Android uses so anchor ordering stays
    platform-stable. Any KMS error, missing alias, or empty payload aborts the whole
    run — the caller never sees a partial list, which would silently ship an SDK that
    trusts fewer envelope signers than intended."""
    anchors: list[str] = []
    for alias in KMS_ALIASES:
        try:
            resp = kms.get_public_key(KeyId=alias)
        except Exception as ex:
            raise SystemExit(
                f"Failed to fetch KMS public key for alias '{alias}' in {AWS_REGION}: {ex}"
            ) from ex
        pub_bytes = resp.get("PublicKey") or b""
        if not pub_bytes:
            raise SystemExit(f"KMS returned an empty public key for alias '{alias}'")
        b64 = base64.b64encode(pub_bytes).decode("ascii")
        print(f"\n--- {alias} ---")
        print(f"  keyId              : {resp.get('KeyId', '')}")
        print(f"  keySpec            : {resp.get('KeySpec', '')}")
        print(f"  keyUsage           : {resp.get('KeyUsage', '')}")
        print(f"  signingAlgorithms  : {', '.join(resp.get('SigningAlgorithms', []))}")
        print(f"  publicKey base64   : ({len(b64)} chars)")
        print(f"    {b64}")
        anchors.append(b64)
    if len(anchors) != len(KMS_ALIASES):
        raise SystemExit(f"Expected {len(KMS_ALIASES)} anchors, got {len(anchors)}")
    return anchors


def fetch_pin_hashes(sm) -> list[str]:
    """Fetches the baseline SPKI pin hashes from AWS Secrets Manager as trimmed strings.

    Each secret's `SecretString` is expected to be a raw SHA-256 hash WITHOUT the
    `sha256/` prefix — `build_blobs` prepends the prefix when it composes the final
    line, matching Android's `pinsPrefixed` step. Iterates `PIN_SECRET_NAMES` in order
    and fails loudly on any missing secret, IAM error, or empty payload."""
    pins: list[str] = []
    for name in PIN_SECRET_NAMES:
        try:
            resp = sm.get_secret_value(SecretId=name)
        except Exception as ex:
            raise SystemExit(
                f"Failed to fetch Secrets Manager secret '{name}' in {AWS_REGION}: {ex}"
            ) from ex
        value = (resp.get("SecretString") or "").strip()
        if not value:
            raise SystemExit(f"Secrets Manager returned an empty secretString for '{name}'")
        print(f"\n--- {name} ---")
        print(f"  arn                : {resp.get('ARN', '')}")
        print(f"  versionId          : {resp.get('VersionId', '')}")
        print(f"  createdDate        : {resp.get('CreatedDate', '')}")
        print(f"  secretString (raw) :")
        print(f"    {value}")
        pins.append(value)
    if len(pins) != len(PIN_SECRET_NAMES):
        raise SystemExit(f"Expected {len(PIN_SECRET_NAMES)} pin secrets, got {len(pins)}")
    return pins


def xor(plain: bytes) -> bytes:
    """Symmetric XOR-obfuscation cycling `SALT` by `i mod 16`.

    Same function both obfuscates plaintext before hex-encoding for emission AND
    de-obfuscates hex during the round-trip verify — XOR is its own inverse, so a
    single implementation covers both directions. `SALT` must byte-match the Kotlin
    task's constant or blobs stop being platform-swappable."""
    return bytes(b ^ SALT[i % len(SALT)] for i, b in enumerate(plain))


def build_blobs(anchors_b64: list[str], pin_hashes: list[str]) -> tuple[bytes, bytes]:
    """Composes the exact plaintext byte layout the iOS `OtplessKeyVault` reader (and
    its Kotlin twin) expects, ready for XOR-obfuscation.

    - `verify_anchors` — newline-separated base64 SPKI strings WITH a trailing newline
      (the reader splits on `\\n` and drops empty lines; the trailing newline lets it
      terminate cleanly).
    - `baseline_pins`  — a single `PINNED_HOST\\tsha256/{h1}\\tsha256/{h2}\\n` line;
      the reader splits on tabs and takes column 0 as the host.

    The layout is decoder-exact: a missing tab, a stray space, or a dropped trailing
    newline silently breaks decoding downstream. The round-trip verify in `main` is
    what catches such regressions before they ship."""
    
    verify_anchors_plain = ("\n".join(anchors_b64) + "\n").encode("utf-8")
    pin_line = PINNED_HOST + "".join(f"\tsha256/{h}" for h in pin_hashes) + "\n"
    baseline_pins_plain = pin_line.encode("utf-8")
    return verify_anchors_plain, baseline_pins_plain


def emit_swift(salt_hex: str, verify_anchors_hex: str, baseline_pins_hex: str) -> str:
    """Renders the complete text of `PinConstants.swift` from the three generated hex blobs.

    Every byte of the emitted file comes from this template, so hand-edits to
    `PinConstants.swift` are transient — the next successful run overwrites them. Hex
    arguments are inserted verbatim into Swift string literals; supply uppercase hex
    with no `0x` prefix and no whitespace so the vault reader can decode them byte-exact."""
    return f"""\
//
//  PinConstants.swift
//  OtplessBM
//
//  GENERATED FILE — DO NOT EDIT BY HAND.
//  Regenerate with: python3 scripts/src/create-pin-constants.py
//

import Foundation

/// Obfuscated trust roots for the SSL pin envelope flow. At startup `OtplessKeyVault`
/// decodes each ciphertext below by XORing its bytes against `saltHex` cycling
/// `i mod 16`, then hands the plaintext to `OtplessSslPinManager`:
/// `verifyAnchorsHex` authenticates every remotely fetched pin envelope, and
/// `baselinePinsHex` is the always-on pin set that envelopes may refine but never remove.
///
/// Decoded layouts:
///   - `verifyAnchorsHex` → newline-separated base64 DER `SubjectPublicKeyInfo` strings,
///     one ECDSA P-256 anchor per line. Two anchors ship so signers can rotate without
///     a new SDK release.
///   - `baselinePinsHex`  → a single `host\\tsha256/pin\\tsha256/pin\\n` line — the host
///     is pinned on system trust plus these SPKI hashes even before any envelope loads.
///
/// XOR against a fixed salt is obfuscation, not encryption; it only defeats naive
/// `strings`-style scraping of the binary. Real integrity comes from Apple code-signing
/// (authenticity of the anchors in the shipped binary) plus ECDSA verification of every
/// envelope against those anchors before its pins are trusted.
///
/// This file is produced by a full-file emitter that mirrors Android's `emitKotlin` in
/// `OtplessSslKeyVaultTask.kt` — both SDKs read the same AWS material through the same
/// XOR-obfuscation, so blobs are byte-for-byte swappable between platforms.
internal enum PinConstants {{

    static let saltHex = "{salt_hex}"

    static let verifyAnchorsHex = "{verify_anchors_hex}"

    static let baselinePinsHex = "{baseline_pins_hex}"
}}
"""


def extract_hex(text: str, name: str) -> str:
    """Pulls one uppercase-hex value back out of an already-emitted `PinConstants.swift`
    by matching `static let <name> = "<hex>"`.

    Used exclusively by the round-trip verify step in `main` to prove the file on disk
    decodes to the same plaintext we started from — this is how the script catches its
    own emitter bugs (bad escaping, wrong constant names, corrupted hex) before the
    Xcode build finds them. Rejects odd-length hex up front so `bytes.fromhex` never
    sees garbage."""
    m = re.search(rf'static let {name}\s*=\s*"([0-9A-Fa-f]+)"', text)
    if not m:
        raise SystemExit(f"round-trip: {name} not found in emitted file")
    hex_str = m.group(1)
    if len(hex_str) % 2 != 0:
        raise SystemExit(f"round-trip: {name} has odd hex length {len(hex_str)}")
    return hex_str


def main() -> int:
    """Orchestrates the full refresh: parse args → fetch AWS material → build and XOR
    the plaintext blobs → emit `PinConstants.swift` → round-trip verify.

    Uses the default boto3 credential chain (env vars, `~/.aws/credentials`, SSO cache,
    instance profile) against `AWS_REGION`. In `--dry-run` mode, nothing is written —
    a unified diff of what would change is printed to stdout so you can eyeball the
    result before committing to it. On a real run, if the round-trip verify fails for
    any reason (mismatched decode, missing constant, odd-length hex) the original file
    is restored (or the freshly-created one is deleted) so the working tree never lands
    in a corrupt half-patched state — a small hardening over Android, which leaves the
    broken file behind and expects the developer to reset by hand."""
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Fetch and emit, but print a diff instead of writing PinConstants.swift.",
    )
    args = parser.parse_args()

    print(f"Using boto3 default credential chain (region={AWS_REGION}, pinnedHost={PINNED_HOST})")

    session = boto3.Session(region_name=AWS_REGION)

    print(f"\n=== Fetching KMS public keys (region={AWS_REGION}) ===")
    anchors_b64 = fetch_anchors(session.client("kms"))

    print(f"\n=== Fetching Secrets Manager secrets (region={AWS_REGION}) ===")
    pin_hashes = fetch_pin_hashes(session.client("secretsmanager"))

    verify_plain, pins_plain = build_blobs(anchors_b64, pin_hashes)
    verify_cipher = xor(verify_plain)
    pins_cipher = xor(pins_plain)

    emitted = emit_swift(
        salt_hex=SALT.hex().upper(),
        verify_anchors_hex=verify_cipher.hex().upper(),
        baseline_pins_hex=pins_cipher.hex().upper(),
    )

    if args.dry_run:
        original_text = TARGET_FILE.read_text() if TARGET_FILE.is_file() else ""
        diff = unified_diff(
            original_text.splitlines(keepends=True),
            emitted.splitlines(keepends=True),
            fromfile=str(TARGET_FILE),
            tofile=str(TARGET_FILE) + " (dry-run)",
        )
        sys.stdout.write("".join(diff))
        print("\nDry-run: no files written.")
        return 0

    # Snapshot for rollback so a round-trip failure never leaves a corrupt file on disk
    # (this is a small improvement over Android, which leaves the broken file behind).
    original_bytes = TARGET_FILE.read_bytes() if TARGET_FILE.is_file() else None
    TARGET_FILE.parent.mkdir(parents=True, exist_ok=True)
    TARGET_FILE.write_text(emitted)

    try:
        reread = TARGET_FILE.read_text()
        decoded_salt = bytes.fromhex(extract_hex(reread, "saltHex"))
        decoded_anchors = xor(bytes.fromhex(extract_hex(reread, "verifyAnchorsHex")))
        decoded_pins = xor(bytes.fromhex(extract_hex(reread, "baselinePinsHex")))
        if decoded_salt != SALT:
            raise SystemExit("round-trip: saltHex on disk does not match SALT constant")
        if decoded_anchors != verify_plain:
            raise SystemExit("round-trip: verify_anchors mismatch after re-reading emitted file")
        if decoded_pins != pins_plain:
            raise SystemExit("round-trip: baseline_pins mismatch after re-reading emitted file")
    except SystemExit:
        if original_bytes is not None:
            TARGET_FILE.write_bytes(original_bytes)
        else:
            TARGET_FILE.unlink(missing_ok=True)
        raise

    print(f"\nWrote {TARGET_FILE}")
    print(f"  verify_anchors : {len(verify_plain)} B plaintext -> {len(verify_cipher)} B ciphertext")
    print(f"  baseline_pins  : {len(pins_plain)} B plaintext -> {len(pins_cipher)} B ciphertext")
    print("Round-trip verify: OK")
    print("=== Refresh complete ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
