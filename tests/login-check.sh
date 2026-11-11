#!/bin/bash
# Runs inside a GitLab container (bash -s). Signs in through the web form
# as gate-owner@example.com with T_LOGIN_PASSWORD; exits 0 on success.
# GitLab sees https from its nginx, so its session cookie is Secure and curl
# will not keep it from a plain http answer; it is passed on by hand.
set -u
work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT
printf '%s' "${T_LOGIN_PASSWORD}" > "${work}/password"
unset T_LOGIN_PASSWORD

curl -sS -D "${work}/headers" -H "Host: ${T_DOMAIN}" http://127.0.0.1/users/sign_in > "${work}/page" || exit 2
token=$(grep -o 'name="authenticity_token" value="[^"]*"' "${work}/page" | head -1 | sed 's/.*value="//; s/"$//')
session=$(tr -d '\r' < "${work}/headers" | grep -i '^set-cookie: _gitlab_session=' | head -1 | sed 's/^[^:]*: //; s/;.*//')
[ -n "${token}" ] && [ -n "${session}" ] || { echo "no sign-in form or session" >&2; exit 2; }

result=$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' \
    -H "Cookie: ${session}" -H "Host: ${T_DOMAIN}" \
    --data-urlencode "authenticity_token=${token}" \
    --data-urlencode "user[login]=gate-owner@example.com" \
    --data-urlencode "user[password]@${work}/password" \
    http://127.0.0.1/users/sign_in) || exit 2

case "${result}" in
    302\ */users/sign_in* | 302\ */users/password* ) exit 1 ;;
    302\ *) exit 0 ;;
    *) exit 1 ;;
esac
