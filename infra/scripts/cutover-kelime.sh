#!/usr/bin/env bash
#
# Kelime Savaşı switch from the old server (178.105.72.95) to the cluster.
# Run the phases in order, in a quiet hour (04:00-06:00 Istanbul). Each phase
# checks its own result and stops on the first problem.
#
#   ./scripts/cutover-kelime.sh check      # anytime: shows state, changes nothing
#   ./scripts/cutover-kelime.sh switch     # ~5 min downtime: stop old, copy DB, start new
#   -> then switch DNS in Cloudflare (api, @, www, admin -> LB IP; delete AAAA; Full strict)
#   ./scripts/cutover-kelime.sh verify     # after DNS: tests through Cloudflare
#
#   ./scripts/cutover-kelime.sh rollback   # DNS back first, then this: restarts old service
#
# Players in a running match at the moment of "switch" lose that match, the same
# as with every deploy of the old server.
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/lib.sh
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/antcoders.txt}"

OLD=root@178.105.72.95
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=15 -i "$HOME/.ssh/antcoders_deploy" "$OLD")
LB=49.13.42.163
H=api.kelimesavasi.app
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

say()  { printf '\033[36m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[31mxxx\033[0m %s\n' "$*" >&2; exit 1; }
primary() { kubectl -n game get cluster pg-game -o jsonpath='{.status.currentPrimary}'; }
psql_new() { kubectl -n game exec -i "$(primary)" -c postgres -- psql -U postgres -v ON_ERROR_STOP=1 "$@"; }

COUNTS_SQL='select count(*)||'"'"' users, '"'"'||(select count(*) from matches)||'"'"' matches, '"'"'||(select count(*) from coin_transactions)||'"'"' coin tx, '"'"'||(select count(*) from leaderboard_weekly)||'"'"' lb rows, '"'"'||(select max(version) from schema_migrations)||'"'"' schema'"'"' from users'

check() {
  use_antcoders_cluster
  say "Old server"
  "${SSH[@]}" 'docker ps --format "  {{.Names}}: {{.Status}}" | grep kelime'
  say "Cluster"
  kubectl -n game get deploy kelime-service -o jsonpath='  kelime-service replicas: {.spec.replicas}  image: {.spec.template.spec.containers[0].image}{"\n"}'
  kubectl -n game get cluster pg-game -o jsonpath='  pg-game: {.status.phase}, primary {.status.currentPrimary}{"\n"}'
  kubectl -n game get networkpolicy kelime-service-no-internet >/dev/null 2>&1 \
    && echo "  test isolation policy: present (removed by 'switch')" \
    || echo "  test isolation policy: absent"
}

switch() {
  use_antcoders_cluster
  [[ "$(kubectl -n game get deploy kelime-service -o jsonpath='{.spec.replicas}')" == 0 ]] \
    || die "cluster kelime-service is already running; refusing"

  say "1/8 Refresh the config seed from the server (admin-panel edits since preparation)"
  local pw; pw=$(sops -d secrets/game/pg-game-kelime.yaml | awk '/password:/{print $2}' | base64 -d)
  "${SSH[@]}" 'cat /opt/kelime-savasi/backend/config.prod.yaml' | PW="$pw" python3 -c '
import sys,os,re,json
src=sys.stdin.read(); out=[]; sec=None; n=0
for line in src.splitlines(keepends=True):
    m=re.match(r"^([a-z_]+):", line)
    if m: sec=m.group(1)
    if sec=="postgres":
        if re.match(r"^\s+host:", line): line=re.sub(r"host:.*", "host: \"pg-game-rw\"", line); n+=1
        elif re.match(r"^\s+password:", line): line=re.sub(r"password:.*", "password: "+json.dumps(os.environ["PW"]), line); n+=1
    out.append(line)
assert n==2, n
sys.stdout.write("".join(out))' > "$WORK/config.yaml"
  unset pw
  kubectl -n game create secret generic kelime-config-seed --from-file=config.yaml="$WORK/config.yaml" \
    --dry-run=client -o yaml > secrets/game/kelime-config-seed.yaml
  sops -e -i secrets/game/kelime-config-seed.yaml
  sops -d secrets/game/kelime-config-seed.yaml | kubectl apply -f - >/dev/null
  rm -f "$WORK/config.yaml"

  say "2/8 Stop the old game service (downtime starts)"
  "${SSH[@]}" 'docker stop -t 20 kelime-savasi-service-1 >/dev/null && echo "  stopped at $(date -u +%H:%M:%S) UTC"'

  say "3/8 Final dump of the old database"
  "${SSH[@]}" 'docker exec kelime-savasi-postgres-1 pg_dump -U kelime -d kelime_prod -Fc --no-owner --no-privileges --no-comments' > "$WORK/kelime.dump"
  head -c 5 "$WORK/kelime.dump" | grep -q PGDMP || die "dump is not a valid pg_dump file"
  "${SSH[@]}" "docker exec kelime-savasi-postgres-1 psql -U kelime -d kelime_prod -Atc \"$COUNTS_SQL\"" > "$WORK/old-counts"
  echo "  old: $(cat "$WORK/old-counts")  ($(stat -f %z "$WORK/kelime.dump") bytes)"

  say "4/8 Replace the practice copy in the cluster"
  psql_new -d postgres -qAt -c "select pg_terminate_backend(pid) from pg_stat_activity where datname='kelime_prod' and pid<>pg_backend_pid();" >/dev/null
  psql_new -d postgres -q -c "DROP DATABASE kelime_prod;"
  psql_new -d postgres -q -c "CREATE DATABASE kelime_prod OWNER kelime TEMPLATE template0 ENCODING 'UTF8' LC_COLLATE 'en_US.UTF-8' LC_CTYPE 'en_US.UTF-8';"
  kubectl -n game exec -i "$(primary)" -c postgres -- pg_restore -U postgres -d kelime_prod --no-owner --role=kelime --exit-on-error < "$WORK/kelime.dump"
  local new; new=$(psql_new -d kelime_prod -Atc "$COUNTS_SQL")
  echo "  new: $new"
  [[ "$new" == "$(cat "$WORK/old-counts")" ]] || die "row counts differ; old service is stopped, run 'rollback' after fixing DNS"

  say "5/8 Fresh Redis, then carry over the 'leader already announced' sets"
  kubectl -n game exec deploy/redis -- redis-cli FLUSHALL >/dev/null
  local k=0
  for key in $("${SSH[@]}" 'docker exec kelime-savasi-redis-1 redis-cli --scan --pattern "feed:lb:leaders:*"'); do
    members=$("${SSH[@]}" "docker exec kelime-savasi-redis-1 redis-cli SMEMBERS $key")
    ttl=$("${SSH[@]}" "docker exec kelime-savasi-redis-1 redis-cli TTL $key")
    [[ -n "$members" ]] && kubectl -n game exec deploy/redis -- redis-cli SADD "$key" $members >/dev/null
    [[ "$ttl" -gt 0 ]] && kubectl -n game exec deploy/redis -- redis-cli EXPIRE "$key" "$ttl" >/dev/null
    k=$((k+1))
  done
  echo "  copied $k leader set(s)"

  say "6/8 Reset config.yaml on the volume so it is re-seeded from step 1"
  kubectl -n game run kelime-config-reset --rm -i --restart=Never --image=busybox:1.37 \
    --overrides='{"spec":{"securityContext":{"runAsUser":65532,"runAsGroup":65532,"fsGroup":65532},"volumes":[{"name":"c","persistentVolumeClaim":{"claimName":"kelime-config"}}],"containers":[{"name":"r","image":"busybox:1.37","command":["rm","-f","/data/config.yaml"],"volumeMounts":[{"name":"c","mountPath":"/data"}]}]}}' \
    >/dev/null 2>&1 || true

  say "7/8 Remove the test isolation policy and start the game in the cluster"
  kubectl delete -f apps/kelime/test-isolation.yaml --ignore-not-found >/dev/null
  kubectl -n game scale deploy kelime-service --replicas=1 >/dev/null
  kubectl -n game rollout status deploy/kelime-service --timeout=300s

  say "8/8 Test through the load balancer"
  local ready; ready=$(curl -sk --resolve "$H:443:$LB" "https://$H/readyz")
  echo "  readyz: $ready"
  [[ "$ready" == *ready* ]] || die "cluster game service is not ready"
  echo "  websocket: $(curl -sk --resolve "$H:443:$LB" --http1.1 -o /dev/null -w '%{http_code}' --max-time 5 \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "https://$H/ws" || true)"
  cat <<'MSG'

  GAME IS READY IN THE CLUSTER. Now in Cloudflare (zone kelimesavasi.app):
    - A records api, @ (kelimesavasi.app), www, admin  ->  49.13.42.163, proxied
    - delete the AAAA records for those names
    - delete the "metrics" record (Grafana replaces Netdata)
    - SSL/TLS -> Full (strict)
  Then run:  ./scripts/cutover-kelime.sh verify
MSG
}

verify() {
  for u in "https://$H/readyz" https://kelimesavasi.app/ https://www.kelimesavasi.app/ https://admin.kelimesavasi.app/ https://kelimesavasi.app/app-ads.txt; do
    printf '  %-45s %s\n' "$u" "$(curl -s -o /dev/null -w '%{http_code} %{time_total}s' "$u")"
  done
  echo "  websocket via Cloudflare: $(curl -s --http1.1 -o /dev/null -w '%{http_code}' --max-time 5 \
    -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "https://$H/ws" || true)"
  use_antcoders_cluster >/dev/null
  echo "  game log lines in the last 2 min: $(kubectl -n game logs deploy/kelime-service -c service --since=2m | wc -l | xargs)"
  echo "  last old-server API request: $("${SSH[@]}" 'tail -1 /var/log/nginx/access.log 2>/dev/null | cut -d" " -f4' || true)"
}

rollback() {
  use_antcoders_cluster
  say "Point DNS back to 178.105.72.95 FIRST (api, @, www, admin), then continue."
  read -r -p "  DNS points to the old server again? [yes/no] " a
  [[ "$a" == yes ]] || die "aborted"
  kubectl -n game scale deploy kelime-service --replicas=0 >/dev/null
  "${SSH[@]}" 'docker start kelime-savasi-service-1 >/dev/null && echo "  old service started"'
  echo "  Note: anything players did on the cluster after the switch is not on the old database."
}

case "${1:-}" in
  check|switch|verify|rollback) "$1" ;;
  *) sed -n '3,17p' "$0"; exit 1 ;;
esac
