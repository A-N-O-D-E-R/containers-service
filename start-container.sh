#!/bin/bash

set -euo pipefail

# Determine script directory safely
script_path=$(realpath "$0")
dir=$(dirname "$script_path")

# Check for required argument
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <app-name>"
  exit 1
fi

app="$1"
compose_file="$dir/$app/docker-compose.yaml"

# Check for sudo privileges
if ! sudo -n true 2>/dev/null; then
  echo "Error: This script requires sudo privileges. Please run as a user with sudo access."
  exit 1
fi

# Check for required tools
if ! command -v docker &>/dev/null; then
  echo "Error: Docker is not installed or not in PATH."
  exit 1
fi

if ! command -v docker-compose &>/dev/null && ! docker compose version &>/dev/null; then
  echo "Error: Docker Compose is not available."
  exit 1
fi

# Check if docker-compose.yaml exists
if [[ ! -f "$compose_file" ]]; then
  echo "Error: Compose file not found at '$compose_file'"
  exit 1
fi

# Run Docker Compose
echo "Starting Docker Compose for '$app'..."
sudo docker compose -p "$app" -f "$compose_file" up -d
