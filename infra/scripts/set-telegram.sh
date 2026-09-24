#!/usr/bin/env bash
#
# Stores the Telegram bot used for Grafana alerts as an encrypted secret
# (secrets/monitoring/grafana-telegram.yaml) and applies it to the cluster.
# The token is read with hidden input and never printed.
#
# Before running: create the bot with @BotFather, open it in Telegram and press
# Start (or add it to a group and send a message there), so it can find the chat.
#
#   ./scripts/set-telegram.sh
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/lib.sh
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/antcoders.txt}"
umask 077

read -r -s -p "Telegram bot token (from @BotFather): " TOKEN; echo
[[ "$TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]{30,}$ ]] || { echo "That doesn't look like a bot token (123456789:AA...)." >&2; exit 1; }

# Check the token and list the chats the bot has seen, without printing the token.
ME=$(curl -s "https://api.telegram.org/bot${TOKEN}/getMe")
BOT=$(python3 -c 'import sys,json;d=json.loads(sys.argv[1]);print(d["result"]["username"] if d.get("ok") else "")' "$ME")
[[ -n "$BOT" ]] || { echo "Telegram rejected this token." >&2; exit 1; }
echo "Bot: @$BOT"

CHATS=$(curl -s "https://api.telegram.org/bot${TOKEN}/getUpdates" | python3 -c '
import sys,json
seen={}
for u in json.load(sys.stdin).get("result",[]):
    m=u.get("message") or u.get("my_chat_member") or u.get("channel_post") or {}
    c=m.get("chat")
    if c: seen[c["id"]]=c.get("title") or " ".join(x for x in (c.get("first_name"),c.get("last_name")) if x) or c.get("username","")
for i,(cid,name) in enumerate(seen.items(),1): print(f"{i}|{cid}|{name}")')

if [[ -z "$CHATS" ]]; then
  echo "The bot hasn't seen any chat yet. Open @$BOT in Telegram, press Start, then run this again." >&2
  exit 1
fi
echo "Chats the bot can message:"
echo "$CHATS" | awk -F'|' '{printf "  %s) %s  (%s)\n", $1, $3, $2}'
read -r -p "Send alerts to which one? [1] " PICK; PICK="${PICK:-1}"
CHAT_ID=$(echo "$CHATS" | awk -F'|' -v p="$PICK" '$1==p{print $2}')
[[ -n "$CHAT_ID" ]] || { echo "No such choice." >&2; exit 1; }

F=secrets/monitoring/grafana-telegram.yaml
kubectl create secret generic grafana-telegram -n monitoring \
  --from-literal=TELEGRAM_BOT_TOKEN="$TOKEN" \
  --from-literal=TELEGRAM_CHAT_ID="$CHAT_ID" \
  --dry-run=client -o yaml > "$F"
sops -e -i "$F" || { rm -f "$F"; echo "encryption failed" >&2; exit 1; }
unset TOKEN

use_antcoders_cluster
sops -d "$F" | kubectl apply -f -
echo "Saved and applied $F (encrypted; safe to commit)."

# Grafana reads the token from its environment, so restart it, then load the
# contact point and send a test message.
kubectl -n monitoring rollout restart deploy/vm-grafana >/dev/null
kubectl -n monitoring rollout status deploy/vm-grafana --timeout=240s
kustomize build monitoring/telegram | kubectl apply --server-side --field-manager=antcoders-infra -f -
sleep 30
# Grafana 13 test API: receiver name is base64("telegram") = dGVsZWdyYW0. The
# token is read from Grafana's own environment, so it never leaves the pod.
kubectl -n monitoring exec deploy/vm-grafana -c grafana -- sh -c '
  curl -s -X POST -u "$GF_SECURITY_ADMIN_USER:$GF_SECURITY_ADMIN_PASSWORD" \
    -H "Content-Type: application/json" \
    http://localhost:3000/apis/notifications.alerting.grafana.app/v1beta1/namespaces/default/receivers/dGVsZWdyYW0/test \
    -d "{\"integration\":{\"uid\":\"telegram\",\"type\":\"telegram\",\"version\":\"v1\",\"settings\":{\"bottoken\":\"$TELEGRAM_BOT_TOKEN\",\"chatid\":\"$TELEGRAM_CHAT_ID\",\"parse_mode\":\"HTML\"}}}"' \
  | grep -q '"status":"success"' || { echo "Grafana could not send the test message." >&2; exit 1; }
echo "A test message should now be in your Telegram chat."
