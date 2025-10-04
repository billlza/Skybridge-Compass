#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_ROOT"

cat <<'MSG'
Gradle usage is disabled in this repository snapshot.
To build the Android project, sync the source tree into an online-capable
workstation and use Android Studio or a custom build pipeline that supplies
the required dependencies locally.
MSG

exit 1

