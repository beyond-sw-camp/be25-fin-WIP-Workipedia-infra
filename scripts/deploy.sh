#!/usr/bin/env bash

set -euo pipefail

target="${1:-}"
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "${target}" != "be" && "${target}" != "ai" ]]; then
  echo "Usage: $0 <be|ai>" >&2
  exit 1
fi

target_dir="${root_dir}/${target}"
env_file="${target_dir}/.env"

if [[ ! -f "${env_file}" ]]; then
  echo "Missing runtime environment file: ${env_file}" >&2
  exit 1
fi

docker compose \
  --env-file "${env_file}" \
  --file "${target_dir}/docker-compose.yml" \
  config --quiet

docker compose \
  --env-file "${env_file}" \
  --file "${target_dir}/docker-compose.yml" \
  pull

docker compose \
  --env-file "${env_file}" \
  --file "${target_dir}/docker-compose.yml" \
  up -d --remove-orphans

docker compose \
  --env-file "${env_file}" \
  --file "${target_dir}/docker-compose.yml" \
  ps
