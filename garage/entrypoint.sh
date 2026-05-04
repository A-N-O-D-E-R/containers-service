#!/bin/sh
set -e

/garage server &
SERVER_PID=$!

# Wait for the server to be ready
until /garage status > /dev/null 2>&1; do
  sleep 1
done

# Apply layout if not already done (version 0 = no nodes assigned yet)
if /garage layout show 2>&1 | grep -q "version: 0"; then
  NODE_ID=$(/garage status 2>/dev/null | awk '/^[0-9a-f]/ {print $1; exit}')
  /garage layout assign -z dc1 -c 1G "$NODE_ID"
  /garage layout apply --version 1
fi

# Create buckets listed in GARAGE_BUCKETS (space or comma separated)
if [ -n "$GARAGE_BUCKETS" ]; then
  echo "$GARAGE_BUCKETS" | tr ',\ ' '\n' | grep -v '^$' | while read -r bucket; do
    if ! /garage bucket list | grep -qx "$bucket"; then
      /garage bucket create "$bucket"
    fi
  done
fi

# Create default key if no keys exist yet
if [ -z "$(/garage key list | awk 'NR>1 {print $1; exit}')" ]; then
  /garage key create --help
  /garage key create default-key 
  /garage key allow --create-bucket default-key
  /garage bucket list | awk 'NR>1 {print $1}' | while read -r bucket; do
    /garage bucket allow "$bucket" --key default-key --read --write
  done
fi

wait $SERVER_PID
