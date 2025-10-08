#!/bin/bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Allow overriding the cached Maven repository location so developers with
# pre-extracted artifacts elsewhere can reuse them without copying into the
# repository checkout.
REPO_DIR="${OFFLINE_M2_PATH:-${PROJECT_ROOT}/third_party/m2repository}"
GRADLE_HOME_DIR="${PROJECT_ROOT}/.gradle-offline"
GRADLE_VERSION="9.0.0"
GRADLE_DISTS_DIR="${GRADLE_HOME_DIR}/distributions"
GRADLE_INSTALL_DIR="${GRADLE_DISTS_DIR}/gradle-${GRADLE_VERSION}"
GRADLE_BIN="${GRADLE_INSTALL_DIR}/bin/gradle"

is_repo_populated() {
    if [ ! -d "${REPO_DIR}" ]; then
        return 1
    fi
    local first
    first="$(find "${REPO_DIR}" -mindepth 1 -not -name '.gitkeep' -print -quit 2>/dev/null || true)"
    [ -n "${first}" ]
}

collect_archives() {
    local -n _result_ref="$1"
    shift
    local search_roots=("${PROJECT_ROOT}/third_party" "${PROJECT_ROOT}/dist" "${PROJECT_ROOT}")
    local patterns=("$@")
    for root in "${search_roots[@]}"; do
        [ -d "${root}" ] || continue
        for pattern in "${patterns[@]}"; do
            while IFS= read -r -d '' path; do
                _result_ref+=("${path}")
            done < <(find "${root}" -maxdepth 3 -type f -name "${pattern}" -print0 2>/dev/null)
        done
    done
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
    local archives=()
    collect_archives archives \
        'm2repository.zip' 'm2repository.tgz' 'm2repository.tar' \
        'm2repository.tar.gz' 'm2repository.tar.bz2' 'm2repository.tbz2' \
        'm2repository-*.zip' 'm2repository-*.tgz' 'm2repository-*.tar' \
        'm2repository-*.tar.gz' 'm2repository-*.tar.bz2' 'm2repository-*.tbz2' \
        '*-m2repository.zip' '*-m2repository.tgz' '*-m2repository.tar' \
        '*-m2repository.tar.gz' '*-m2repository.tar.bz2' '*-m2repository.tbz2' \
        '*offline-maven*.zip' '*offline-maven*.tgz' '*offline-maven*.tar' \
        '*offline-maven*.tar.gz' '*offline-maven*.tar.bz2' '*offline-maven*.tbz2'
    if [ ${#archives[@]} -gt 0 ]; then
        IFS=$'\n' archives=($(printf '%s\n' "${archives[@]}" | sort))
        unset IFS
    fi
    for archive in "${archives[@]}"; do
        if extract_offline_archive "${archive}"; then
            break
        fi
    done
    if ! is_repo_populated; then
        echo "Offline Maven repository at ${REPO_DIR} is empty." >&2
        if [ ${#archives[@]} -eq 0 ]; then
            echo "No m2repository archives were found under third_party/, dist/, or the repo root." >&2
        else
            echo "Checked the following archives without finding cached artifacts:" >&2
            printf '  - %s\n' "${archives[@]}" >&2
        fi
        echo "Provide the cached artifacts or an archive named m2repository.* before running the build." >&2
        exit 1
    fi
}

ensure_gradle_distribution() {
    if [ -x "${GRADLE_BIN}" ]; then
        return
    fi

    local archives=()
    collect_archives archives \
        "gradle-${GRADLE_VERSION}-bin.zip" \
        "gradle-${GRADLE_VERSION}-all.zip" \
        "gradle-${GRADLE_VERSION}.zip" \
        "gradle-${GRADLE_VERSION}-*.zip"
    if [ ${#archives[@]} -gt 0 ]; then
        IFS=$'\n' archives=($(printf '%s\n' "${archives[@]}" | sort))
        unset IFS
    fi

    for archive in "${archives[@]}"; do
        mkdir -p "${GRADLE_DISTS_DIR}"
        unzip -qo "${archive}" -d "${GRADLE_DISTS_DIR}"
        if [ -x "${GRADLE_BIN}" ]; then
            break
        fi
    done

    if [ -x "${GRADLE_BIN}" ]; then
        return
    fi

    if command -v gradle >/dev/null 2>&1; then
        GRADLE_BIN="$(command -v gradle)"
        echo "Gradle ${GRADLE_VERSION} archive not provided; using system Gradle at ${GRADLE_BIN}." >&2
        return
    fi

    echo "Gradle ${GRADLE_VERSION} distribution not found. Place gradle-${GRADLE_VERSION}-*.zip under third_party/." >&2
    exit 1
}

prepare_offline_repo
ensure_gradle_distribution

REQUIRED_ARTIFACTS=(
    "com/android/tools/build/gradle/8.7.3/gradle-8.7.3.pom"
    "com/android/tools/build/gradle/8.7.3/gradle-8.7.3.jar"
)

for artifact in "${REQUIRED_ARTIFACTS[@]}"; do
    if [ ! -f "${REPO_DIR}/${artifact}" ]; then
        echo "Missing artifact ${artifact} in offline repository." >&2
        exit 1
    fi
done

export GRADLE_USER_HOME="${GRADLE_HOME_DIR}"
cd "${PROJECT_ROOT}"

"${GRADLE_BIN}" --offline assembleRelease "$@"
