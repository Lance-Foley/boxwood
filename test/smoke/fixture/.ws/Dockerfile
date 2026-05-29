# Tier-2 smoke fixture — minimal no-DB image.
# Deliberately tiny (alpine) so `ws rebuild` finishes in seconds.
FROM alpine:latest

# docker-entrypoint.sh runs db-init.sh when DB_INIT=true, then execs the CMD.
COPY docker-entrypoint.sh db-init.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh /usr/local/bin/db-init.sh

ENTRYPOINT ["docker-entrypoint.sh"]
# Keep the container alive so compose healthchecks have something to probe.
CMD ["tail", "-f", "/dev/null"]
