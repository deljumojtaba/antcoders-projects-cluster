# Sourced by every script that talks to the cluster.
#
# Always uses infra/kubeconfig, ignoring any KUBECONFIG already set in your
# shell (which may point at a different cluster), and refuses to continue
# unless the nodes are this cluster's (names start with "antcoders-").

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="$INFRA_DIR/kubeconfig"

use_antcoders_cluster() {
  if [[ ! -f "$KUBECONFIG" ]]; then
    echo "No $KUBECONFIG — run hetzner-k3s create first." >&2
    exit 1
  fi
  local nodes
  if ! nodes=$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); then
    echo "Cannot reach the cluster in $KUBECONFIG." >&2
    exit 1
  fi
  for n in $nodes; do
    if [[ "$n" != antcoders-* ]]; then
      echo "REFUSING: node '$n' is not part of the antcoders cluster." >&2
      echo "Check $KUBECONFIG." >&2
      exit 1
    fi
  done
  echo "Cluster: antcoders ($(echo "$nodes" | wc -w | xargs) nodes) via $KUBECONFIG"
}
