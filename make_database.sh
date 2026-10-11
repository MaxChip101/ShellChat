set -euo pipefail

DB_NAME="${DB_NAME:-chat_server}"

if ! psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'" | grep -q 1; then
    createdb "$DB_NAME"
fi

psql -v ON_ERROR_STOP=1 -d "$DB_NAME" -f init.sql

echo "database $DB_NAME ready"
