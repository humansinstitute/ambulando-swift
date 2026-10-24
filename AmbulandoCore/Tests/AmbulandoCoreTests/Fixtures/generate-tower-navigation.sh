#!/bin/sh
# Runs generate-tower-navigation.ts against a Tower checkout. Tower's config module refuses to load without these
# settings; the serializers never use them, so placeholders (and the public NIP-19 test npub) are passed, and no .env is read.
# Usage: sh generate-tower-navigation.sh <path-to-tower> > tower-navigation.json
set -eu
here=$(cd "$(dirname "$0")" && pwd)
p=placeholder
test_npub=npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg
exec env SUPERBASED_DIRECT_HTTPS_URL=https://placeholder.invalid STORAGE_S3_ENDPOINT_PUBLIC=https://placeholder.invalid \
  STORAGE_S3_ACCESS_KEY=$p STORAGE_S3_SECRET_KEY=$p DB_USER=$p DB_PASSWORD=$p \
  GRAPH_DB_ADMIN_USER=$p GRAPH_DB_ADMIN_PASSWORD=$p GRAPH_DB_APP_USER=$p GRAPH_DB_APP_PASSWORD=$p \
  ADMIN_NPUB=$test_npub FLIGHT_DECK_PG_APP_NPUB=$test_npub \
  bun --no-env-file "$here/generate-tower-navigation.ts" "$1"
