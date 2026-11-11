#!/bin/bash
# =============================================================================
# Appbox entrypoint for the GitLab CE image
# =============================================================================
#
# Runs before the image's own /assets/init-container (the CMD), then hands
# over to it with exec. init-container runs `gitlab-ctl reconfigure`, which
# installs or upgrades GitLab, and then /scripts/appbox-post-reconfigure
# (GITLAB_POST_RECONFIGURE_SCRIPT in the Dockerfile).
#
# STATE
#   /etc/gitlab/.appbox-admin-pending    (volume) a fresh install whose
#                                        administrator is not confirmed yet
#   /etc/gitlab/.appbox-admin-confirmed  (volume) administrator confirmed, or
#                                        installed by an image older than
#                                        this check
#   /etc/app_configured                  (container) this container has
#                                        started before
#   /etc/appbox_callback_pending         (container) the installed callback
#                                        for this container is not sent yet
#
# The environment holds the administrator password and the callback token,
# so this script is never traced.
{ set +x; } 2>/dev/null
set -u

ADMIN_PENDING=/etc/gitlab/.appbox-admin-pending
ADMIN_CONFIRMED=/etc/gitlab/.appbox-admin-confirmed
CONFIG_FLAG=/etc/app_configured
CALLBACK_PENDING=/etc/appbox_callback_pending

case "${SSH_PORT:-}" in
    '' | *[!0-9]*)
        echo "[appbox] SSH_PORT must be a port number" >&2
        exit 1
        ;;
esac

# GitLab writes /var/opt/gitlab/gitlab-rails/VERSION during its first
# reconfigure. Without it and without a marker, this is a fresh install.
if [[ ! -f "${ADMIN_CONFIRMED}" && ! -f "${ADMIN_PENDING}" ]]; then
    if [[ -f /var/opt/gitlab/gitlab-rails/VERSION ]]; then
        touch "${ADMIN_CONFIRMED}"
    else
        touch "${ADMIN_PENDING}"
    fi
fi

if [[ ! -f /etc/gitlab/gitlab.rb ]]; then
    cat << EOF > /etc/gitlab/gitlab.rb
external_url 'https://${DOMAIN}'
nginx['listen_port'] = 80

nginx['listen_https'] = false

nginx['proxy_set_headers'] = {

"X-Forwarded-Proto" => "https",

"X-Forwarded-Ssl" => "on"

}
puma['worker_processes'] = 2
sidekiq['concurrency'] = 2
puma['worker_timeout'] = 180
nginx['real_ip_header'] = 'X-Real-IP'
nginx['set_real_ip_from'] = '172.20.0.0/12'
gitlab_rails['gitlab_shell_ssh_port'] = ${SSH_PORT}
postgresql['shared_buffers'] = "1MB"
prometheus_monitoring['enable'] = false
EOF
    chmod 0600 /etc/gitlab/gitlab.rb
else
    # The SSH port can change when the app moves; keep gitlab.rb in step.
    sed -i '/gitlab_shell_ssh_port/d' /etc/gitlab/gitlab.rb
    sed -i "/set_real_ip_from/a gitlab_rails['gitlab_shell_ssh_port'] = ${SSH_PORT}" /etc/gitlab/gitlab.rb
fi

# One installed callback per container: Appbox creates a new container for
# every install and update. Mark it pending before the container is marked
# configured, so a stop between the two cannot lose it.
if [[ ! -f "${CONFIG_FLAG}" ]]; then
    touch "${CALLBACK_PENDING}"
    touch "${CONFIG_FLAG}"
fi

exec "$@"
