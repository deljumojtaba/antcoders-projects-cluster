#!/usr/bin/env bash
#
# Creates the `ghcr-pull` image pull secret in every app namespace. Needs a
# GitHub classic token with only the read:packages scope.
#
#   GHCR_USER=deljumojtaba GHCR_TOKEN=ghp_... ./scripts/create-ghcr-pull.sh
set -euo pipefail

source "$(dirname "$0")/../scripts/lib.sh"
use_antcoders_cluster
: "${GHCR_USER:?set GHCR_USER}"
: "${GHCR_TOKEN:?set GHCR_TOKEN (read:packages only)}"

for ns in game kinmemo assist web marketing; do
  kubectl -n "$ns" create secret docker-registry ghcr-pull \
    --docker-server=ghcr.io \
    --docker-username="$GHCR_USER" \
    --docker-password="$GHCR_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -
done
