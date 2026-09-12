#!/bin/sh
set -eu

COMPOSE_FILE="database/tests/docker-compose.pipeline-db.yml"
COMPOSE_PROJECT="kiko-pipeline-t02"
export PIPELINE_TEST_DATABASE_URL="${PIPELINE_TEST_DATABASE_URL:-postgres://pipeline_admin:pipeline_test_only@127.0.0.1:15432/kiko_pipeline_test}"

docker compose -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" up -d --wait
trap 'docker compose -p "$COMPOSE_PROJECT" -f "$COMPOSE_FILE" down --volumes' EXIT INT TERM
corepack pnpm vitest run --no-file-parallelism tests/pipeline-db "$@"
