#!/usr/bin/env bash

set -euo pipefail

target="${1:-}"
root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ "${target}" != "be" && "${target}" != "ai" && "${target}" != "qdrant" ]]; then
  echo "Usage: $0 <be|ai|qdrant>" >&2
  exit 1
fi

target_dir="${root_dir}/${target}"
env_file="${target_dir}/.env"
compose_file="${target_dir}/docker-compose.yml"

if [[ ! -f "${env_file}" ]]; then
  echo "Missing runtime environment file: ${env_file}" >&2
  exit 1
fi

echo "Deploy target: ${target}"
echo "Compose file: ${compose_file}"
echo "Env file: ${env_file}"

docker compose \
  --env-file "${env_file}" \
  --file "${compose_file}" \
  config --quiet

docker compose \
  --env-file "${env_file}" \
  --file "${compose_file}" \
  pull

docker compose \
  --env-file "${env_file}" \
  --file "${compose_file}" \
  up -d --remove-orphans

docker compose \
  --env-file "${env_file}" \
  --file "${compose_file}" \
  ps
