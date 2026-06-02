#!/usr/bin/env python3
"""tools/sign_update.py — sign a .dmg with an Ed25519 private key for Sparkle.

Sparkle 2.x verifies update signatures with the public key in
Info.plist's SUPublicEDKey. The signature is over the entire .dmg
file contents. The output is a 64-byte signature, base64-encoded.

Usage:
    python3 tools/sign_update.py --dmg path/to/file.dmg --private-key keys/odysseus_update_private.pem

Outputs the base64 signature to stdout. Exits 0 on success.

Verification (sanity check):
    python3 tools/sign_update.py --dmg file.dmg --private-key priv.pem --public-key keys/odysseus_update_public.txt
    # will print 'signature valid' if the sig verifies with the public key.
"""

import argparse
import base64
import sys
from pathlib import Path

try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import (
        Ed25519PrivateKey,
        Ed25519PublicKey,
    )
    from cryptography.hazmat.primitives import serialization
except ImportError:
    print("ERROR: the `cryptography` library is required.", file=sys.stderr)
    print("Install it with: pip install cryptography", file=sys.stderr)
    sys.exit(1)


def sign_dmg(dmg_path: Path, private_key_path: Path) -> str:
    """Sign a .dmg and return the base64 signature."""
    priv_pem = private_key_path.read_bytes()
    priv = serialization.load_pem_private_key(priv_pem, password=None)
    if not isinstance(priv, Ed25519PrivateKey):
        raise ValueError(f"Private key is not Ed25519: got {type(priv).__name__}")
    data = dmg_path.read_bytes()
    sig = priv.sign(data)
    return base64.b64encode(sig).decode("ascii")


def verify_signature(dmg_path: Path, signature_b64: str, public_key_path: Path) -> bool:
    """Verify a base64 signature against a .dmg using the given public key file (base64-encoded 32 bytes)."""
    pub_b64 = public_key_path.read_text().strip()
    pub_bytes = base64.b64decode(pub_b64)
    if len(pub_bytes) != 32:
        raise ValueError(f"Public key must be 32 bytes, got {len(pub_bytes)}")
    pub = Ed25519PublicKey.from_public_bytes(pub_bytes)
    sig = base64.b64decode(signature_b64)
    try:
        pub.verify(sig, dmg_path.read_bytes())
        return True
    except Exception:
        return False


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dmg", required=True, help="path to the .dmg to sign")
    parser.add_argument("--private-key", required=True, help="path to PEM-encoded Ed25519 private key")
    parser.add_argument("--public-key", help="(optional) verify the sig with this public key file")
    args = parser.parse_args()

    dmg_path = Path(args.dmg)
    priv_path = Path(args.private_key)

    if not dmg_path.is_file():
        print(f"ERROR: {dmg_path} does not exist", file=sys.stderr)
        sys.exit(1)
    if not priv_path.is_file():
        print(f"ERROR: {priv_path} does not exist", file=sys.stderr)
        sys.exit(1)

    sig_b64 = sign_dmg(dmg_path, priv_path)
    print(sig_b64)

    if args.public_key:
        pub_path = Path(args.public_key)
        if verify_signature(dmg_path, sig_b64, pub_path):
            print("signature valid", file=sys.stderr)
        else:
            print("ERROR: signature did NOT verify", file=sys.stderr)
            sys.exit(1)


if __name__ == "__main__":
    main()
