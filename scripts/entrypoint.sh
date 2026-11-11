#!/bin/bash
set -x

if [ ! -f /etc/gitlab/gitlab.rb ]; then

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

else
    sed -i '/gitlab_shell_ssh_port/d' /etc/gitlab/gitlab.rb
    sed -i "/set_real_ip_from/a gitlab_rails['gitlab_shell_ssh_port'] = ${SSH_PORT}" /etc/gitlab/gitlab.rb
fi

if [[ ! $(cat /assets/init-container | grep 'Cylo') ]]; then
sed -i '/gitlab-ctl tail/a \
\
echo "Calling back to Cylo API..." \
if [ ! -f /etc/app_configured ]; then \
    touch /etc/app_configured \
    until [[ $(curl -i -H "Accept: application/json" -H "Content-Type:application/json" -X POST "https://api.cylo.io/v1/apps/installed/${INSTANCE_ID}" | grep "200") ]] \
        do \
        sleep 5 \
    done \
fi' /assets/init-container
fi

exec "$@"
