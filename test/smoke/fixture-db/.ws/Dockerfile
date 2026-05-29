# Tier-2 smoke fixture — minimal image WITH a database dependency.
# Still alpine-tiny so `ws rebuild` finishes in seconds; the postgres-client
# is needed because db-init.sh waits on the db service with pg_isready.
FROM alpine:latest

# postgresql-client provides pg_isready for the db-init wait loop.
RUN apk add --no-cache postgresql-client

# docker-entrypoint.sh runs db-init.sh when DB_INIT=true, then execs the CMD.
COPY docker-entrypoint.sh db-init.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh /usr/local/bin/db-init.sh

ENTRYPOINT ["docker-entrypoint.sh"]
# Keep the container alive so compose healthchecks have something to probe.
CMD ["tail", "-f", "/dev/null"]
