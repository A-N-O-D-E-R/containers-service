#!/bin/bash
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE USER forgejo WITH PASSWORD '${FORGEJO_DB_PASSWORD}';
    CREATE DATABASE forgejo OWNER forgejo;
EOSQL
