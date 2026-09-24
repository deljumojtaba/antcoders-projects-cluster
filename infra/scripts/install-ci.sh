#!/usr/bin/env bash
#
# Copies the CI workflows and k8s Dockerfiles from infra/ into the app repos.
# It only writes files; review them with `git status` and commit yourself.
#
#   ./scripts/install-ci.sh antcoders            # one project
#   ./scripts/install-ci.sh                      # all four
#   PROJECTS_DIR=/path ./scripts/install-ci.sh   # repos elsewhere
#
# Projects: kelime-savasi, kinmemo, assist, antcoders
set -euo pipefail

INFRA="$(cd "$(dirname "$0")/.." && pwd)"
# Your working copies (the ones you commit from), not the copies next to infra/.
ROOT="${PROJECTS_DIR:-$HOME/Documents/projects}"
ONLY="${1:-all}"

copy() { mkdir -p "$(dirname "$2")"; cp "$1" "$2"; echo "  $2"; }
want() { [[ "$ONLY" == all || "$ONLY" == "$1" ]]; }
check_repo() {
  git -C "$1" rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repo: $1" >&2; exit 1; }
  echo "    remote: $(git -C "$1" remote get-url origin)"
}

if want kelime-savasi; then
echo "==> kelime-savasi"
R="$ROOT/kelime-savasi"; check_repo "$R"
copy "$INFRA/ci/kelime-savasi/k8s-backend.yml" "$R/.github/workflows/k8s-backend.yml"
copy "$INFRA/ci/kelime-savasi/k8s-sites.yml"   "$R/.github/workflows/k8s-sites.yml"
for f in Dockerfile nginx.conf; do
  copy "$INFRA/images/kelime-website/$f" "$R/deploy/k8s/kelime-website/$f"
  copy "$INFRA/images/kelime-admin/$f"   "$R/deploy/k8s/kelime-admin/$f"
done

fi

if want kinmemo; then
echo "==> kinmemo"
R="$ROOT/kinmemo"; check_repo "$R"
copy "$INFRA/ci/kinmemo/k8s-backend.yml" "$R/.github/workflows/k8s-backend.yml"
copy "$INFRA/ci/kinmemo/k8s-sites.yml"   "$R/.github/workflows/k8s-sites.yml"
copy "$INFRA/apps/kinmemo/migrate-job.yaml" "$R/deploy/k8s/migrate-job.yaml"
for f in Dockerfile nginx.conf security.conf; do
  copy "$INFRA/images/kinmemo-site/$f" "$R/deploy/k8s/kinmemo-site/$f"
done
for f in Dockerfile nginx.conf; do
  copy "$INFRA/images/kinmemo-admin/$f" "$R/deploy/k8s/kinmemo-admin/$f"
done

fi

if want assist; then
echo "==> Antcoders Assist"
check_repo "$ROOT/Antcoders Assist"
copy "$INFRA/ci/antcoders-assist/k8s.yml" "$ROOT/Antcoders Assist/.github/workflows/k8s.yml"

fi

if want antcoders; then
echo "==> antcoders"
check_repo "$ROOT/antcoders"
copy "$INFRA/ci/antcoders/k8s.yml" "$ROOT/antcoders/.github/workflows/k8s.yml"
fi

cat <<'MSG'

Next, in each GitHub repo: Settings -> Secrets and variables -> Actions ->
New repository secret  KUBECONFIG_CI  = output of scripts/make-ci-kubeconfig.sh
MSG
