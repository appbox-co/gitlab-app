#!/bin/bash
# Shared helpers for tests/release-gate.sh and tests/upgrade-chain.sh.
# Sourced, never run. Every container, volume and network a test creates is
# named "${T_PREFIX}-..." and labelled cylo.job=${T_JOB}, and removed by
# t_cleanup on exit.

T_TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T_JOB="${CYLO_JOB:-gitlab-test-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')}"
case "${T_JOB}" in '' | *[!A-Za-z0-9_.-]*) echo "bad CYLO_JOB" >&2; exit 2 ;; esac
T_PREFIX="${T_JOB}"
T_LABEL="cylo.job=${T_JOB}"
T_NET="${T_PREFIX}-net"
T_MOCK="${T_PREFIX}-mock"
T_DOMAIN="gitlab-test.example.com"

t_log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
t_fail() { t_log "FAIL: $*"; exit 1; }

t_cleanup() {
    local ids
    ids=$(docker ps -aq --filter "label=${T_LABEL}")
    [[ -n "${ids}" ]] && docker rm -f -v ${ids} >/dev/null 2>&1
    ids=$(docker volume ls -q --filter "label=${T_LABEL}")
    [[ -n "${ids}" ]] && docker volume rm ${ids} >/dev/null 2>&1
    ids=$(docker network ls -q --filter "label=${T_LABEL}")
    [[ -n "${ids}" ]] && docker network rm ${ids} >/dev/null 2>&1
    rm -rf "${T_TMP:-/nonexistent-gitlab-test}"
    return 0
}

t_setup() {
    T_TMP="$(mktemp -d "/tmp/${T_PREFIX}.XXXXXX")"
    trap t_cleanup EXIT
    trap 'exit 130' INT TERM
    docker network create --label "${T_LABEL}" "${T_NET}" >/dev/null
}

# Mock Appbox API. Runs the image's embedded Ruby, so no other image is needed.
t_start_mock() {
    local image="$1"
    docker run -d --name "${T_MOCK}" --label "${T_LABEL}" --network "${T_NET}" \
        -v "${T_TESTS_DIR}/mock-api.rb:/mock-api.rb:ro" \
        --entrypoint /opt/gitlab/embedded/bin/ruby "${image}" /mock-api.rb >/dev/null
}

# Number of installed callbacks the mock received for an instance id.
t_callbacks() {
    docker logs "${T_MOCK}" 2>&1 | grep -c "^MOCK POST /v1/apps/installed/$1\$" || true
}

t_volumes() {
    local name="$1" v
    for v in etc opt log; do
        docker volume create --label "${T_LABEL}" "${T_PREFIX}-${name}-${v}" >/dev/null
    done
}

# t_env_file <file> <instance-id> <password>
t_env_file() {
    printf '%s\n' \
        "DOMAIN=${T_DOMAIN}" \
        "SSH_PORT=2222" \
        "INSTANCE_ID=$2" \
        "GITLAB_ROOT_EMAIL=gate-owner@example.com" \
        "GITLAB_ROOT_PASSWORD=$3" \
        "APPBOX_CALLBACK_BASE=http://${T_MOCK}:8080" \
        "APPBOX_CALLBACK_RETRY_DELAY=1" > "$1"
    chmod 0600 "$1"
}

# t_run <container> <volume-set> <image> <env-file> [extra docker run args...]
# Mirrors the production limits: 6 GB memory, no swap, init.
t_run() {
    local name="$1" vols="$2" image="$3" envfile="$4"
    shift 4
    docker run -d --name "${name}" --label "${T_LABEL}" --network "${T_NET}" \
        --memory 6g --memory-swap 6g --init \
        --env-file "${envfile}" \
        -v "${T_PREFIX}-${vols}-etc:/etc/gitlab" \
        -v "${T_PREFIX}-${vols}-opt:/var/opt/gitlab" \
        -v "${T_PREFIX}-${vols}-log:/var/log/gitlab" \
        "$@" "${image}" >/dev/null
}

t_running() {
    [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]
}

# t_wait_healthy <container> <timeout-seconds>
t_wait_healthy() {
    local name="$1" deadline=$((SECONDS + $2))
    while ((SECONDS < deadline)); do
        t_running "${name}" || t_fail "${name} stopped (exit $(docker inspect -f '{{.State.ExitCode}}' "${name}"))"
        if docker exec "${name}" /opt/gitlab/bin/gitlab-healthcheck --fail --max-time 10 >/dev/null 2>&1; then
            return 0
        fi
        sleep 15
    done
    t_fail "${name} not healthy after $2s"
}

# t_wait_exit <container> <timeout-seconds>; prints the exit code.
t_wait_exit() {
    local name="$1" deadline=$((SECONDS + $2))
    while ((SECONDS < deadline)); do
        if ! t_running "${name}"; then
            docker inspect -f '{{.State.ExitCode}}' "${name}"
            return 0
        fi
        sleep 10
    done
    t_fail "${name} still running after $2s"
}

# t_wait_callbacks <instance-id> <count> <timeout-seconds>
t_wait_callbacks() {
    local deadline=$((SECONDS + $3))
    while ((SECONDS < deadline)); do
        [[ "$(t_callbacks "$1")" -ge "$2" ]] && return 0
        sleep 10
    done
    t_fail "expected $2 callback(s) for instance $1, got $(t_callbacks "$1")"
}

# t_login <container> <password> -> 0 when GitLab signs the owner in.
# The password reaches the container through the environment and a file,
# never a command line.
t_login() {
    T_LOGIN_PASSWORD="$2" docker exec -i -e T_LOGIN_PASSWORD -e T_DOMAIN="${T_DOMAIN}" \
        "$1" bash -s < "${T_TESTS_DIR}/login-check.sh"
}

# Files on a stopped container's volume set: t_file_exists <volume-set> <path-under-/etc/gitlab>
t_marker() {
    docker run --rm --label "${T_LABEL}" -v "${T_PREFIX}-$1-etc:/etc/gitlab:ro" \
        --entrypoint test "${T_IMAGE_FOR_TOOLS}" -f "/etc/gitlab/$2"
}

# Batched background migrations not yet finished (status 3 = finished,
# 6 = finalized).
t_bbm_pending() {
    docker exec "$1" gitlab-psql -At -c \
        "SELECT count(*) FROM batched_background_migrations WHERE status NOT IN (3, 6)" 2>/dev/null | tail -1
}

t_wait_bbm() {
    local name="$1" deadline=$((SECONDS + $2)) pending
    while ((SECONDS < deadline)); do
        pending="$(t_bbm_pending "${name}")"
        [[ "${pending}" == "0" ]] && return 0
        t_log "${name}: ${pending:-?} batched background migrations still running"
        sleep 60
    done
    t_fail "${name}: batched background migrations not finished after $2s"
}

t_gitlab_version() {
    docker run --rm --label "${T_LABEL}" --entrypoint awk "$1" \
        '/^gitlab-(ce|ee)/ {print $NF; exit}' /opt/gitlab/version-manifest.txt
}
