#!/bin/sh
set -e

sed "s|\${GARAGE_RPC_SECRET}|${GARAGE_RPC_SECRET}|g" /etc/garage.toml.tpl > /tmp/garage.toml
G="/garage -c /tmp/garage.toml"

$G server &
SERVER_PID=$!

until $G status > /dev/null 2>&1; do
  sleep 1
done

if $G layout show 2>&1 | grep -q "version: 0"; then
  NODE_ID=$($G status 2>/dev/null | awk '/^[0-9a-f]/ {print $1; exit}')
  $G layout assign -z dc1 -c 1G "$NODE_ID"
  $G layout apply --version 1
fi

if [ -n "$GARAGE_BUCKETS" ]; then
  echo "$GARAGE_BUCKETS" | tr ',\ ' '\n' | grep -v '^$' | while read -r bucket; do
    if ! $G bucket list | grep -qx "$bucket"; then
      $G bucket create "$bucket"
    fi
  done
fi

if [ -z "$($G key list | awk 'NR>1 {print $1; exit}')" ]; then
  $G key create default-key
  $G key allow --create-bucket default-key
  $G bucket list | awk 'NR>1 {print $1}' | while read -r bucket; do
    $G bucket allow "$bucket" --key default-key --read --write
  done
fi

wait $SERVER_PID
