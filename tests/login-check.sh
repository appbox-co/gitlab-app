#!/bin/bash
# Runs inside a GitLab container (bash -s). Signs in through the web form
# as gate-owner@example.com with T_LOGIN_PASSWORD; exits 0 on success.
# GitLab sees https from its nginx, so it marks the session cookie Secure;
# the jar is edited so curl still sends it over the local http hop.
set -u
work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT
printf '%s' "${T_LOGIN_PASSWORD}" > "${work}/password"
unset T_LOGIN_PASSWORD

curl -sS -c "${work}/jar" -H "Host: ${T_DOMAIN}" http://127.0.0.1/users/sign_in > "${work}/page" || exit 2
token=$(grep -o 'name="authenticity_token" value="[^"]*"' "${work}/page" | head -1 | sed 's/.*value="//; s/"$//')
[ -n "${token}" ] || { echo "no sign-in form" >&2; exit 2; }
awk 'BEGIN { FS = OFS = "\t" } NF >= 7 { $4 = "FALSE" } { print }' "${work}/jar" > "${work}/jar2"

result=$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' \
    -b "${work}/jar2" -H "Host: ${T_DOMAIN}" \
    --data-urlencode "authenticity_token=${token}" \
    --data-urlencode "user[login]=gate-owner@example.com" \
    --data-urlencode "user[password]@${work}/password" \
    http://127.0.0.1/users/sign_in) || exit 2

case "${result}" in
    302\ */users/sign_in* | 302\ */users/password* ) exit 1 ;;
    302\ *) exit 0 ;;
    *) exit 1 ;;
esac
