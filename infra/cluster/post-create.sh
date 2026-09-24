#!/usr/bin/env bash
#
# Run once after `hetzner-k3s create`. Marks one node as the game node.
#
#   ./cluster/post-create.sh                 # uses the first master
#   ./cluster/post-create.sh antcoders-master2
#
# Isolation works by label, not taint: every non-game workload in this repo
# carries a required node affinity `antcoders.dev/pool NotIn [game]`. A taint
# would be stricter, but k3s' local-path helper pods and several operator Jobs
# do not tolerate custom taints, which breaks database volumes on that node.
set -euo pipefail

source "$(dirname "$0")/../scripts/lib.sh"
use_antcoders_cluster

GAME_NODE="${1:-$(kubectl get nodes -o name | sort | head -1 | cut -d/ -f2)}"

echo "==> Game node: ${GAME_NODE}"
kubectl label node "${GAME_NODE}" antcoders.dev/pool=game --overwrite

for n in $(kubectl get nodes -o name | cut -d/ -f2); do
  [[ "$n" == "$GAME_NODE" ]] && continue
  kubectl label node "$n" antcoders.dev/pool=apps --overwrite
done

echo "==> Storage classes (expect hcloud-volumes and local-path):"
kubectl get storageclass

kubectl get nodes -L antcoders.dev/pool
