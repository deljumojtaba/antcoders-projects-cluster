#!/usr/bin/env bash
#
# Prints a kubeconfig for GitHub Actions that uses the narrow `deployer`
# service account (platform/base/deployer-rbac.yaml), never your admin one.
#
#   ./scripts/make-ci-kubeconfig.sh | pbcopy     # then paste into KUBECONFIG_CI
set -euo pipefail

source "$(dirname "$0")/../scripts/lib.sh"
use_antcoders_cluster >&2

SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CA=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
TOKEN=$(kubectl -n kube-system get secret deployer-token -o jsonpath='{.data.token}' | base64 -d)

cat <<KC
apiVersion: v1
kind: Config
clusters:
  - name: antcoders
    cluster:
      server: ${SERVER}
      certificate-authority-data: ${CA}
users:
  - name: deployer
    user:
      token: ${TOKEN}
contexts:
  - name: deployer@antcoders
    context: { cluster: antcoders, user: deployer }
current-context: deployer@antcoders
KC
