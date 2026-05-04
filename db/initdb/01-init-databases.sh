#!/bin/bash
set -e


IFS=',' read -ra ENTRIES <<< "$CREDENTIALS"

for entry in "${ENTRIES[@]}"; do
  IFS=":" read -r DB_NAME DB_USER DB_PASSWORD <<< "$entry"

  psql -v ON_ERROR_STOP=1 \
       --username "$POSTGRES_USER" \
       --dbname "$POSTGRES_DB" <<-EOSQL
    DO
    \$\$
    BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$DB_USER') THEN
        CREATE USER "$DB_USER" WITH PASSWORD '$DB_PASSWORD';
      END IF;
    END
    \$\$;

    CREATE DATABASE "$DB_NAME" OWNER "$DB_USER";
EOSQL

done