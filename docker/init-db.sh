#!/usr/bin/env bash
set -euo pipefail

MARKER_DIR="${INIT_MARKER_DIR:-/var/lib/turtle-init}"
MARKER_FILE="${MARKER_DIR}/initialized"
SQL_ROOT="${SQL_DIR:-/opt/turtle/sql}"

DB_HOST="${DB_HOST:-db}"
DB_PORT="${DB_PORT:-3306}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}"
DB_USER="${DB_USER:-mangos}"
DB_PASSWORD="${DB_PASSWORD:-mangos}"
DB_LOGIN="${DB_LOGIN:-tw_logon}"
DB_WORLD="${DB_WORLD:-tw_world}"
DB_CHAR="${DB_CHAR:-tw_char}"
DB_LOGS="${DB_LOGS:-tw_logs}"

REALM_NAME="${REALM_NAME:-TurtleWoW}"
REALM_ADDRESS="${REALM_ADDRESS:-127.0.0.1}"
WORLD_PORT="${WORLD_PORT:-8090}"
REALM_ID="${REALM_ID:-1}"

PLAYERBOTS_BUILT="${PLAYERBOTS_BUILT:-ON}"

if [[ -z "${DB_ROOT_PASSWORD}" ]]; then
  echo "DB_ROOT_PASSWORD (or MYSQL_ROOT_PASSWORD) is required." >&2
  exit 1
fi

mysql_root() {
  mysql -h"${DB_HOST}" -P"${DB_PORT}" -uroot -p"${DB_ROOT_PASSWORD}" --protocol=TCP "$@"
}

echo "Waiting for MariaDB at ${DB_HOST}:${DB_PORT}..."
for i in $(seq 1 90); do
  if mysql_root -e "SELECT 1" &>/dev/null; then
    break
  fi
  if [[ "${i}" -eq 90 ]]; then
    echo "MariaDB did not become ready in time." >&2
    exit 1
  fi
  sleep 2
done
echo "MariaDB is ready."

if [[ -f "${MARKER_FILE}" ]]; then
  echo "Init marker found (${MARKER_FILE}); skipping database import."
  exit 0
fi

if [[ ! -f "${SQL_ROOT}/create_databases.sql" ]]; then
  echo "Missing ${SQL_ROOT}/create_databases.sql" >&2
  exit 1
fi

echo "Creating databases and base schemas..."
mysql_root < "${SQL_ROOT}/create_databases.sql"

# BackupCharacterInventory copies rows with INSERT ... SELECT * and therefore
# requires a structurally identical snapshot table in the character database.
character_inventory_copy_sql="${SQL_ROOT}/character-inventory-copy.sql"
if [[ ! -f "${character_inventory_copy_sql}" ]]; then
  echo "Missing ${character_inventory_copy_sql}" >&2
  exit 1
fi
echo "Ensuring character_inventory_copy exists..."
mysql_root "${DB_CHAR}" < "${character_inventory_copy_sql}"

echo "Creating application user '${DB_USER}' and grants..."
mysql_root <<SQL
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DB_LOGIN}\`.* TO '${DB_USER}'@'%';
GRANT ALL PRIVILEGES ON \`${DB_WORLD}\`.* TO '${DB_USER}'@'%';
GRANT ALL PRIVILEGES ON \`${DB_CHAR}\`.* TO '${DB_USER}'@'%';
GRANT ALL PRIVILEGES ON \`${DB_LOGS}\`.* TO '${DB_USER}'@'%';
FLUSH PRIVILEGES;
SQL

echo "Importing world content from sql/base (this can take several minutes)..."
shopt -s nullglob
base_files=("${SQL_ROOT}"/base/*.sql)
if [[ "${#base_files[@]}" -eq 0 ]]; then
  echo "No SQL files found under ${SQL_ROOT}/base" >&2
  exit 1
fi
for f in "${base_files[@]}"; do
  echo "  -> $(basename "${f}")"
  mysql_root "${DB_WORLD}" < "${f}"
done

echo "Applying database_updates with --force (duplicate keys expected)..."

# Find all .sql files, count directory depth, sort deepest first (then alphabetically), and process.
# character/ holds character-DB migrations, so it is applied to DB_CHAR below, not to the world DB.
find "${SQL_ROOT}/database_updates" -type f -name "*.sql" -not -path "*/character/*" \
  | awk -F'/' '{print NF, $0}' \
  | sort -k1,1nr -k2 \
  | cut -d' ' -f2- \
  | while IFS= read -r f; do
      echo "  -> $(basename "${f}")"
      mysql_root --force "${DB_WORLD}" < "${f}" || true
    done
for f in "${SQL_ROOT}"/database_updates/character/*.sql; do
  [[ -f "${f}" ]] || continue
  echo "  -> $(basename "${f}") (character)"
  mysql_root --force "${DB_CHAR}" < "${f}" || true
done

# AutoUpdater keys applied rows by file SHA1 (not by name). Hash 'manual'
# never matches, so mangosd would retry every update and die on duplicates.
# Record exactly what it scans: database_updates/world against the world DB and
# database_updates/character against the character DB (Database.AutoUpdate.Path
# plus the WorldUpdateName/CharUpdateName folders). Top-level files are not scanned.
echo "Recording migrations as applied (SHA1 hashes)..."
record_migrations() {
  local db="$1" dir="$2" f n h
  # Same schema mangosd's AutoUpdater creates, so this also works on a DB it has not touched yet.
  mysql_root -e "CREATE TABLE IF NOT EXISTS ${db}.migrations (
    Id INT(10) UNSIGNED NOT NULL AUTO_INCREMENT,
    Name VARCHAR(255) NOT NULL DEFAULT '0' COLLATE 'utf8_general_ci',
    Module VARCHAR(255) NOT NULL DEFAULT '' COLLATE 'utf8_general_ci',
    Hash VARCHAR(128) NOT NULL DEFAULT '0' COLLATE 'utf8_general_ci',
    AppliedAt DATETIME NOT NULL,
    PRIMARY KEY (Id) USING BTREE) COLLATE='utf8_general_ci' ENGINE=InnoDB;"
  mysql_root -e "DELETE FROM ${db}.migrations;"
  for f in "${dir}"/*.sql; do
    [[ -f "${f}" ]] || continue
    n="$(basename "${f}" .sql)"
    h="$(sha1sum "${f}" | awk '{ print toupper($1) }')"
    mysql_root -e "INSERT INTO ${db}.migrations (Name, Hash, AppliedAt) VALUES ('${n}','${h}',NOW());"
  done
}
record_migrations "${DB_WORLD}" "${SQL_ROOT}/database_updates/world"
record_migrations "${DB_CHAR}" "${SQL_ROOT}/database_updates/character"

# Verify a known schema change from migrations landed.
col_count="$(mysql_root -N -e "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='${DB_WORLD}' AND TABLE_NAME='spell_template' AND COLUMN_NAME='script_name';")"
if [[ "${col_count}" != "1" ]]; then
  echo "WARNING: spell_template.script_name not found after migrations (got count=${col_count})." >&2
  exit 0
fi

# Playerbot tables (only when this image was built with BUILD_PLAYERBOTS=ON)
normalized="$(echo "${PLAYERBOTS_BUILT}" | tr '[:lower:]' '[:upper:]')"
if [[ "${normalized}" == "ON" || "${normalized}" == "1" || "${normalized}" == "TRUE" ]]; then
  PB_SQL="${SQL_ROOT}/playerbots"
  if [[ -d "${PB_SQL}" ]]; then
    echo "Importing playerbots world SQL..."
    cat "${PB_SQL}"/world/*.sql "${PB_SQL}"/world/classic/*.sql | mysql_root "${DB_WORLD}"
    echo "Importing playerbots characters SQL..."
    cat "${PB_SQL}"/characters/*.sql | mysql_root "${DB_CHAR}"
  else
    echo "PLAYERBOTS_BUILT=${PLAYERBOTS_BUILT} but ${PB_SQL} is missing." >&2
    exit 1
  fi
else
  echo "Skipping playerbots SQL (PLAYERBOTS_BUILT=${PLAYERBOTS_BUILT})."
fi

echo "Inserting realmlist row..."
mysql_root <<SQL
DELETE FROM ${DB_LOGIN}.realmlist;
INSERT INTO ${DB_LOGIN}.realmlist
  (id, name, address, port, icon, realmflags, timezone, allowedSecurityLevel, realmbuilds)
VALUES
  (${REALM_ID}, '${REALM_NAME}', '${REALM_ADDRESS}', ${WORLD_PORT}, 0, 0, 1, 0, '7272');
SQL

mkdir -p "${MARKER_DIR}"
date -u +"%Y-%m-%dT%H:%M:%SZ" > "${MARKER_FILE}"
echo "Database init complete."
