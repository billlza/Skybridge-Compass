#!/usr/bin/env bash

skybridge_default_macos_destination() {
    printf '%s\n' "${SKYBRIDGE_MACOS_BUILD_DESTINATION:-platform=macOS,arch=arm64}"
}

skybridge_filter_xcodebuild_output() {
    awk '
        BEGIN {
            skipDestinationWarning = 0
        }

        /^[0-9][0-9][0-9][0-9]-[0-9]{2}-[0-9]{2}[[:space:]][0-9:.+-]+[[:space:]]xcodebuild\[[0-9]+:[0-9]+\][[:space:]]\[MT\][[:space:]]IDERunDestination: Supported platforms for the buildables in the current scheme is empty\.$/ {
            next
        }

        /^--- xcodebuild: WARNING: Using the first of multiple matching destinations:$/ {
            skipDestinationWarning = 1
            next
        }

        skipDestinationWarning {
            if ($0 ~ /^[[:space:]]*\{[[:space:]]*platform:/) {
                next
            }
            skipDestinationWarning = 0
        }

        {
            print
        }
    '
}

skybridge_run_xcodebuild() {
    local temp_dir
    local fifo_path
    local filter_pid
    local command_status

    if [[ "${SKYBRIDGE_XCODEBUILD_KEEP_NOISE:-0}" == "1" ]]; then
        xcodebuild "$@"
        return $?
    fi

    temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/skybridge-xcodebuild.XXXXXX")"
    fifo_path="${temp_dir}/output.fifo"
    mkfifo "${fifo_path}"

    skybridge_filter_xcodebuild_output < "${fifo_path}" &
    filter_pid=$!

    xcodebuild "$@" > "${fifo_path}" 2>&1
    command_status=$?

    wait "${filter_pid}" || true
    rm -rf "${temp_dir}"

    return "${command_status}"
}
