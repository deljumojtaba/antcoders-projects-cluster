#!/usr/bin/env bash
#
# Installs the cluster-wide pieces, in dependency order. Idempotent: re-run it
# after changing a values file or bumping a version below.
#
#   ./platform/install.sh
set -euo pipefail

cd "$(dirname "$0")"
source ../scripts/lib.sh
use_antcoders_cluster

# Pinned versions (checked 2026-09-24). Bump deliberately, one at a time.
TRAEFIK_CHART=41.6.0              # Traefik v3.7
CERT_MANAGER_CHART=v1.21.2        # required by the barman-cloud plugin
CNPG_CHART=0.29.1                 # CloudNativePG operator 1.30.1
BARMAN_PLUGIN_CHART=0.8.0         # plugin-barman-cloud v0.15.0 (backups to R2)
VM_STACK_CHART=0.93.0             # VictoriaMetrics + Grafana

helm repo add traefik https://traefik.github.io/charts >/dev/null
helm repo add jetstack https://charts.jetstack.io >/dev/null
helm repo add cnpg https://cloudnative-pg.github.io/charts >/dev/null
helm repo add vm https://victoriametrics.github.io/helm-charts >/dev/null
helm repo update >/dev/null

echo "==> Namespaces, priority classes, local-path storage"
kubectl apply -f base/namespaces.yaml
kubectl apply -f base/priorityclasses.yaml
kubectl apply -f base/local-path-storage.yaml

# Charts below reference these secrets (TLS certs, Grafana admin), so they
# must exist first. Needs the SOPS age key.
# k3s ships CoreDNS with 1 replica. If its node dies, service names stop
# resolving cluster-wide and database failover stalls (found in the power-off
# test). k3s does not manage the replica count, so this persists.
echo "==> CoreDNS: one replica per node"
kubectl -n kube-system scale deploy coredns --replicas=3

echo "==> Secrets for traefik and monitoring"
../scripts/apply-secrets.sh traefik
../scripts/apply-secrets.sh monitoring

echo "==> cert-manager"
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --version "$CERT_MANAGER_CHART" \
  -f values/cert-manager.yaml --wait

echo "==> CloudNativePG operator + barman-cloud plugin"
helm upgrade --install cnpg cnpg/cloudnative-pg \
  --namespace cnpg-system --version "$CNPG_CHART" \
  -f values/cnpg.yaml --wait
helm upgrade --install barman-cloud cnpg/plugin-barman-cloud \
  --namespace cnpg-system --version "$BARMAN_PLUGIN_CHART" \
  -f values/barman-cloud.yaml --wait

echo "==> Traefik (creates the Hetzner LB11 through the cloud controller)"
helm upgrade --install traefik traefik/traefik \
  --namespace traefik --version "$TRAEFIK_CHART" \
  -f values/traefik.yaml --wait
kubectl apply -f base/traefik-shared.yaml

echo "==> Monitoring"
helm upgrade --install vm vm/victoria-metrics-k8s-stack \
  --namespace monitoring --version "$VM_STACK_CHART" \
  -f values/vm-stack.yaml --wait --timeout 10m

kubectl apply -f base/deployer-rbac.yaml

echo
echo "Done. Load balancer:"
kubectl -n traefik get svc traefik -o wide
