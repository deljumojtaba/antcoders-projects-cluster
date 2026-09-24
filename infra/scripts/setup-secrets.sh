#!/usr/bin/env bash
#
# Creates the secrets needed BEFORE migration, encrypted with SOPS:
#   traefik/    the 3 Cloudflare Origin certificates
#   game, data  R2 backup credentials
#   game, data  database role passwords (generated here, you never type them)
#   monitoring  Grafana admin password (generated)
#
# Run it in your own terminal. It asks for values with hidden input and never
# prints them. Existing secret files are left alone, so it is safe to re-run.
#
#   ./scripts/setup-secrets.sh
#
# The app secrets (kelime-config-seed, kinmemo-env, assist-env) come later, in
# each project's migration step, because they need values from the old servers.
set -euo pipefail

cd "$(dirname "$0")/.."
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/antcoders.txt}"

command -v sops >/dev/null || { echo "install sops: brew install sops" >&2; exit 1; }
command -v kubectl >/dev/null || { echo "install kubectl" >&2; exit 1; }
[[ -f "$SOPS_AGE_KEY_FILE" ]] || { echo "no age key at $SOPS_AGE_KEY_FILE" >&2; exit 1; }
grep -q 'AGE_PUBLIC_KEY_HERE' .sops.yaml && { echo "put your age public key in .sops.yaml first" >&2; exit 1; }

umask 077

# write <path>: reads YAML on stdin, writes it to <path>, encrypts in place.
# If encryption fails the plaintext file is removed.
write() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path"
  if ! sops -e -i "$path"; then
    rm -f "$path"
    echo "encryption failed for $path" >&2
    exit 1
  fi
  echo "  created $path"
}

exists() { [[ -f "$1" ]] && { echo "  exists  $1 (skipped)"; return 0; } || return 1; }

pw() { openssl rand -hex 24; }

echo "==> Cloudflare Origin certificates"
echo "    Save each certificate and private key from Cloudflare as two files first"
echo "    (for example ~/secure/kelimesavasi.crt and ~/secure/kelimesavasi.key)."
for zone in kelimesavasi kinmemo antcoders; do
  f="secrets/traefik/tls-$zone.yaml"
  exists "$f" && continue
  read -r -p "    $zone certificate file (.crt/.pem): " crt
  read -r -p "    $zone private key file (.key):      " key
  crt="${crt/#\~/$HOME}"; key="${key/#\~/$HOME}"
  [[ -f "$crt" && -f "$key" ]] || { echo "file not found" >&2; exit 1; }
  grep -q 'BEGIN CERTIFICATE' "$crt" || { echo "$crt is not a PEM certificate" >&2; exit 1; }
  grep -q 'PRIVATE KEY' "$key" || { echo "$key is not a PEM private key" >&2; exit 1; }
  kubectl create secret tls "tls-$zone" -n traefik --cert="$crt" --key="$key" \
    --dry-run=client -o yaml | write "$f"
done

echo "==> Cloudflare R2 (bucket antcoders-backups)"
if [[ ! -f secrets/game/r2-credentials.yaml || ! -f secrets/data/r2-credentials.yaml ]]; then
  echo "    Use the S3 credentials, NOT the token value (cfat_...)."
  read -r -s -p "    R2 Access Key ID (32 characters): " r2id; echo
  read -r -s -p "    R2 Secret Access Key (64 characters): " r2secret; echo
  if [[ ${#r2id} -ne 32 || ${#r2secret} -ne 64 ]]; then
    echo "    Wrong lengths (got ${#r2id} and ${#r2secret}, expected 32 and 64)." >&2
    echo "    The Access Key ID is the token's ID; the Secret Access Key is the SHA-256 of its value." >&2
    exit 1
  fi
  for ns in game data; do
    f="secrets/$ns/r2-credentials.yaml"
    exists "$f" && continue
    kubectl create secret generic r2-credentials -n "$ns" \
      --from-literal=ACCESS_KEY_ID="$r2id" \
      --from-literal=ACCESS_SECRET_KEY="$r2secret" \
      --from-literal=REGION=auto \
      --dry-run=client -o yaml | write "$f"
  done
  unset r2id r2secret
else
  echo "  exists  r2-credentials (skipped)"
fi

echo "==> Database passwords (generated)"
role() {  # role <namespace> <secret-name> <username>
  local f="secrets/$1/$2.yaml"
  exists "$f" && return
  kubectl create secret generic "$2" -n "$1" --type=kubernetes.io/basic-auth \
    --from-literal=username="$3" --from-literal=password="$(pw)" \
    --dry-run=client -o yaml | write "$f"
}
role game pg-game-kelime       kelime
role data pg-apps-marketing    marketing
role data pg-apps-kinmemo-app  kinmemo_app
role data pg-apps-kinmemo-system kinmemo_system
role data pg-apps-rag          rag

echo "==> Grafana admin (generated)"
f="secrets/monitoring/grafana-admin.yaml"
exists "$f" || kubectl create secret generic grafana-admin -n monitoring \
  --from-literal=admin-user=admin --from-literal=admin-password="$(pw)" \
  --dry-run=client -o yaml | write "$f"

cat <<'MSG'

Done. Every file above is encrypted and safe to commit. To read a value later:
  sops -d secrets/monitoring/grafana-admin.yaml
You can now delete the certificate/key files you saved for this script.
MSG
