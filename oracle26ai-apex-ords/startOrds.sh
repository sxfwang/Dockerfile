#!/bin/bash
# shellcheck disable=SC2155
# LICENSE UPL 1.0
#
# Copyright (c) 2026 Oracle and/or its affiliates. All rights reserved.
#
# Since: September, 2026
# Description: Starts ORDS in standalone mode in the background after the
#              database is ready. Invoked by runOracle.sh on every container
#              startup once APEX/ORDS have been installed (installApexOrds.sh).
#
# DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS HEADER.

ORDS_HOME="${ORDS_HOME:-$ORACLE_BASE/ords}"
ORDS_CONFIG="${ORDS_CONFIG:-$ORACLE_BASE/oradata/ords-config}"
ORDS_PORT="${ORDS_PORT:-8080}"
ORDS_LOG_DIR="${ORACLE_BASE}/ords/logs"
ORDS_PID_FILE="/tmp/ords.pid"
ORDS_BIN="${ORDS_HOME}/bin/ords"

if [ ! -x "$ORDS_BIN" ]; then
   echo "ERROR: ORDS binary not found at $ORDS_BIN. Exiting..."
   exit 1
fi

# Already running (e.g. a scripted restart)? Then there is nothing to do.
if [ -f "$ORDS_PID_FILE" ] && kill -0 "$(cat "$ORDS_PID_FILE")" 2>/dev/null; then
   echo "ORDS is already running (pid $(cat "$ORDS_PID_FILE"))."
   exit 0
fi

mkdir -p "$ORDS_LOG_DIR"

echo "Starting ORDS on port ${ORDS_PORT}..."
nohup "$ORDS_BIN" --config "$ORDS_CONFIG" serve > "$ORDS_LOG_DIR/serve.log" 2>&1 &
echo $! > "$ORDS_PID_FILE"

# Best-effort readiness probe: wait up to ~90s. Non-fatal on timeout,
# the ORDS log is available for troubleshooting.
for _ in $(seq 1 30); do
   if curl -so /dev/null "http://localhost:${ORDS_PORT}/ords/"; then
      echo "ORDS is ready and listening on port ${ORDS_PORT}."
      break
   fi
   sleep 3
done

echo "ORDS log: ${ORDS_LOG_DIR}/serve.log"
