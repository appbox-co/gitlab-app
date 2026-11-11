# Upgrade stops: GitLab must pass through 18.5, 18.8, 18.11 and 19.2 on the
# way from 18.2 to 19.5. Release each stop as its own image and version;
# see README.md.
FROM gitlab/gitlab-ce:18.5.7-ce.0

RUN groupmod -g 9999 nogroup
RUN usermod -g 9999 nobody
RUN usermod -u 9999 nobody
RUN usermod -g 9999 sshd
RUN usermod -g 9999 sync

ADD scripts /scripts
ADD sshd_config /etc/ssh/sshd_config
RUN chmod -R +x /scripts

# init-container runs this after `gitlab-ctl reconfigure`.
ENV GITLAB_POST_RECONFIGURE_SCRIPT=/scripts/appbox-post-reconfigure

CMD ["/assets/init-container"]

ENTRYPOINT ["/scripts/entrypoint.sh"]

HEALTHCHECK --interval=60s --timeout=30s --retries=5 \
CMD /opt/gitlab/bin/gitlab-healthcheck --fail --max-time 10
