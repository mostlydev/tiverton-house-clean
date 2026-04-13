#!/bin/bash
set -euo pipefail

# Hermes loads $HERMES_HOME/.env itself on startup.
# "hermes gateway" stays in the foreground, which is what Docker needs.
exec hermes gateway
