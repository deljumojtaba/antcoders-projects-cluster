# Antcoders cluster

A 3-node k3s cluster on Hetzner Cloud running Kelime Savaşı, Kinmemo, Antcoders
Assist, antcoders.dev and (later) the marketing agent. About $40.6/month:
3 × CX33 ($29.97), one LB11 ($8.49) and three IPv4 addresses ($2.16).

The Persian plan (https://claude.ai/artifact/CYjixTcVLBkTeNJGiVF2MT) explains the reasoning behind the design. This file covers
**how to build the cluster and migrate the apps**.

```
infra/
├── cluster/        hetzner-k3s config + post-create labelling
├── platform/       Helm installs (Traefik, CloudNativePG, cert-manager, monitoring) and shared objects
├── databases/      pg-game (Kelime) and pg-apps (Kinmemo, Assist, marketing)
├── apps/           one kustomization per project
├── monitoring/     scrape targets and Uptime Kuma
├── secrets/        SOPS-encrypted secrets (*.example.yaml are templates)
├── images/         Dockerfiles for the static sites (copied into app repos)
├── ci/             GitHub Actions workflows (copied into app repos)
└── scripts/        helpers
```

## Layout at a glance

| Node | Label | Runs |
| --- | --- | --- |
| master1 | `antcoders.dev/pool=game` | kelime-service, pg-game primary, game Redis, Traefik |
| master2 | `antcoders.dev/pool=apps` | pg-game replica, pg-apps primary or replica, apps, Traefik |
| master3 | `antcoders.dev/pool=apps` | pg-apps replica or primary, apps, monitoring, Traefik |

All three are control-plane nodes (embedded etcd), so the cluster survives
losing any one node.

**How the game gets its own node.** Every non-game workload has a required
node affinity `antcoders.dev/pool NotIn [game]`. Game workloads *prefer* the
game node, but they are allowed to move if it dies. Isolation uses this label,
not a taint, because k3s' local-path helper pods and CNPG's Jobs don't
tolerate custom taints. Small system pods (Traefik, node-exporter, CSI) still
run on the game node.

**Things that must stay at one replica for now:**

| Workload | Why | Unblocked by |
| --- | --- | --- |
| kelime-service | matches and the WebSocket hub live in process memory | phase R4 in `kelime-savasi/docs/backend-refactoring-plan.md` |
| kinmemo-api / worker | they share an RWO uploads volume | moving uploads to R2, then enabling `apps/kinmemo/hpa.yaml` |
| assist-api | the realtime hub is in-process | fanning the hub out through Postgres LISTEN/NOTIFY or Redis |

## Tools on your Mac

```bash
brew install vitobotta/tap/hetzner_k3s
brew install kubectl helm sops age kustomize
brew install cloudnative-pg/tap/kubectl-cnpg     # `kubectl cnpg status ...`
helm version    # must be >= 3.14 (the VictoriaMetrics chart refuses older)
```

---

## Runbook

Every step leaves the old servers untouched until the matching DNS switch.
Each switch is a Cloudflare DNS edit, so rolling back takes seconds.

### 0. Accounts and keys (once)

1. **Hetzner**: create a Cloud project API token (Read & Write).
2. **Cloudflare R2**: create bucket `antcoders-backups` and an API token with
   *Object Read & Write* on that bucket only. Note the account ID, then put it
   in `databases/pg-game.yaml` and `databases/pg-apps.yaml` (`R2_ACCOUNT_ID`).
3. **Cloudflare Origin certificates**: for each zone (kelimesavasi.app,
   kinmemo.app, antcoders.dev), go to SSL/TLS → Origin Server → Create
   certificate. Include the apex and `*.apex`, and pick 15 years.
4. **SOPS key**:
   ```bash
   mkdir -p ~/.config/sops/age
   age-keygen -o ~/.config/sops/age/antcoders.txt   # BACK THIS FILE UP (password manager)
   ```
   Put the printed public key into `.sops.yaml`.
5. **GitHub token** for pulling images: a classic token with only
   `read:packages`.
6. Put your home IP into `cluster/hetzner-k3s.yaml` → `allowed_networks.ssh`.

### 1. Create the cluster (week 1)

```bash
cd infra
export HCLOUD_TOKEN=...
hetzner-k3s create --config cluster/hetzner-k3s.yaml
export KUBECONFIG=$PWD/kubeconfig
./cluster/post-create.sh
kubectl get nodes -L antcoders.dev/pool
```

Check that the three servers ended up on different physical hosts. Look for a
placement group in the Hetzner console. If there isn't one, create a *spread*
group and assign the servers to it; adding them requires a short power-off.

### 2. Platform

```bash
./platform/install.sh
kubectl -n traefik get svc traefik     # EXTERNAL-IP = the LB11's public IP
```

In the Hetzner console, check that the LB service is **TCP** on 80 and 443 with
proxy protocol turned on. The cloud controller sets this from the annotations
in `platform/values/traefik.yaml`.

### 3. Secrets

For every template you need:

```bash
cp secrets/game/pg-game-kelime.example.yaml secrets/game/pg-game-kelime.yaml
$EDITOR secrets/game/pg-game-kelime.yaml
sops -e -i secrets/game/pg-game-kelime.yaml    # now safe to commit
```

Leave `kelime-config-seed`, `kinmemo-env` and `assist-env` until their
migration step, because they need values from the old servers. Then:

```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/antcoders.txt
./scripts/apply-secrets.sh traefik
./scripts/apply-secrets.sh monitoring
./scripts/apply-secrets.sh data
./scripts/apply-secrets.sh game
GHCR_USER=deljumojtaba GHCR_TOKEN=ghp_... ./scripts/create-ghcr-pull.sh
```

### 4. Databases

```bash
kubectl apply -f databases/
kubectl cnpg status pg-game -n game       # expect: 2 instances, primary on the game node
kubectl cnpg status pg-apps -n data
kubectl -n data exec pg-apps-1 -- psql -U postgres -d kinmemo -c "select extname from pg_extension"   # vector, citext
kubectl apply -k monitoring/
```

**Failover test (do this now, while nothing depends on it).** Power off one
server in the Hetzner console. Then:

```bash
kubectl cnpg status pg-game -n game
```

The replica should be promoted within about 30 seconds. Power the server back
on. Do the same once for each node.

### 5. CI

```bash
./scripts/install-ci.sh antcoders             # or no argument for all 4 repos in ~/Documents/projects
./scripts/make-ci-kubeconfig.sh | pbcopy      # → each repo's secret KUBECONFIG_CI
```

Review and commit the new files in each repo. The first push builds the
images. Deploys to the cluster then fail until step 6 creates the Deployments.
That is expected.

Images live on GHCR (github.com/deljumojtaba → Packages) and stay private. Each
workflow keeps the last 10 versions of its image (20 for `kelime-service`) and
deletes older ones, so storage stays inside GitHub's free quota. If the
"Delete old images" step fails with a permission error, open the package →
Package settings → Manage Actions access, and give the repo the **Admin** role.

### 6. Migrate, one project at a time

The same pattern applies to each project:
1. Apply the manifests.
2. Copy the data over.
3. Test through a temporary hostname or `curl --resolve`.
4. Switch DNS in Cloudflare to the LB IP.
5. Watch for errors.
6. Delete the old server a few days later.

Test before switching DNS, for any hostname:

```bash
LB=$(kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -sk --resolve antcoders.dev:443:$LB https://antcoders.dev/ -o /dev/null -w '%{http_code}\n'
```

#### 6a. antcoders.dev + Antcoders Assist (week 2)

```bash
# secrets/assist/assist-env.yaml from /opt/antcoders-assist/.env.production, then:
./scripts/apply-secrets.sh assist
kubectl apply -k apps/web -k apps/assist

# Database: dump from the old server, restore as role rag
ssh -i ~/.ssh/antcoders_deploy root@157.180.70.104 \
  'cd /opt/antcoders-assist && docker compose -f docker-compose.prod.yml exec -T postgres pg_dump -U rag -Fc --no-owner rag' > rag.dump
kubectl -n data port-forward svc/pg-apps-rw 15432:5432 &
PGPASSWORD=$(kubectl -n data get secret pg-apps-superuser -o jsonpath='{.data.password}' | base64 -d) \
  pg_restore -h localhost -p 15432 -U postgres -d rag --no-owner --role=rag rag.dump
```

In Cloudflare (zone antcoders.dev):
1. Point `antcoders.dev`, `www` and `ai` to the LB IP (proxied).
2. **In the same minute**, change SSL/TLS mode from *Flexible* to
   *Full (strict)*. The old server only speaks HTTP, and the new one only
   speaks HTTPS.
3. Set Telegram webhooks again if Assist doesn't do it on start. The URL
   itself doesn't change.

Delete **Antco1** after a few quiet days, but first download `/opt/antcoders`.
It holds old, stopped projects (ant-log, ant-puzzle, antco,
antco-telegram-bot, hookwatch, solana-trading-bot, nginx-proxy) and
`backups/antlog-backup-20250923_173319.tar.gz`, none of which is in the
cluster:

```bash
ssh -i ~/.ssh/antcoders_deploy root@157.180.70.104 'tar czf - -C /opt antcoders' > antco1-opt-antcoders.tgz
```

#### 6b. Kinmemo (week 3)

```bash
# secrets/kinmemo/kinmemo-env.yaml from /opt/kinmemo/.env, with the new DB/Redis URLs
./scripts/apply-secrets.sh kinmemo
kubectl apply -k apps/kinmemo

# Maintenance window, ~5 minutes. Stop the API first and give the worker a
# minute to finish staged imports, so the uploads volume is empty and nothing
# needs copying. Then stop the worker.
OLD="ssh -i $HOME/.ssh/antcoders_deploy root@5.75.135.98"
$OLD 'cd /opt/kinmemo && docker compose -f docker-compose.prod.yml stop api'
sleep 60
$OLD 'cd /opt/kinmemo && docker compose -f docker-compose.prod.yml stop worker'
$OLD 'cd /opt/kinmemo && docker compose -f docker-compose.prod.yml exec -T db pg_dump -U postgres -Fc kinmemo' > kinmemo.dump

# Restore as superuser, keeping owners and grants (CNPG already created the roles)
kubectl -n data port-forward svc/pg-apps-rw 15432:5432 &
PGPASSWORD=$(kubectl -n data get secret pg-apps-superuser -o jsonpath='{.data.password}' | base64 -d) \
  pg_restore -h localhost -p 15432 -U postgres -d kinmemo kinmemo.dump
kubectl -n kinmemo rollout restart deploy/kinmemo-api deploy/kinmemo-worker
```

Before deleting the old Kinmemo server, download its backups (not in the cluster):

```bash
ssh -i ~/.ssh/antcoders_deploy root@5.75.135.98 \
  'tar czf - -C /opt/kinmemo backups pre-baseline-20260805-0456.sql.gz .env.bak.1785782787 .env.bak.domain-cutover-1785921364' > kinmemo-server-backups.tgz
```

Run Kinmemo's RLS test suite against the new database before you switch DNS.
The whole product depends on those policies. Then point `kinmemo.app`, `www`,
`api` and `admin` to the LB IP (proxied, Full (strict)). If `api.kinmemo.app`
was DNS-only (grey cloud), turn the proxy on.

#### 6c. Kelime Savaşı (week 4, 04:00–06:00 Istanbul)

Get the **server's** config, because the admin panel has edited it:

```bash
scp -i ~/.ssh/antcoders_deploy root@178.105.72.95:/opt/kelime-savasi/backend/config.prod.yaml .
# edit: postgres.host=pg-game-rw, postgres.password (= pg-game-kelime), redis.addr=redis:6379,
#       google_service_account_path=/app/google-service-account.json
# paste into secrets/game/kelime-config-seed.yaml, encrypt, apply
./scripts/apply-secrets.sh game
```

Check the collation of the old database first, and match it in
`databases/pg-game.yaml` if it isn't `en_US.utf8`:

```bash
ssh -i ~/.ssh/antcoders_deploy root@178.105.72.95 "docker compose -f /opt/kelime-savasi/docker-compose.prod.yml exec -T postgres \
  psql -U kelime -d kelime_prod -Atc \"select datcollate from pg_database where datname='kelime_prod'\""
```

Then the switch (about 5 minutes of downtime; the database is ~230 MB):

```bash
OLD="ssh -i $HOME/.ssh/antcoders_deploy root@178.105.72.95"
$OLD 'cd /opt/kelime-savasi && docker compose -f docker-compose.prod.yml stop service'
$OLD 'cd /opt/kelime-savasi && docker compose -f docker-compose.prod.yml exec -T postgres pg_dump -U kelime -Fc kelime_prod' > kelime.dump
kubectl -n game port-forward svc/pg-game-rw 25432:5432 &
PGPASSWORD=$(kubectl -n game get secret pg-game-kelime -o jsonpath='{.data.password}' | base64 -d) \
  pg_restore -h localhost -p 25432 -U kelime -d kelime_prod --no-owner --role=kelime kelime.dump
kubectl apply -k apps/kelime                                     # first start: seeds config.yaml
kubectl -n game rollout status deploy/kelime-service
curl -sk --resolve api.kelimesavasi.app:443:$LB https://api.kelimesavasi.app/readyz
```

Point `api`, `@`, `www` and `admin` of kelimesavasi.app to the LB IP (proxied,
Full (strict)), then open the app on your phone and play one match. Remove the
`metrics` DNS record, because Grafana replaces Netdata.

**Rollback**: point DNS back to 178.105.72.95 and start the old `service`
container again. Anything players did on the new cluster after the switch is
not on the old database, so decide within the first hour. Keep that server
for 1–2 weeks.

### 7. After the move

- Grafana: `kubectl -n monitoring port-forward svc/vm-grafana 3000:80`. Add a
  Telegram contact point and alerts for game p95 latency > 200 ms, pg-game
  CPU > 60%, replica lag, and a node going NotReady.
- Uptime Kuma: `kubectl -n monitoring port-forward svc/uptime-kuma 3001:3001`.
  Add the URLs listed in `monitoring/uptime-kuma.yaml`. Also add one free
  external monitor, because an in-cluster monitor can't report the whole
  cluster being down.
- Test restoring from R2 once a month (see the CNPG docs, *Recovery from an
  object store*, into a throwaway cluster).

## Day-to-day

| Task | Command |
| --- | --- |
| Deploy the game | GitHub → kelime-savasi → Actions → k8s-backend → Run workflow (quiet hours) |
| Deploy anything else | push to the main branch |
| Game DB health | `kubectl cnpg status pg-game -n game` |
| Move game primary back after a failover | `kubectl cnpg promote pg-game <instance-on-game-node> -n game` |
| Logs | `kubectl -n game logs deploy/kelime-service -f` |
| Change a secret | `sops secrets/.../x.yaml` then `./scripts/apply-secrets.sh <ns>` and restart the deployment |

## Scaling steps

| Signal | Action | Monthly |
| --- | --- | --- |
| 300–500 concurrent players, pg-game CPU > 60%, or p95 > 200 ms | Resize master1 to CX43 in the console. Its pods move to the other nodes during the resize. | ≈ $49.1 |
| Short traffic spike | Uncomment the `burst` pool in `cluster/hetzner-k3s.yaml`, enable `cluster_autoscaler`, run `hetzner-k3s create` again | hourly |
| Kinmemo uploads on R2 | add `hpa.yaml` to `apps/kinmemo/kustomization.yaml`, set api to RollingUpdate | – |
