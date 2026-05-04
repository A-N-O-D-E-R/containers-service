#!/bin/bash
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE USER zabbix WITH PASSWORD '${ZABBIX_DB_PASSWORD}';
    CREATE DATABASE zabbix OWNER zabbix;
EOSQL
