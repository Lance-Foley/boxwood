#!/bin/sh
set -e

# No database here — just drop the marker the healthcheck looks for.
touch /tmp/.db_initialized
echo ready
