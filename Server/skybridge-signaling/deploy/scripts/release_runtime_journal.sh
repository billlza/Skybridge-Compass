#!/usr/bin/env bash
# The signaling release's selected Node runtime and reversible service configuration.
# Explicit returns also preserve failure when a caller uses this helper in an if.

validate_selected_node_runtime() {
    local runtime_dir="$1"
    local runtime_node="$runtime_dir/bin/node"
    local host_platform host_arch description
    if [[ ! "$runtime_dir" =~ ^/[A-Za-z0-9._/-]+$ || "$runtime_dir" == "/" || "/$runtime_dir/" == *"/../"* ]]; then
        echo "[runtime] Invalid Node runtime directory" >&2
        return 1
    fi
    if [[ ! -x "$runtime_node" || ! -f "$runtime_dir/lib/node_modules/npm/bin/npm-cli.js" ]]; then
        echo "[runtime] Selected runtime must contain bin/node and its bundled npm CLI" >&2
        return 1
    fi
    case "$(uname -s)" in
        Linux) host_platform=linux ;;
        Darwin) host_platform=darwin ;;
        *) echo "[runtime] Unsupported host platform" >&2; return 1 ;;
    esac
    case "$(uname -m)" in
        aarch64|arm64) host_arch=arm64 ;;
        x86_64|amd64) host_arch=x64 ;;
        *) echo "[runtime] Unsupported host architecture" >&2; return 1 ;;
    esac
    description="$("$runtime_node" -p 'JSON.stringify({version:process.versions.node,platform:process.platform,arch:process.arch,execPath:process.execPath})')" || return
    "$runtime_node" - "$description" "$runtime_node" "$host_platform" "$host_arch" <<'VALIDATE_RUNTIME'
const fs = require('node:fs');
const [raw, selectedNode, platform, arch] = process.argv.slice(2);
function fail(message) { console.error('[runtime] ' + message); process.exit(1); }
let runtime;
try { runtime = JSON.parse(raw); } catch { fail('Selected Node returned invalid runtime metadata'); }
if (!runtime || typeof runtime.version !== 'string') fail('Selected Node did not report its version');
const version = runtime.version.split('.').map(Number);
if (version.length !== 3 || !version.every((component) => Number.isSafeInteger(component) && component >= 0)
    || version[0] < 24 || (version[0] === 24 && version[1] < 6)) {
  fail('Node.js 24.6.0 or newer is required');
}
if (runtime.platform !== platform || runtime.arch !== arch) fail('Selected Node does not match the host platform and architecture');
if (typeof runtime.execPath !== 'string' || fs.realpathSync(runtime.execPath) !== fs.realpathSync(selectedNode)) {
  fail('Selected Node executable does not match runtime metadata');
}
console.log('[runtime] version=' + runtime.version + ' platform=' + runtime.platform + ' arch=' + runtime.arch + ' executable=' + runtime.execPath);
VALIDATE_RUNTIME
}

service_runtime_dropin_path() {
    printf '/etc/systemd/system/%s.service.d/20-node-runtime.conf\n' "$1"
}

read_health_build_fingerprint() {
    local runtime_dir="$1"
    local health_url="$2"
    local response_file="$3"
    local status
    status="$(sudo curl --disable --silent --show-error --connect-timeout 5 --max-time 15 \
        --max-filesize 1048576 --proto '=http,https' --output "$response_file" \
        --write-out '%{http_code}' "$health_url")" || return
    if [[ "$status" != "200" ]]; then
        echo "[runtime] Health identity probe expected HTTP 200, received $status" >&2
        return 1
    fi
    sudo "$runtime_dir/bin/node" - "$response_file" <<'READ_HEALTH_BUILD'
const fs = require('node:fs');
function fail(message) { console.error('[runtime] ' + message); process.exit(1); }
let body;
try { body = JSON.parse(fs.readFileSync(process.argv[2], 'utf8')); } catch { fail('Health identity response is not valid JSON'); }
const build = body && body.serverBuildFingerprint;
if (typeof build !== 'string' || !build || build.length > 256 || /[\u0000-\u001f\u007f]/.test(build)) {
  fail('Health identity response has no valid serverBuildFingerprint');
}
console.log(build);
READ_HEALTH_BUILD
}

capture_previous_health_build() {
    local release_dir="$1"
    local previous_release="$2"
    local health_url="$3"
    local runtime_dir observed expected
    runtime_dir="$(cat "$release_dir/.node-runtime-dir")" || return
    observed="$(read_health_build_fingerprint "$runtime_dir" "$health_url" "$release_dir/.service-runtime-journal/previous-health.json")" || return
    if [[ -f "$previous_release/.skybridge-build-fingerprint" ]]; then
        expected="$(sudo cat "$previous_release/.skybridge-build-fingerprint")" || return
        if [[ "$observed" != "$expected" ]]; then
            echo "[runtime] Running predecessor build does not match its release" >&2
            return 1
        fi
    fi
    printf '%s\n' "$observed" | sudo tee "$release_dir/.service-runtime-journal/previous-health-build" >/dev/null
}

expected_rollback_build() {
    local source_release="$1"
    local target_release="$2"
    local expected previous_target
    if [[ -f "$target_release/.skybridge-build-fingerprint" ]]; then
        expected="$(sudo cat "$target_release/.skybridge-build-fingerprint")" || return
    else
        previous_target="$(cat "$source_release/.previous-current-target")" || return
        if [[ "$previous_target" != "$target_release" ]]; then
            echo "[runtime] Legacy target has no matching predecessor health receipt" >&2
            return 1
        fi
        expected="$(sudo cat "$source_release/.service-runtime-journal/previous-health-build")" || return
    fi
    if [[ -z "$expected" ]]; then
        echo "[runtime] Rollback target has no build identity" >&2
        return 1
    fi
    printf '%s\n' "$expected"
}

verify_rollback_build() {
    local source_release="$1"
    local target_release="$2"
    local health_url="$3"
    local runtime_dir expected observed
    runtime_dir="$(cat "$source_release/.node-runtime-dir")" || return
    expected="$(expected_rollback_build "$source_release" "$target_release")" || return
    observed="$(read_health_build_fingerprint "$runtime_dir" "$health_url" "$source_release/.service-runtime-journal/restored-health.json")" || return
    if [[ "$observed" != "$expected" ]]; then
        echo "[runtime] Restored service build does not match the rollback target" >&2
        return 1
    fi
    echo "[runtime] Restored build verified: $expected"
}

capture_service_runtime_journal() {
    local release_dir="$1"
    local service="$2"
    local journal="$release_dir/.service-runtime-journal"
    local unit="/etc/systemd/system/$service.service"
    local dropin
    dropin="$(service_runtime_dropin_path "$service")"
    sudo mkdir -m 0700 "$journal" || return
    printf '1\n' | sudo tee "$journal/version" >/dev/null || return
    capture_service_configuration_file "$unit" "$journal/unit" || return
    capture_service_configuration_file "$dropin" "$journal/runtime"
}

capture_service_configuration_file() {
    local destination="$1"
    local snapshot="$2"
    if sudo test -e "$destination" || sudo test -L "$destination"; then
        if ! sudo test -f "$destination" && ! sudo test -L "$destination"; then
            echo "[runtime] Service configuration is not a file: $destination" >&2
            return 1
        fi
        sudo cp -a "$destination" "$snapshot" || return
        printf 'present\n' | sudo tee "$snapshot.state" >/dev/null
    else
        printf 'absent\n' | sudo tee "$snapshot.state" >/dev/null
    fi
}

apply_recorded_release_configuration() {
    local release_dir="$1"
    local service="$2"
    local runtime_dir dropin
    if [[ ! -f "$release_dir/.node-runtime-dir" || ! -f "$release_dir/deploy/systemd/skybridge-signaling.service" ]]; then
        echo "[runtime] Target release has no recorded Node runtime and service unit" >&2
        return 1
    fi
    validate_service_runtime_journal "$release_dir/.service-runtime-journal" || return
    runtime_dir="$(cat "$release_dir/.node-runtime-dir")" || return
    validate_selected_node_runtime "$runtime_dir" || return
    dropin="$(service_runtime_dropin_path "$service")"
    sudo mkdir -p "$(dirname "$dropin")" || return
    printf '[Service]\nExecStart=\nExecStart=%s/bin/node server.js\n' "$runtime_dir" \
        | sudo tee "$release_dir/.service-runtime-journal/selected-runtime.conf" >/dev/null || return
    sudo rm -f -- "/etc/systemd/system/$service.service" || return
    sudo install -m 0644 "$release_dir/deploy/systemd/skybridge-signaling.service" "/etc/systemd/system/$service.service" || return
    sudo rm -f -- "$dropin" || return
    sudo install -m 0644 "$release_dir/.service-runtime-journal/selected-runtime.conf" "$dropin"
}

validate_service_runtime_journal() {
    local journal="$1"
    local entry state version
    version="$(sudo cat "$journal/version")" || return
    if [[ "$version" != "1" ]]; then
        echo "[runtime] Unsupported service runtime journal version" >&2
        return 1
    fi
    for entry in unit runtime; do
        state="$(sudo cat "$journal/$entry.state")" || return
        case "$state" in
            present)
                if ! sudo test -f "$journal/$entry" && ! sudo test -L "$journal/$entry"; then
                    echo "[runtime] Service runtime journal is missing $entry" >&2
                    return 1
                fi
                ;;
            absent) ;;
            *) echo "[runtime] Invalid service runtime journal state for $entry" >&2; return 1 ;;
        esac
    done
}

restore_service_configuration_file() {
    local snapshot="$1"
    local destination="$2"
    local state
    state="$(sudo cat "$snapshot.state")" || return
    if [[ "$state" == "present" ]]; then
        sudo mkdir -p "$(dirname "$destination")" || return
        # Remove only the known service file so a symlink is restored as a symlink.
        sudo rm -f -- "$destination" || return
        sudo cp -a "$snapshot" "$destination"
    else
        sudo rm -f -- "$destination"
    fi
}

switch_to_recorded_release() {
    local source_release="$1"
    local target_release="$2"
    local service="$3"
    local current_link="$4"
    local operation="${5:-rollback}"
    local previous_target=""
    local journal="$source_release/.service-runtime-journal"
    local verified_build target_build
    if [[ "$operation" != "promote" && "$operation" != "rollback" ]]; then
        echo "[runtime] Invalid release switch operation" >&2
        return 1
    fi
    if [[ -n "$source_release" && -f "$source_release/.previous-current-target" ]]; then
        previous_target="$(cat "$source_release/.previous-current-target")" || return
    fi
    if [[ "$previous_target" == "$target_release" ]] && sudo test -d "$journal"; then
        validate_service_runtime_journal "$journal" || return
        if [[ "$operation" == "rollback" ]]; then expected_rollback_build "$source_release" "$target_release" >/dev/null || return; fi
        restore_service_configuration_file "$journal/unit" "/etc/systemd/system/$service.service" || return
        restore_service_configuration_file "$journal/runtime" "$(service_runtime_dropin_path "$service")" || return
    elif [[ "$operation" == "promote" && -f "$target_release/.node-runtime-dir" ]]; then
        apply_recorded_release_configuration "$target_release" "$service" || return
    elif [[ "$operation" == "rollback" && -f "$target_release/.node-runtime-dir" && -f "$target_release/.deployment-verified" && -f "$target_release/.skybridge-build-fingerprint" ]]; then
        verified_build="$(cat "$target_release/.deployment-verified")" || return
        target_build="$(cat "$target_release/.skybridge-build-fingerprint")" || return
        if [[ -z "$verified_build" || "$verified_build" != "$target_build" ]]; then
            echo "[runtime] Target release verification record does not match its build" >&2
            return 1
        fi
        apply_recorded_release_configuration "$target_release" "$service" || return
    else
        echo "[runtime] Target release has no runtime record or matching previous-release journal; refusing to guess" >&2
        return 1
    fi
    sudo ln -sfn "$target_release" "$current_link" || return
    sudo chown -h skybridge:skybridge "$current_link" || return
    sudo systemctl daemon-reload || return
    sudo systemctl restart "$service"
}
