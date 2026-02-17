#!/usr/bin/env bash
set -euo pipefail

IFACE="${IFACE:-lo}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iface) IFACE="$2"; shift 2 ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

sudo tc qdisc del dev "$IFACE" root >/dev/null 2>&1 || true
echo "Cleared netem qdisc on iface=$IFACE"
