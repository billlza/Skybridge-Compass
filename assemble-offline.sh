#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${PROJECT_ROOT}/third_party/m2repository"
GRADLE_HOME_DIR="${PROJECT_ROOT}/.gradle-offline"

is_repo_populated() {
    if [ ! -d "${REPO_DIR}" ]; then
        return 1
    fi
    local first
    first="$(find "${REPO_DIR}" -mindepth 1 -not -name '.gitkeep' -print -quit 2>/dev/null || true)"
    [ -n "${first}" ]
}

extract_offline_archive() {
    local archive="$1"
    local temp_dir
    temp_dir="$(mktemp -d)"
    case "${archive}" in
        *.zip) unzip -q "${archive}" -d "${temp_dir}" ;;
        *.tar) tar -xf "${archive}" -C "${temp_dir}" ;;
        *.tar.gz|*.tgz) tar -xzf "${archive}" -C "${temp_dir}" ;;
        *.tar.bz2|*.tbz2) tar -xjf "${archive}" -C "${temp_dir}" ;;
        *) echo "Unsupported offline cache archive ${archive}." >&2; rm -rf "${temp_dir}"; return 1 ;;
    esac
    local extracted_root="${temp_dir}"
    if [ -d "${temp_dir}/m2repository" ]; then
        extracted_root="${temp_dir}/m2repository"
    fi
    mkdir -p "${REPO_DIR}"
    shopt -s dotglob
    mv "${extracted_root}"/* "${REPO_DIR}/"
    shopt -u dotglob
    rm -rf "${temp_dir}"
}

prepare_offline_repo() {
    if is_repo_populated; then
        return
    fi
    mkdir -p "${REPO_DIR}"
    local archives=(
        "${PROJECT_ROOT}/third_party/m2repository.zip"
        "${PROJECT_ROOT}/third_party/m2repository.tar"
        "${PROJECT_ROOT}/third_party/m2repository.tar.gz"
        "${PROJECT_ROOT}/third_party/m2repository.tgz"
        "${PROJECT_ROOT}/third_party/m2repository.tar.bz2"
        "${PROJECT_ROOT}/third_party/m2repository.tbz2"
    )
    for archive in "${archives[@]}"; do
        if [ -f "${archive}" ]; then
            if extract_offline_archive "${archive}"; then
                break
            fi
        fi
    done
    if ! is_repo_populated; then
        echo "Offline Maven repository at ${REPO_DIR} is empty." >&2
        echo "Provide the cached artifacts or an archive named m2repository.* before running the build." >&2
        exit 1
    fi
}

prepare_offline_repo

REQUIRED_ARTIFACTS=(
    "com/android/tools/build/gradle/8.6.1/gradle-8.6.1.pom"
    "com/android/tools/build/gradle/8.6.1/gradle-8.6.1.jar"
)

for artifact in "${REQUIRED_ARTIFACTS[@]}"; do
    if [ ! -f "${REPO_DIR}/${artifact}" ]; then
        echo "Missing artifact ${artifact} in offline repository." >&2
        exit 1
    fi
done

export GRADLE_USER_HOME="${GRADLE_HOME_DIR}"
cd "${PROJECT_ROOT}"

gradle --offline assembleRelease "$@"
