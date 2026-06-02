#!/usr/bin/env python3
"""tools/generate_keys.py — generate a Sparkle-compatible Ed25519 keypair.

Usage:
    python3 tools/generate_keys.py <app-name>

Outputs:
    keys/<app-name>_update_private.pem  (NEVER commit; put in GitHub secret)
    keys/<app-name>_update_public.txt  (32-byte Ed25519 public key, base64)

Sparkle uses the binary public key (32 bytes) base64-encoded. The private key
is stored in PEM format so it can be passed to `cryptography` later.

For deterministic test runs, you can also set the environment variable
SEED to a 32-byte hex string; this lets you reproduce the same keypair
across machines (useful for CI testing).
"""

import argparse
import base64
import os
import sys
from pathlib import Path

# Try to import cryptography, fall back to nacl if not available
try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import (
        Ed25519PrivateKey,
        Ed25519PublicKey,
    )
    from cryptography.hazmat.primitives import serialization

    HAVE_CRYPTOGRAPHY = True
except ImportError:
    HAVE_CRYPTOGRAPHY = False
    try:
        import nacl.signing
        HAVE_NACL = True
    except ImportError:
        HAVE_NACL = False


def generate_with_cryptography():
    """Generate using the `cryptography` library."""
    if os.environ.get("SEED"):
        # Deterministic key from a 32-byte seed
        import hashlib
        seed = bytes.fromhex(os.environ["SEED"])
        priv = Ed25519PrivateKey.from_private_bytes(seed)
    else:
        priv = Ed25519PrivateKey.generate()
    pub = priv.public_key()
    return priv, pub


def generate_with_nacl():
    """Generate using the `nacl` library."""
    if os.environ.get("SEED"):
        import hashlib
        seed = bytes.fromhex(os.environ["SEED"])
        priv = nacl.signing.SigningKey(seed)
    else:
        priv = nacl.signing.SigningKey.generate()
    pub = priv.verify_key
    return priv, pub


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app_name", help="e.g. odysseus")
    parser.add_argument("--keys-dir", default="keys", help="output directory")
    args = parser.parse_args()

    keys_dir = Path(args.keys_dir)
    keys_dir.mkdir(parents=True, exist_ok=True)

    priv_path = keys_dir / f"{args.app_name}_update_private.pem"
    pub_path = keys_dir / f"{args.app_name}_update_public.txt"

    # Don't overwrite existing keys without --force
    if (priv_path.exists() or pub_path.exists()) and not os.environ.get("FORCE"):
        print(f"ERROR: {priv_path} or {pub_path} already exists.")
        print("Set FORCE=1 to overwrite, or delete the existing files first.")
        sys.exit(1)

    if HAVE_CRYPTOGRAPHY:
        print("Using `cryptography` library")
        priv, pub = generate_with_cryptography()
        # Save private key as PEM
        priv_pem = priv.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        )
        priv_path.write_bytes(priv_pem)
        # Save public key as base64 (32 bytes raw, then base64)
        pub_bytes = pub.public_bytes(
            encoding=serialization.Encoding.Raw,
            format=serialization.PublicFormat.Raw,
        )
        pub_b64 = base64.b64encode(pub_bytes).decode("ascii")
        pub_path.write_text(pub_b64 + "\n")
    elif HAVE_NACL:
        print("Using `nacl` library")
        priv, pub = generate_with_nacl()
        # nacl uses raw bytes for private key
        priv_raw = bytes(priv)
        priv_pem = (
            b"-----BEGIN PRIVATE KEY-----\n"
            + base64.encodebytes(priv_raw + b"\x00" * 32)  # pad to 64 bytes for PKCS8
            + b"-----END PRIVATE KEY-----\n"
        )
        # Note: this is a simplification. nacl and cryptography have different
        # key formats. For real signing, use tools/sign_update.py with the
        # nacl key in raw form, or use cryptography throughout.
        priv_path.write_bytes(priv_pem)
        pub_raw = bytes(pub)
        pub_b64 = base64.b64encode(pub_raw).decode("ascii")
        pub_path.write_text(pub_b64 + "\n")
    else:
        print("ERROR: neither `cryptography` nor `nacl` is installed.")
        print("Install one with: pip install cryptography")
        sys.exit(1)

    # Print the public key (safe to share)
    print(f"Public key: {pub_b64}")
    print(f"Written: {pub_path}")
    print(f"Written: {priv_path}  (DO NOT COMMIT; add to .gitignore + GitHub secret)")


if __name__ == "__main__":
    main()
