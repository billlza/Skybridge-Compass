#!/usr/bin/env python3
"""Bind the imported, usable signing identity to the preflight certificate."""
import argparse
from pathlib import Path
import re


def select_identity(text: str, fingerprint: str) -> str:
    if not re.fullmatch(r"[0-9A-F]{40}", fingerprint):
        raise ValueError("expected an exact uppercase certificate fingerprint")
    identities = re.findall(r'^\s*\d+\) ([0-9A-F]{40}) "([^"\r\n]+)"\s*$', text, re.MULTILINE)
    selected = [(digest, name) for digest, name in identities if digest == fingerprint]
    if len(selected) != 1 or not selected[0][1].startswith("Developer ID Application:"):
        raise ValueError("the profile-bound Developer ID certificate is not one usable imported identity")
    name = selected[0][1]
    if any(digest != fingerprint and other_name == name for digest, other_name in identities):
        raise ValueError("the selected signing authority name is ambiguous in the release keychain")
    if any(ord(character) < 32 or ord(character) == 127 for character in name):
        raise ValueError("the signing authority contains a control character")
    return name


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--identities", type=Path, required=True)
    parser.add_argument("--fingerprint", required=True)
    arguments = parser.parse_args()
    try:
        print(select_identity(arguments.identities.read_text(), arguments.fingerprint))
    except ValueError as error:
        parser.exit(1, str(error) + "\n")
