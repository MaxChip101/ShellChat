set -e

DB_NAME="chat_server"

psql -h "$PGHOST" -U postgres -tAc "SELECT 1 FROM pg_database WHERE datame = '$DB_NAME'" | grep -q 1 || \
    psql -h "$PGHOST" -U postgres -c "CREATE DATABASE $DB_NAME"

psql-h "$PGHOST" -U postgres -d "$DB_NAME" -f init.sql

echo "postgresql database created"