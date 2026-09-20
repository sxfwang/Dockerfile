#!/bin/bash
# shellcheck disable=SC1091,SC2155
# LICENSE UPL 1.0
#
# Copyright (c) 2026 Oracle and/or its affiliates. All rights reserved.
#
# Since: September, 2026
# Description: Installs Oracle APEX into the PDB and configures ORDS to serve it
#              on standalone mode (default port 8080). Invoked by runOracle.sh
#              after the database has been created or when an existing oradata
#              volume does not have APEX/ORDS installed yet.
#
# Idempotency: guarded by a checkpoint file in the persistent oradata volume.
#
# Passwords: all APEX/ORDS account passwords default to ORACLE_PWD. They can be
# overridden individually with the following environment variables:
#   APEX_ADMIN_PWD              - APEX Instance ADMIN account
#   APEX_PUBLIC_USER_PWD        - gateway runtime user
#   APEX_LISTENER_PWD           - created by apex_rest_config.sql
#   APEX_REST_PUBLIC_USER_PWD   - created by apex_rest_config.sql
# Note: passwords are expanded inside SQL*Plus heredocs, so avoid the shell
# special characters $, ` and \" in them.
#
# DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS HEADER.

ORACLE_SID="${ORACLE_SID:-ORCLCDB}"
ORACLE_PDB="${ORACLE_PDB:-ORCLPDB1}"
APEX_HOME="${APEX_HOME:-$ORACLE_BASE/apex}"
ORDS_HOME="${ORDS_HOME:-$ORACLE_BASE/ords}"
ORDS_CONFIG="${ORDS_CONFIG:-$ORACLE_BASE/oradata/ords-config}"
ORDS_PORT="${ORDS_PORT:-8080}"
CHECKPOINT_FILE_EXTN="${CHECKPOINT_FILE_EXTN:-.created}"
APEX_ORDS_CHECKPOINT="${ORACLE_BASE}/oradata/.${ORACLE_SID}.apexords${CHECKPOINT_FILE_EXTN}"
ORDS_BIN="${ORDS_HOME}/bin/ords"

function checkError {
   ret=$?
   if [ "$ret" -ne 0 ]; then
      echo "ERROR: $1 (exit code: $ret)"
      exit "$ret"
   fi;
}

# Idempotency guard: skip if APEX/ORDS have already been installed
if [ -f "$APEX_ORDS_CHECKPOINT" ]; then
   echo "APEX/ORDS are already installed. Skipping installation."
   exit 0
fi

if [ ! -d "$APEX_HOME" ]; then
   echo "ERROR: APEX home directory not found at $APEX_HOME. Exiting..."
   exit 1
fi

if [ ! -x "$ORDS_BIN" ]; then
   echo "ERROR: ORDS binary not found at $ORDS_BIN. Exiting..."
   exit 1
fi

echo "##############################"
echo "# Installing APEX and ORDS   #"
echo "##############################"

# ---------------------------------------------------------------------------
# Password resolution
# ---------------------------------------------------------------------------
# DBCA -autoGeneratePasswords scenario: ORACLE_PWD is unknown to the image, so
# generate a strong random password and reset SYS to allow ORDS to connect.
if [ -z "${ORACLE_PWD:-}" ]; then
   ORACLE_PWD="Aa1$(openssl rand -hex 10)"
   echo "ORACLE_PWD is not set. Generating a random password and resetting SYS."
   sqlplus -s / as sysdba <<EOF
ALTER USER SYS IDENTIFIED BY "${ORACLE_PWD}";
exit;
EOF
   checkError "Unable to reset the SYS password"
fi
export ORACLE_PWD

APEX_ADMIN_PWD="${APEX_ADMIN_PWD:-$ORACLE_PWD}"
APEX_PUBLIC_USER_PWD="${APEX_PUBLIC_USER_PWD:-$ORACLE_PWD}"
APEX_LISTENER_PWD="${APEX_LISTENER_PWD:-$ORACLE_PWD}"
APEX_REST_PUBLIC_USER_PWD="${APEX_REST_PUBLIC_USER_PWD:-$ORACLE_PWD}"

# ---------------------------------------------------------------------------
# Step 1: Check if APEX is already installed, install if not
#         Oracle Database 26ai ships with APEX pre-installed (APEX_260100).
# ---------------------------------------------------------------------------
APEX_SCHEMA_COUNT=$(sqlplus -s / as sysdba <<EOF
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF
ALTER SESSION SET CONTAINER=${ORACLE_PDB};
SELECT COUNT(*) FROM dba_users WHERE username LIKE 'APEX_%';
exit;
EOF
)

# Trim whitespace
APEX_SCHEMA_COUNT=$(echo "$APEX_SCHEMA_COUNT" | tr -d '[:space:]')

if [ "${APEX_SCHEMA_COUNT:-0}" -gt 0 ] 2>/dev/null; then
   echo "APEX is already installed in ${ORACLE_PDB} (found ${APEX_SCHEMA_COUNT} APEX schemas)."
   echo "Skipping APEX schema installation."
else
   echo "Installing APEX into PDB ${ORACLE_PDB} (this may take 10-30 minutes)..."
   cd "$APEX_HOME" || exit 1
   sqlplus -s / as sysdba <<EOF
SET DEFINE OFF
WHENEVER SQLERROR EXIT SQL.SQLCODE
ALTER SESSION SET CONTAINER=${ORACLE_PDB};
@apexins.sql SYSAUX SYSAUX TEMP /i/
exit;
EOF
   checkError "APEX installation failed"
fi

# ---------------------------------------------------------------------------
# Step 2: Create or reset the APEX Instance ADMIN account
#         Use the PL/SQL API directly for better error handling.
# ---------------------------------------------------------------------------
echo "Creating the APEX Instance ADMIN account..."
# Determine the APEX schema name dynamically
APEX_SCHEMA=$(sqlplus -s / as sysdba <<EOF2
SET PAGESIZE 0 FEEDBACK OFF VERIFY OFF HEADING OFF
ALTER SESSION SET CONTAINER=${ORACLE_PDB};
SELECT username FROM dba_users WHERE username LIKE 'APEX_%' AND username NOT LIKE '%_FILES' AND username NOT LIKE '%_ROUTER' AND rownum = 1;
exit;
EOF2
)
APEX_SCHEMA=$(echo "$APEX_SCHEMA" | tr -d '[:space:]')

if [ -z "$APEX_SCHEMA" ]; then
   echo "Warning: Could not determine APEX schema name. Skipping ADMIN account creation."
else
   echo "APEX schema: $APEX_SCHEMA"
   sqlplus -s / as sysdba <<EOF
SET DEFINE OFF
WHENEVER SQLERROR CONTINUE
ALTER SESSION SET CONTAINER=${ORACLE_PDB};
ALTER SESSION SET CURRENT_SCHEMA = ${APEX_SCHEMA};
BEGIN
    wwv_flow_instance_admin.create_or_update_admin_user (
        p_username => 'ADMIN',
        p_email => 'admin@localhost',
        p_password => '${APEX_ADMIN_PWD}');
    COMMIT;
END;
/
exit;
EOF
fi
echo "APEX Instance ADMIN account configured."

# ---------------------------------------------------------------------------
# Step 3: Unlock and set passwords for APEX_PUBLIC_USER and REST users
#         These may already exist (pre-installed) or need to be created.
# ---------------------------------------------------------------------------
echo "Configuring APEX REST services users..."
sqlplus -s / as sysdba <<EOF
SET DEFINE OFF
WHENEVER SQLERROR CONTINUE
ALTER SESSION SET CONTAINER=${ORACLE_PDB};

-- Unlock and set password for APEX_PUBLIC_USER
BEGIN
    EXECUTE IMMEDIATE 'ALTER USER APEX_PUBLIC_USER IDENTIFIED BY "${APEX_PUBLIC_USER_PWD}" ACCOUNT UNLOCK';
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('APEX_PUBLIC_USER: ' || SQLERRM);
END;
/

-- Unlock and set password for APEX_LISTENER
BEGIN
    EXECUTE IMMEDIATE 'ALTER USER APEX_LISTENER IDENTIFIED BY "${APEX_LISTENER_PWD}" ACCOUNT UNLOCK';
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('APEX_LISTENER: ' || SQLERRM);
END;
/

-- Unlock and set password for APEX_REST_PUBLIC_USER
BEGIN
    EXECUTE IMMEDIATE 'ALTER USER APEX_REST_PUBLIC_USER IDENTIFIED BY "${APEX_REST_PUBLIC_USER_PWD}" ACCOUNT UNLOCK';
EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('APEX_REST_PUBLIC_USER: ' || SQLERRM);
END;
/
exit;
EOF
echo "APEX REST services users configured."

# ---------------------------------------------------------------------------
# Step 4: Configure ORDS standalone settings
# ---------------------------------------------------------------------------
# Clear any stale ORDS config from a previous failed install
rm -rf "$ORDS_CONFIG"
mkdir -p "$ORDS_CONFIG/logs" || exit 1

# ---------------------------------------------------------------------------
# Step 5: Install ORDS into the PDB (creates ORDS_METADATA and ORDS_PUBLIC_USER)
#         Install first without gateway mode, configure it after.
# ---------------------------------------------------------------------------
echo "Installing ORDS into PDB ${ORACLE_PDB}..."
printf '%s\n' "$ORACLE_PWD" | "$ORDS_BIN" --config "$ORDS_CONFIG" install \
   --admin-user SYS \
   --db-hostname localhost \
   --db-port 1521 \
   --db-servicename "$ORACLE_PDB" \
   --feature-db-api true \
   --feature-rest-enabled-sql true \
   --feature-sdw true \
   --log-folder "$ORDS_CONFIG/logs" \
   --password-stdin
checkError "ORDS installation failed"

# ---------------------------------------------------------------------------
# Step 6: Configure ORDS standalone settings (after install succeeds)
# ---------------------------------------------------------------------------
echo "Configuring ORDS (config dir: $ORDS_CONFIG)..."
"$ORDS_BIN" --config "$ORDS_CONFIG" config set standalone.static.path "$APEX_HOME/images" || exit 1
"$ORDS_BIN" --config "$ORDS_CONFIG" config set standalone.context.path "/ords" || exit 1
"$ORDS_BIN" --config "$ORDS_CONFIG" config set standalone.http.port "$ORDS_PORT" || exit 1
"$ORDS_BIN" --config "$ORDS_CONFIG" config set plsql.gateway.mode proxied || exit 1

# ---------------------------------------------------------------------------
# Step 6: Write the checkpoint file
# ---------------------------------------------------------------------------
echo "$(date -Iseconds)" > "$APEX_ORDS_CHECKPOINT"

echo "#######################################"
echo "APEX AND ORDS WERE INSTALLED SUCCESSFULLY!"
echo "APEX URL        : http://localhost:${ORDS_PORT}/ords/apex"
echo "SQL Developer Web: http://localhost:${ORDS_PORT}/ords/sql-developer"
echo "ADMIN password  : \$APEX_ADMIN_PWD (default: \$ORACLE_PWD)"
echo "#######################################"
