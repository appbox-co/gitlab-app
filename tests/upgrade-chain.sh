#!/bin/bash
# =============================================================================
# Upgrade chain: tests/upgrade-chain.sh <base-image> <stop-image>...
# =============================================================================
#
# Installs <base-image> (the image customers run now), adds a project, an
# issue and a commit, then:
#   - starts the LAST image on that data and expects GitLab to refuse the
#     skipped stops without changing anything;
#   - steps through every <stop-image> in order on the same volumes. At each
#     stop it checks the GitLab version on disk, one installed callback, the
#     owner's sign-in, the project data, and waits for GitLab's batched
#     background migrations to finish before the next stop.
# Prints how long each stop took.
set -u
set -o pipefail

[[ $# -ge 2 ]] || { echo "usage: $0 <base-image> <stop-image>..." >&2; exit 2; }
for ref in "$@"; do
    case "${ref}" in
        repo.cylo.net/gitlab-ce:* ) ;;
        *) echo "unexpected image ${ref}" >&2; exit 2 ;;
    esac
    case "${ref}" in *[!A-Za-z0-9._/:-]*) echo "bad image reference" >&2; exit 2 ;; esac
done
base="$1"
shift
stops=("$@")
last="${stops[${#stops[@]}-1]}"

source "$(dirname "$0")/lib.sh"
T_IMAGE_FOR_TOOLS="${last}"
t_setup
t_start_mock "${last}"

password='Bv"8\'"'"'$Nc-Hx2!Wy'
t_volumes chain
t_env_file "${T_TMP}/base.env" 425000 "${password}"

# --- Base install ---------------------------------------------------------
# The base image's entrypoint posts its callback to api.cylo.io in a loop;
# point that name at the container itself so nothing leaves the builder.
started=${SECONDS}
t_run "${T_PREFIX}-c0" chain "${base}" "${T_TMP}/base.env" --add-host api.cylo.io:127.0.0.1
t_log "base: waiting for GitLab"
t_wait_healthy "${T_PREFIX}-c0" 1800
t_login "${T_PREFIX}-c0" "${password}" || t_fail "base: owner cannot sign in"
base_version="$(docker exec "${T_PREFIX}-c0" cat /var/opt/gitlab/gitlab-rails/VERSION)"
t_log "base: GitLab ${base_version} up in $((SECONDS - started))s"

token="glpat-chain$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
docker exec -i -e T_TOKEN="${token}" "${T_PREFIX}-c0" gitlab-rails runner - <<'RUBY' || t_fail "base: could not create an API token"
user = User.admins.first
pat = user.personal_access_tokens.build(name: 'upgrade-chain', scopes: ['api'], expires_at: 30.days.from_now)
if pat.respond_to?(:organization_id=) && pat.organization_id.nil?
  pat.organization_id = user.try(:organization_id) || Organizations::Organization.first&.id
end
pat.set_token(ENV.fetch('T_TOKEN'))
pat.save!
puts 'token created'
RUBY

api() {
    # api <container> <method> <path> [curl args...]
    local name="$1" method="$2" path="$3"
    shift 3
    docker exec -e T_TOKEN="${token}" -e T_DOMAIN="${T_DOMAIN}" "${name}" sh -c \
        'm="$1"; p="$2"; shift 2; curl -sS -f -X "$m" -H "Host: ${T_DOMAIN}" -H "PRIVATE-TOKEN: ${T_TOKEN}" "http://127.0.0.1/api/v4$p" "$@"' \
        api "${method}" "${path}" "$@"
}

project_id="$(api "${T_PREFIX}-c0" POST /projects -d name=chain-check -d initialize_with_readme=true | jq -r .id)"
[[ "${project_id}" =~ ^[0-9]+$ ]] || t_fail "base: could not create the project"
api "${T_PREFIX}-c0" POST "/projects/${project_id}/repository/files/chain.txt" \
    -d branch=main -d content=appbox-chain-ok -d commit_message=chain >/dev/null || t_fail "base: could not commit"
api "${T_PREFIX}-c0" POST "/projects/${project_id}/issues" -d title=chain-issue >/dev/null || t_fail "base: could not open an issue"

check_data() {
    local name="$1" content issues
    content="$(api "${name}" GET "/projects/${project_id}/repository/files/chain.txt/raw?ref=main")" || t_fail "${name}: file unreadable"
    [[ "${content}" == "appbox-chain-ok" ]] || t_fail "${name}: file content changed"
    issues="$(api "${name}" GET "/projects/${project_id}/issues" | jq -r '[.[] | select(.title == "chain-issue")] | length')"
    [[ "${issues}" == "1" ]] || t_fail "${name}: issue missing"
}
check_data "${T_PREFIX}-c0"
t_log "base: project, commit and issue created"
docker stop -t 120 "${T_PREFIX}-c0" >/dev/null
docker rm -v "${T_PREFIX}-c0" >/dev/null

# --- Skipped stops are refused ----------------------------------------------
t_env_file "${T_TMP}/skip.env" 425099 "${password}"
t_run "${T_PREFIX}-skip" chain "${last}" "${T_TMP}/skip.env"
code="$(t_wait_exit "${T_PREFIX}-skip" 600)"
[[ "${code}" != "0" ]] || t_fail "the last image accepted ${base_version} data"
docker logs "${T_PREFIX}-skip" 2>&1 | grep -q 'It is required to upgrade to the latest' \
    || t_fail "the last image stopped for another reason than the upgrade check"
after="$(docker run --rm --label "${T_LABEL}" -v "${T_PREFIX}-chain-opt:/var/opt/gitlab:ro" \
    --entrypoint cat "${last}" /var/opt/gitlab/gitlab-rails/VERSION)"
[[ "${after}" == "${base_version}" ]] || t_fail "the refused start changed the data version to ${after}"
[[ "$(t_callbacks 425099)" == "0" ]] || t_fail "the refused start sent a callback"
docker rm -v "${T_PREFIX}-skip" >/dev/null
t_log "skip: ${last} refused ${base_version} data and changed nothing"

# --- Stops ----------------------------------------------------------------
i=0
for image in "${stops[@]}"; do
    i=$((i + 1))
    name="${T_PREFIX}-c${i}"
    instance=$((425000 + i))
    want="$(t_gitlab_version "${image}")"
    t_env_file "${T_TMP}/c${i}.env" "${instance}" "${password}"
    started=${SECONDS}
    t_run "${name}" chain "${image}" "${T_TMP}/c${i}.env"
    t_log "stop ${i}: ${want}, waiting for GitLab"
    t_wait_healthy "${name}" 3600
    up=$((SECONDS - started))
    t_wait_callbacks "${instance}" 1 900
    got="$(docker exec "${name}" cat /var/opt/gitlab/gitlab-rails/VERSION)"
    [[ "${got}" == "${want}" ]] || t_fail "stop ${i}: data is on ${got}, expected ${want}"
    t_login "${name}" "${password}" || t_fail "stop ${i}: owner cannot sign in"
    check_data "${name}"
    docker exec "${name}" test -f /etc/gitlab/.appbox-admin-confirmed || t_fail "stop ${i}: confirmed marker missing"
    pg="$(docker exec "${name}" gitlab-psql -At -c 'SHOW server_version' | tail -1)"
    t_wait_bbm "${name}" 7200
    t_log "stop ${i}: GitLab ${got} on PostgreSQL ${pg}; up in ${up}s, background migrations done after $((SECONDS - started))s"
    docker stop -t 120 "${name}" >/dev/null
    docker rm -v "${name}" >/dev/null
done

t_log "PASS ${base_version} -> ${want} through ${#stops[@]} stops"
