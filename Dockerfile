FROM gitlab/gitlab-ce:18.2.2-ce.0

RUN groupmod -g 9999 nogroup
RUN usermod -g 9999 nobody
RUN usermod -u 9999 nobody
RUN usermod -g 9999 sshd
RUN usermod -g 9999 sync

ADD scripts /scripts
ADD sshd_config /etc/ssh/sshd_config
RUN chmod -R +x /scripts

CMD ["/assets/init-container"]

ENTRYPOINT ["/scripts/entrypoint.sh"]

HEALTHCHECK --interval=60s --timeout=30s --retries=5 \
CMD /opt/gitlab/bin/gitlab-healthcheck --fail --max-time 10
