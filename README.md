# GitLab CE for Appbox

Appbox app 119. The image is the official `gitlab/gitlab-ce` image with a
small Appbox layer:

- `scripts/entrypoint.sh` writes `/etc/gitlab/gitlab.rb` on the first start,
  keeps the SSH port in step on later starts, and marks the installed
  callback as pending once per container.
- `scripts/appbox-post-reconfigure` runs after `gitlab-ctl reconfigure`
  (`GITLAB_POST_RECONFIGURE_SCRIPT`). On a fresh install it confirms that the
  administrator from the install fields (`GITLAB_ROOT_EMAIL`,
  `GITLAB_ROOT_PASSWORD`) signs in, and fails closed if not: GitLab stops,
  no callback is sent and the next start tries again. It then sends the
  installed callback in the background with `scripts/appbox-installed-callback`
  (copied unchanged from example-app).

Persistent data: `/etc/gitlab`, `/var/opt/gitlab`, `/var/log/gitlab`.

## Upgrade stops

GitLab must be upgraded through its required stops (x.2, x.5, x.8 and x.11
from GitLab 17) and its batched background migrations must finish at each
stop. Each upstream image refuses data older than the previous stop
(`gitlab-ctl upgrade-check` in `/assets/init-container`), so a skipped stop
stops the container before anything changes.

The dashboard's Update button moves an instance straight to the default
version. So each stop is released as its own catalogue version, admin-only,
existing instances are stepped through them by an operator, and only then
does the newest version become the default. 18.11 also upgrades the bundled
PostgreSQL from 16 to 17 on its first start.

| Version | Requires data from |
| --- | --- |
| 18.5.7-ce.0 | 18.2 or later |
| 18.8.11-ce.0 | 18.5 or later |
| 18.11.14-ce.0 | 18.8 or later |
| 19.2.10-ce.0 | 18.11 or later |
| 19.5.4-ce.0 | 19.2 or later |

## Releasing

Each version is built from its own commit, which pins `FROM` in the
`Dockerfile`, on the dedicated builder:

```bash
docker build --builder default --platform linux/amd64 -t repo.cylo.net/gitlab-ce:<version> .
tests/release-gate.sh repo.cylo.net/gitlab-ce:<version> && docker push repo.cylo.net/gitlab-ce:<version>
```

`tests/release-gate.sh` tests a fresh install (including a password with
`"`, `\`, `'` and `$`), a restart and a rejected setup, then checks that the
tag is not in the registry yet. `tests/upgrade-chain.sh <current-image>
<stop-image>...` installs the current image, adds a project, and steps it
through every stop on the same volumes.
