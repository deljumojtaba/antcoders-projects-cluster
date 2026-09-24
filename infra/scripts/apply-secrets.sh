#!/usr/bin/env bash
#
# Decrypts every secrets/**/*.yaml with SOPS and applies it. Plaintext never
# touches the disk. Templates (*.example.yaml) are skipped.
#
#   export SOPS_AGE_KEY_FILE=~/.config/sops/age/antcoders.txt
#   ./scripts/apply-secrets.sh              # all
#   ./scripts/apply-secrets.sh game         # one namespace folder
set -euo pipefail

INFRA="$(cd "$(dirname "$0")/.." && pwd)"
source "$(dirname "$0")/../scripts/lib.sh"
use_antcoders_cluster

find "$INFRA/secrets/${1:-}" -name '*.yaml' ! -name '*.example.yaml' | sort | while read -r f; do
  if ! grep -q '^sops:' "$f"; then
    echo "REFUSING $f: not encrypted. Run: sops -e -i $f" >&2
    exit 1
  fi
  echo "==> ${f#$INFRA/}"
  sops -d "$f" | kubectl apply -f -
done
