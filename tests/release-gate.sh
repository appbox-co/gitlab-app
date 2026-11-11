#!/bin/bash
# =============================================================================
# Release gate: tests/release-gate.sh <image-ref>
# =============================================================================
#
# Exits 0 only when the local image passes every check below AND the
# authenticated registry reports that its tag does not exist yet. Run it on
# the builder as the last command before `docker push`.
#
#   1. The image's GitLab version matches its tag.
#   2. Fresh install with a password containing " \ ' $: the owner signs in
#      with it, a wrong password is refused, both setup markers are right
#      and exactly one installed callback is sent.
#   3. Restart: healthy again, no second callback.
#   4. Rejected setup (GitLab refuses the password): the container stops
#      without an administrator, the confirmed marker or a callback, and
#      the same happens on the next start.
#   5. Registry: the tag is definitively absent (404 after a successful
#      authenticated /v2/ check). Anything else fails closed.
set -u
set -o pipefail

image="${1:-}"
case "${image}" in
    repo.cylo.net/gitlab-ce:[0-9]*-ce.0) ;;
    *) echo "usage: $0 repo.cylo.net/gitlab-ce:<version>-ce.0" >&2; exit 2 ;;
esac
case "${image}" in *[!A-Za-z0-9._/:-]*) echo "bad image reference" >&2; exit 2 ;; esac
tag="${image##*:}"

source "$(dirname "$0")/lib.sh"
T_IMAGE_FOR_TOOLS="${image}"
t_setup

# --- 1. Version -------------------------------------------------------------
version="$(t_gitlab_version "${image}")"
[[ "${version}-ce.0" == "${tag}" ]] || t_fail "image contains GitLab ${version}, tag is ${tag}"
t_log "image contains GitLab ${version}"

t_start_mock "${image}"

good_password='Qz"7\'"'"'$Lp-Mw4!Tr'
case "${good_password}" in *'"'*) ;; *) t_fail "test password lost its double quote" ;; esac
case "${good_password}" in *'\'*) ;; *) t_fail "test password lost its backslash" ;; esac
case "${good_password}" in *"'"*) ;; *) t_fail "test password lost its single quote" ;; esac
case "${good_password}" in *'$'*) ;; *) t_fail "test password lost its dollar sign" ;; esac
# GitLab refuses passwords that contain "gitlab".
rejected_password='gitlab-rejected-2026'

t_env_file "${T_TMP}/fresh.env" 424201 "${good_password}"
t_env_file "${T_TMP}/rejected.env" 424202 "${rejected_password}"

# Phases 2 and 4 run side by side.
t_volumes fresh
t_volumes rejected
t_run "${T_PREFIX}-fresh" fresh "${image}" "${T_TMP}/fresh.env"
t_run "${T_PREFIX}-rejected" rejected "${image}" "${T_TMP}/rejected.env"

# --- 2. Fresh install ---------------------------------------------------------
t_log "fresh install: waiting for GitLab"
t_wait_healthy "${T_PREFIX}-fresh" 1800
t_wait_callbacks 424201 1 900
docker exec "${T_PREFIX}-fresh" test -f /etc/gitlab/.appbox-admin-confirmed || t_fail "confirmed marker missing"
docker exec "${T_PREFIX}-fresh" test ! -e /etc/gitlab/.appbox-admin-pending || t_fail "pending marker left behind"
docker exec "${T_PREFIX}-fresh" test ! -e /etc/appbox_callback_pending || t_fail "callback still pending"
t_login "${T_PREFIX}-fresh" "${good_password}" || t_fail "owner cannot sign in with the special-character password"
if t_login "${T_PREFIX}-fresh" "${good_password}x"; then
    t_fail "a wrong password signed in"
fi
docker logs "${T_PREFIX}-fresh" 2>&1 | grep -qF -- "${good_password}" && t_fail "the password appears in the container log"
t_log "fresh install: owner signs in, one callback, markers right"

# --- 3. Restart ---------------------------------------------------------------
docker restart "${T_PREFIX}-fresh" >/dev/null
sleep 30
t_wait_healthy "${T_PREFIX}-fresh" 1200
sleep 60
[[ "$(t_callbacks 424201)" == "1" ]] || t_fail "restart sent another callback ($(t_callbacks 424201) in total)"
t_login "${T_PREFIX}-fresh" "${good_password}" || t_fail "owner cannot sign in after a restart"
t_log "restart: healthy, no second callback"
docker rm -f -v "${T_PREFIX}-fresh" >/dev/null

# --- 4. Rejected setup --------------------------------------------------------
for attempt in 1 2; do
    if [[ "${attempt}" == "2" ]]; then
        docker start "${T_PREFIX}-rejected" >/dev/null
    fi
    t_log "rejected setup, start ${attempt}: waiting for the container to stop"
    code="$(t_wait_exit "${T_PREFIX}-rejected" 1800)"
    [[ "${code}" != "0" ]] || t_fail "rejected setup exited 0 on start ${attempt}"
    [[ "$(t_callbacks 424202)" == "0" ]] || t_fail "rejected setup sent a callback"
    t_marker rejected .appbox-admin-pending || t_fail "rejected setup lost its pending marker"
    if t_marker rejected .appbox-admin-confirmed; then
        t_fail "rejected setup wrote the confirmed marker"
    fi
    docker logs "${T_PREFIX}-rejected" 2>&1 | grep -qF -- "${rejected_password}" && t_fail "the password appears in the container log"
done
docker logs "${T_PREFIX}-rejected" 2>&1 \
    | grep -qF '[appbox] The administrator account from the install settings could not be confirmed.' \
    || t_fail "the second start did not stop at the administrator check"
t_log "rejected setup: stopped twice with no administrator, marker or callback"
docker rm -f -v "${T_PREFIX}-rejected" >/dev/null

# --- 5. Registry --------------------------------------------------------------
auth="$(jq -r '.auths["repo.cylo.net"].auth // empty' "${HOME}/.docker/config.json" 2>/dev/null)"
[[ -n "${auth}" ]] || t_fail "no repo.cylo.net credentials on this host"
code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 \
    -H "Authorization: Basic ${auth}" https://repo.cylo.net/v2/)" || code=000
[[ "${code}" == "200" ]] || t_fail "registry /v2/ answered HTTP ${code}; tag status unknown"
code="$(curl -sS -o "${T_TMP}/manifest" -w '%{http_code}' --max-time 30 \
    -H "Authorization: Basic ${auth}" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json' \
    "https://repo.cylo.net/v2/gitlab-ce/manifests/${tag}")" || code=000
case "${code}" in
    404)
        jq -e '.errors[]? | select(.code == "MANIFEST_UNKNOWN" or .code == "NAME_UNKNOWN")' "${T_TMP}/manifest" >/dev/null \
            || t_fail "registry answered 404 without MANIFEST_UNKNOWN; tag status unknown"
        ;;
    200) t_fail "repo.cylo.net/gitlab-ce:${tag} already exists" ;;
    *) t_fail "registry answered HTTP ${code} for the tag; status unknown" ;;
esac
t_log "registry: gitlab-ce:${tag} does not exist yet"

t_log "PASS ${image}"
