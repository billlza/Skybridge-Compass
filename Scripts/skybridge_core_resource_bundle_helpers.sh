#!/usr/bin/env bash

# Normalize one SwiftPM SkyBridgeCore resource bundle into the canonical macOS
# Contents/Resources layout. The Python transaction owns validation, snapshot,
# proof, exclusive publication, signal handling, cleanup, and status mapping.
#
# Success: 0, with exactly one layout token on stdout.
# Untrusted/unsupported source or failed proof: 1.
# Invalid arguments, unsafe destination, or destination conflict: 2.
skybridge_copy_normalized_core_resource_bundle() {
  if [[ "$#" -ne 2 ]]; then
    echo "skybridge-core-resource-bundle: reason=usage" >&2
    return 2
  fi

  local helper_dir
  local transaction_cli
  helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || {
    echo "skybridge-core-resource-bundle: reason=helper-path-resolution-failed" >&2
    return 1
  }
  transaction_cli="$helper_dir/skybridge_core_resource_bundle.py"
  if [[ ! -f "$transaction_cli" || -L "$transaction_cli" ]]; then
    echo "skybridge-core-resource-bundle: reason=transaction-cli-missing" >&2
    return 1
  fi

  /usr/bin/python3 "$transaction_cli" \
    --source-bundle "$1" \
    --destination-bundle "$2"
}
