#!/bin/bash
set -e

IFS=',' read -ra ENTRIES <<< "$NOSQL_CREDENTIALS"

for entry in "${ENTRIES[@]}"; do
  IFS=":" read -r DB_NAME DB_USER DB_PASSWORD <<< "$entry"

  mongosh --username "$MONGO_INITDB_ROOT_USERNAME" \
          --password "$MONGO_INITDB_ROOT_PASSWORD" \
          --authenticationDatabase admin \
          --eval "
    const db = db.getSiblingDB('$DB_NAME');
    if (!db.getUser('$DB_USER')) {
      db.createUser({
        user: '$DB_USER',
        pwd: '$DB_PASSWORD',
        roles: [{ role: 'readWrite', db: '$DB_NAME' }]
      });
    }
  "
done
