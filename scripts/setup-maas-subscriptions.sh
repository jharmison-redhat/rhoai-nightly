#!/usr/bin/env bash
#
# setup-maas-subscriptions.sh - Sync the unified MaaS subscriptions + auth
# policy with the models currently registered on the cluster
#
# Creates (if missing) or patches (if changed) three objects in
# `models-as-a-service` covering every MaaSModelRef on the cluster:
#   - MaaSSubscription/all-models-free     (50000 tokens/min, priority 10)
#   - MaaSSubscription/all-models-premium  (100000 tokens/min, priority 20)
#   - MaaSAuthPolicy/all-models-access     (system:authenticated)
#
# modelRefs[] is enumerated from LIVE cluster state (`oc get maasmodelref -A`),
# never from a model list here: deploying a model is all it takes for the next
# sync to fold it in, and deleting a model drops it out. With zero
# MaaSModelRefs nothing is applied (the CRDs require at least one modelRef).
#
# Prerequisites:
#   - MaaS installed (run make maas first)
#   - oc logged into cluster
#
# Usage:
#   make maas-subscriptions
#
# Options:
#   -h, --help      Show this help message
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

# =============================================================================
# Preflight
# =============================================================================
if ! oc whoami &>/dev/null; then
    log_error "Not logged into OpenShift cluster"
    exit 1
fi

if ! oc get crd maassubscriptions.maas.opendatahub.io &>/dev/null; then
    log_error "MaaSSubscription CRD not found — MaaS not installed? Run 'make maas' first"
    exit 1
fi

# =============================================================================
# Enumerate live MaaSModelRefs
# =============================================================================
log_step "Syncing unified MaaS subscriptions + auth policy"

REFS_JSON=$(oc get maasmodelref -A -o json)
COUNT=$(echo "$REFS_JSON" | jq -r '.items | length')

if [ "$COUNT" -eq 0 ]; then
    log_warn "No MaaSModelRefs found on the cluster — nothing to sync"
    log_warn "Deploy a model first (make maas-model / make maas-external-model), then re-run"
    exit 0
fi

# =============================================================================
# Ensure namespaces
# =============================================================================
oc create namespace llm --dry-run=client -o yaml | oc apply -f - 2>/dev/null
oc label namespace llm opendatahub.io/dashboard=true --overwrite >/dev/null 2>&1 || true
oc create namespace models-as-a-service --dry-run=client -o yaml | oc apply -f - 2>/dev/null

log_info "Found $COUNT MaaSModelRef(s), building modelRefs..."

# Subscriptions carry per-model rate limits; the auth policy does not.
SUB_REFS=$(echo "$REFS_JSON" | jq -c '[.items[] | {name: .metadata.name, namespace: .metadata.namespace, tokenRateLimits: [{limit: 50000, window: "1m"}]}]')
AUTH_REFS=$(echo "$REFS_JSON" | jq -c '[.items[] | {name: .metadata.name, namespace: .metadata.namespace}]')

# =============================================================================
# Apply (create if missing, patch if changed)
# =============================================================================
log_info "Applying MaaSSubscription/all-models-free (50000 tokens/min, priority 10)..."
oc apply --server-side=true -n models-as-a-service -f - <<EOF
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata:
  name: all-models-free
  namespace: models-as-a-service
  annotations:
    openshift.io/display-name: "All Models Free Tier"
    openshift.io/description: "Free tier: 50000 tokens/min for all authenticated users, covering every registered model"
spec:
  owner:
    groups:
      - name: system:authenticated
    users: []
  modelRefs: ${SUB_REFS}
  priority: 10
EOF

log_info "Applying MaaSSubscription/all-models-premium (100000 tokens/min, priority 20)..."
oc apply --server-side=true -n models-as-a-service -f - <<EOF
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata:
  name: all-models-premium
  namespace: models-as-a-service
  annotations:
    openshift.io/display-name: "All Models Premium Tier"
    openshift.io/description: "Premium tier: 100000 tokens/min for all authenticated users, covering every registered model"
spec:
  owner:
    groups:
      - name: system:authenticated
    users: []
  modelRefs: ${SUB_REFS}
  priority: 20
EOF

log_info "Applying MaaSAuthPolicy/all-models-access..."
oc apply --server-side=true -n models-as-a-service -f - <<EOF
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSAuthPolicy
metadata:
  name: all-models-access
  namespace: models-as-a-service
  annotations:
    openshift.io/display-name: "All Models Access"
    openshift.io/description: "Grants all authenticated users access to every registered model"
spec:
  modelRefs: ${AUTH_REFS}
  subjects:
    groups:
      - name: system:authenticated
    users: []
EOF

log_info "Unified subscriptions + auth policy synced ($COUNT model(s))"
