#!/usr/bin/env bash
#
# deploy-apps.sh - Deploy the root ArgoCD application
#
# This applies the cluster-config Application which triggers GitOps sync
# of all operators and instances.
#
# Usage:
#   ./deploy-apps.sh [OPTIONS]
#
# Options:
#   --repo-url URL    Git repository URL (default: https://github.com/rh-aiservices-bu/rhoai-nightly)
#   --branch BRANCH   Git branch (default: main)
#   --dry-run         Preview without applying
#
# Environment variables (can also be set in .env):
#   GITOPS_REPO_URL, GITOPS_BRANCH

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# Defaults (can be overridden by env vars or CLI args)
REPO_URL="${GITOPS_REPO_URL:-https://github.com/rh-aiservices-bu/rhoai-nightly}"
BRANCH="${GITOPS_BRANCH:-main}"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --repo-url) REPO_URL="$2"; shift 2 ;;
        --branch) BRANCH="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help)
            cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --repo-url URL    Git repository URL (default: https://github.com/rh-aiservices-bu/rhoai-nightly)
  --branch BRANCH   Git branch (default: main)
  --dry-run         Preview without applying

Environment variables (can also be set in .env):
  GITOPS_REPO_URL, GITOPS_BRANCH
EOF
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

# Verify cluster connection
if ! oc whoami &>/dev/null; then
    log_error "Not logged into OpenShift cluster"
    exit 1
fi

log_info "Connected to: $(oc whoami --show-server)"

# Verify ArgoCD is ready
log_step "Verifying ArgoCD is ready..."
if ! oc get deployment openshift-gitops-server -n openshift-gitops &>/dev/null; then
    log_error "ArgoCD not installed. Run 'make gitops' first."
    exit 1
fi

AVAILABLE=$(oc get deployment openshift-gitops-server -n openshift-gitops -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "False")
if [[ "$AVAILABLE" != "True" ]]; then
    log_warn "ArgoCD server not fully available, waiting..."
    oc wait --for=condition=Available deployment/openshift-gitops-server \
        -n openshift-gitops --timeout=120s || {
        log_error "ArgoCD server not ready"
        exit 1
    }
fi

log_info "ArgoCD is ready"
log_info "Using repo: $REPO_URL"
log_info "Using branch: $BRANCH"

for appset in "cluster-operators-applicationset" "cluster-oper-instances-applicationset"; do
    APPSET_JSON=$(oc get applicationset.argoproj.io "$appset" -n openshift-gitops --ignore-not-found -o json 2>/dev/null || true)
    if [[ -n "$APPSET_JSON" ]] && ! jq -e --arg appset "$appset" '
        .metadata.labels["app.kubernetes.io/part-of"] == "rhoai-nightly" or
        ($appset == "cluster-operators-applicationset" and .spec.template.spec.source.path == "{{path}}") or
        ($appset == "cluster-oper-instances-applicationset" and .spec.template.spec.source.path == "{{values.path}}")
    ' <<<"$APPSET_JSON" >/dev/null; then
        log_error "ApplicationSet/$appset is not owned by rhoai-nightly; refusing to modify it"
        exit 1
    fi
done

# Step 1: Apply cluster-config WITHOUT auto-sync
log_step "Applying cluster-config Application (sync disabled)..."

CLUSTER_CONFIG="$REPO_ROOT/bootstrap/rhoaibu-cluster-nightly/cluster-config-app.yaml"
EXISTING_CLUSTER_CONFIG=$(oc get application.argoproj.io/cluster-config -n openshift-gitops --ignore-not-found -o json 2>/dev/null || true)
if [[ -n "$EXISTING_CLUSTER_CONFIG" ]] && ! jq -e '
    .metadata.labels["app.kubernetes.io/part-of"] == "rhoai-nightly" or
    .spec.source.path == "clusters/overlays/rhoaibu-cluster-nightly"
' <<<"$EXISTING_CLUSTER_CONFIG" >/dev/null; then
    log_error "Application/cluster-config is not owned by rhoai-nightly; refusing to modify it"
    exit 1
fi
TEMP_CONFIG=$(mktemp)
trap "rm -f $TEMP_CONFIG" EXIT

# Remove syncPolicy so it doesn't auto-sync before we patch
sed -e '/syncPolicy:/,/selfHeal:/d' "$CLUSTER_CONFIG" > "$TEMP_CONFIG"

if [[ "$DRY_RUN" == "true" ]]; then
    log_info "Dry run - would apply:"
    cat "$TEMP_CONFIG"
    exit 0
fi

oc apply -f "$TEMP_CONFIG"
log_info "cluster-config app created (sync disabled)"

# Step 2: Patch cluster-config with correct repo/branch
log_step "Patching cluster-config with repo/branch..."
oc patch application.argoproj.io/cluster-config -n openshift-gitops --type=merge -p "{
    \"spec\": {
        \"source\": {
            \"repoURL\": \"$REPO_URL\",
            \"targetRevision\": \"$BRANCH\"
        }
    }
}"
log_info "cluster-config patched: $REPO_URL @ $BRANCH"

# Step 3: Manually sync cluster-config (no automated sync to prevent overwriting patches)
log_step "Syncing cluster-config..."
oc patch application.argoproj.io/cluster-config -n openshift-gitops --type=merge -p '{
    "operation": {
        "initiatedBy": { "username": "deploy-script" },
        "sync": {}
    }
}'
log_info "cluster-config sync initiated"

# Step 4: Wait for ApplicationSets to be created
log_step "Waiting for ApplicationSets to be created..."
APPSET_WAIT_TIMEOUT=120
start_time=$(date +%s)

for appset in "cluster-operators-applicationset" "cluster-oper-instances-applicationset"; do
    while ! oc get applicationset.argoproj.io "$appset" -n openshift-gitops &>/dev/null; do
        elapsed=$(($(date +%s) - start_time))
        if [[ $elapsed -ge $APPSET_WAIT_TIMEOUT ]]; then
            log_error "Timeout waiting for ApplicationSet '$appset'"
            exit 1
        fi
        printf "  Waiting for: %s (%ds)...\r" "$appset" "$elapsed"
        sleep 3
    done
    APPSET_JSON=$(oc get applicationset.argoproj.io "$appset" -n openshift-gitops -o json)
    if ! jq -e --arg appset "$appset" '
        .metadata.labels["app.kubernetes.io/part-of"] == "rhoai-nightly" or
        ($appset == "cluster-operators-applicationset" and .spec.template.spec.source.path == "{{path}}") or
        ($appset == "cluster-oper-instances-applicationset" and .spec.template.spec.source.path == "{{values.path}}")
    ' <<<"$APPSET_JSON" >/dev/null; then
        log_error "ApplicationSet/$appset is not owned by rhoai-nightly; refusing to modify it"
        exit 1
    fi
    log_info "ApplicationSet created: $appset"
done

# Step 5: Wait for cluster-config sync operation to complete
log_step "Waiting for cluster-config to sync..."
SYNC_WAIT_TIMEOUT=120
start_time=$(date +%s)
while true; do
    # Check if operation is still in progress
    OP_PHASE=$(oc get application.argoproj.io/cluster-config -n openshift-gitops -o jsonpath='{.status.operationState.phase}' 2>/dev/null || echo "Unknown")
    if [[ "$OP_PHASE" == "Succeeded" || "$OP_PHASE" == "Running" && "$(oc get application.argoproj.io/cluster-config -n openshift-gitops -o jsonpath='{.status.sync.status}' 2>/dev/null)" == "Synced" ]]; then
        break
    fi
    if [[ "$OP_PHASE" == "Failed" || "$OP_PHASE" == "Error" ]]; then
        log_warn "cluster-config sync failed, continuing anyway..."
        break
    fi
    elapsed=$(($(date +%s) - start_time))
    if [[ $elapsed -ge $SYNC_WAIT_TIMEOUT ]]; then
        log_warn "Timeout waiting for cluster-config to sync, continuing anyway..."
        break
    fi
    printf "  cluster-config operation: %s (%ds)...\r" "$OP_PHASE" "$elapsed"
    sleep 3
done
echo ""
log_info "cluster-config synced"

# Step 6: Patch ApplicationSets with correct repo/branch
log_step "Patching ApplicationSets with repo/branch..."

oc patch applicationset cluster-operators-applicationset -n openshift-gitops --type=json -p "[
    {\"op\": \"replace\", \"path\": \"/spec/generators/0/git/repoURL\", \"value\": \"$REPO_URL\"},
    {\"op\": \"replace\", \"path\": \"/spec/generators/0/git/revision\", \"value\": \"$BRANCH\"},
    {\"op\": \"replace\", \"path\": \"/spec/template/spec/source/repoURL\", \"value\": \"$REPO_URL\"},
    {\"op\": \"replace\", \"path\": \"/spec/template/spec/source/targetRevision\", \"value\": \"$BRANCH\"}
]"
log_info "Patched cluster-operators-applicationset"

# instances appset uses list generator, not git - only patch template source
oc patch applicationset cluster-oper-instances-applicationset -n openshift-gitops --type=json -p "[
    {\"op\": \"replace\", \"path\": \"/spec/template/spec/source/repoURL\", \"value\": \"$REPO_URL\"},
    {\"op\": \"replace\", \"path\": \"/spec/template/spec/source/targetRevision\", \"value\": \"$BRANCH\"}
]"
log_info "Patched cluster-oper-instances-applicationset"

# Step 7: Create cert-manager only when it is not externally managed.
CERT_MANAGER_APP_CREATED=false
if ! CERT_MANAGER_APP=$(oc get application.argoproj.io/cert-manager -n openshift-gitops --ignore-not-found -o name 2>/dev/null); then
    log_warn "Could not inspect Application/cert-manager; leaving cert-manager untouched"
elif ! CERT_MANAGER_SUBSCRIPTIONS=$(oc get subscriptions.operators.coreos.com -A -o jsonpath='{range .items[?(@.spec.name=="openshift-cert-manager-operator")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null); then
    log_warn "Could not inspect cert-manager Subscriptions; leaving cert-manager untouched"
elif ! CERT_MANAGER_OPERATOR_GROUP=$(oc get operatorgroup.operators.coreos.com/cert-manager-operator-og -n cert-manager-operator --ignore-not-found -o name 2>/dev/null); then
    log_warn "Could not inspect OperatorGroup/cert-manager-operator-og; leaving cert-manager untouched"
elif [[ -n "$CERT_MANAGER_APP" || -n "$CERT_MANAGER_SUBSCRIPTIONS" || -n "$CERT_MANAGER_OPERATOR_GROUP" ]]; then
    log_warn "Existing cert-manager resources found; leaving cert-manager untouched"
else
    log_step "Creating cert-manager Application (sync disabled)..."
    oc apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: cert-manager
  namespace: openshift-gitops
  labels:
    app.kubernetes.io/part-of: rhoai-nightly
spec:
  project: default
  syncPolicy: {}
  ignoreDifferences:
    - group: operators.coreos.com
      kind: Subscription
      jsonPointers:
        - /spec/installPlanApproval
  source:
    repoURL: $REPO_URL
    targetRevision: $BRANCH
    path: components/operators/cert-manager
  destination:
    server: https://kubernetes.default.svc
    namespace: openshift-gitops
EOF
    CERT_MANAGER_APP_CREATED=true
    log_info "cert-manager app created (sync disabled)"
fi

# Step 8: Wait for all expected apps to be created
EXPECTED_APPS=(
    "nfd" "instance-nfd"
    "nvidia-operator" "instance-nvidia"
    "kueue-operator"
    "leader-worker-set" "instance-lws"
    "jobset-operator" "instance-jobset"
    "connectivity-link" "instance-kuadrant"
    "rhoai-operator" "instance-rhoai"
)
if [[ "$CERT_MANAGER_APP_CREATED" == "true" ]]; then
    EXPECTED_APPS+=("cert-manager")
fi

log_step "Waiting for apps to be created..."
APP_WAIT_TIMEOUT=120
start_time=$(date +%s)

for app in "${EXPECTED_APPS[@]}"; do
    while ! oc get application.argoproj.io/"$app" -n openshift-gitops &>/dev/null; do
        elapsed=$(($(date +%s) - start_time))
        if [[ $elapsed -ge $APP_WAIT_TIMEOUT ]]; then
            log_error "Timeout waiting for app '$app' to be created"
            exit 1
        fi
        printf "  Waiting for app: %s (%ds)...\r" "$app" "$elapsed"
        sleep 3
    done
done
echo ""
log_info "All ${#EXPECTED_APPS[@]} apps created!"

# Step 9: Patch only rhoai-nightly generated and standalone apps with correct repo/branch,
# (re)applying the ownership label so pre-label apps are adopted
# ApplicationSets use create-only policy, so existing apps need direct patching
log_step "Patching rhoai-nightly apps with repo/branch..."
for app in $(oc get applications.argoproj.io -n openshift-gitops -o json | jq -r '
    .items[] |
    select(.metadata.name != "cluster-config" and .metadata.name != "cert-manager") |
    select(
        .metadata.labels["app.kubernetes.io/part-of"] == "rhoai-nightly" or
        any(.metadata.ownerReferences[]?; .kind == "ApplicationSet" and
            (.name == "cluster-operators-applicationset" or .name == "cluster-oper-instances-applicationset")) or
        ((.metadata.name == "instance-maas" and .spec.source.path == "components/instances/maas-instance/chart") or
         (.metadata.name == "instance-maas-observability" and .spec.source.path == "components/instances/maas-observability/base") or
         (.metadata.name == "instance-evalhub" and .spec.source.path == "components/instances/evalhub"))
    ) | "application.argoproj.io/" + .metadata.name
'); do
    oc patch "$app" -n openshift-gitops --type=merge -p "{
        \"metadata\": {
            \"labels\": {
                \"app.kubernetes.io/part-of\": \"rhoai-nightly\"
            }
        },
        \"spec\": {
            \"source\": {
                \"repoURL\": \"$REPO_URL\",
                \"targetRevision\": \"$BRANCH\"
            }
        }
    }" 2>/dev/null || true
done
log_info "rhoai-nightly apps patched with: $REPO_URL @ $BRANCH"
log_info ""
log_info "Apps are deployed with sync DISABLED."
log_info "Run 'make sync' to sync apps in dependency order."
