#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CANDIDATES=()
if [ "${CODEX_JAVA_HOME-}" ]; then
    CANDIDATES+=("${CODEX_JAVA_HOME}")
fi
if [ "${JAVA_HOME-}" ]; then
    CANDIDATES+=("${JAVA_HOME}")
fi
CANDIDATES+=("/root/.local/share/mise/installs/java/21.0.2")
if command -v java >/dev/null 2>&1; then
    JAVA_BIN="$(command -v java)"
    JAVA_BIN="$(readlink -f "${JAVA_BIN}")"
    JAVA_CANDIDATE="$(dirname "${JAVA_BIN}")"
    JAVA_CANDIDATE="$(dirname "${JAVA_CANDIDATE}")"
    CANDIDATES+=("${JAVA_CANDIDATE}")
fi
SELECTED=""
for candidate in "${CANDIDATES[@]}"; do
    if [ -d "${candidate}" ] && [ -x "${candidate}/bin/java" ]; then
        SELECTED="${candidate}"
        break
    fi
done
if [ -z "${SELECTED}" ]; then
    echo "Unable to locate a valid JDK. Set CODEX_JAVA_HOME to a Java 21 installation." >&2
    exit 1
fi
export CODEX_JAVA_HOME="${SELECTED}"
export JAVA_HOME="${SELECTED}"
GRADLE_OPTS_APPEND="-Dorg.gradle.java.home=${SELECTED}"
if [ "${GRADLE_OPTS-}" ]; then
    export GRADLE_OPTS="${GRADLE_OPTS} ${GRADLE_OPTS_APPEND}"
else
    export GRADLE_OPTS="${GRADLE_OPTS_APPEND}"
fi
exec "${PROJECT_ROOT}/assemble-offline.sh" "$@"
