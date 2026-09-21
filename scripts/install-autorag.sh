#!/usr/bin/env bash
#
# install-autorag.sh - Enable AutoML/AutoRAG Tech Preview testing on an RHOAI cluster
#
# This script handles the imperative parts of the autorag test tenant:
#   - autorag-pg-creds secret (generated password — not in git)
#   - instance-autorag ArgoCD Application (with resources-finalizer cascade)
#
# The kustomize manifests (components/instances/autorag/) manage:
#   - autorag-tenant namespace (dashboard-visible project)
#   - DataSciencePipelinesApplication with the managed AutoML/AutoRAG
#     pipelines enabled (spec.apiServer.managedPipelines: {})
#   - pgvector PostgreSQL Deployment + PVC + Service (AutoRAG vector store)
#
# The AutoML/AutoRAG dashboard feature flags are enabled repo-wide in
# components/instances/rhoai-instance/base/odh-dashboard-config.yaml
# (automl/autorag: true) and sync with instance-rhoai — this script does
# not touch them.
#
# Prerequisites:
#   - RHOAI 3.5+ with dashboard flags automl/autorag enabled
#   - ArgoCD running with instance-rhoai synced (used to detect repoURL/branch)
#
# Usage:
#   ./install-autorag.sh [OPTIONS]
#
# Options:
#   --uninstall      Delete the instance-autorag Application (cascade-prunes
#                    DSPA, pgvector, autorag-tenant namespace) + secrets
#   --dry-run        Preview without applying
#   -h, --help       Show this help message
#
# References:
#   - https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/working_with_automl
#   - https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/working_with_autorag
#

set -euo pipefail

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

NAMESPACE=autorag-tenant
APP_NAME=instance-autorag
KUSTOMIZE_PATH=components/instances/autorag

UNINSTALL=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --uninstall) UNINSTALL=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help)
            cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --uninstall      Delete the instance-autorag Application (cascade-prunes
                   DSPA, pgvector, autorag-tenant namespace) + secrets
  --dry-run        Preview without applying
  -h, --help       Show this help message

install-autorag.sh enables AutoML/AutoRAG Tech Preview testing: a dedicated
autorag-tenant project with a DSPA (managed AutoML/AutoRAG pipelines) and a
pgvector PostgreSQL for the AutoRAG remote vector store.
EOF
            exit 0
            ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

run_cmd() {
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] $*"
    else
        "$@"
    fi
}

# =============================================================================
# Phase 1: Preflight checks
# =============================================================================
log_step "Phase 1: Preflight checks"

# Verify cluster connection
if ! oc whoami &>/dev/null; then
    log_error "Not logged into OpenShift cluster"
    exit 1
fi
log_info "Connected to: $(oc whoami --show-server)"

# Check RHOAI CSV
if ! oc get csv -n redhat-ods-operator --no-headers 2>/dev/null | grep rhods >/dev/null; then
    log_error "RHOAI operator not found"
    exit 1
fi
log_info "RHOAI operator found"

# Check dashboard feature flags (set in rhoai-instance base, synced via ArgoCD)
AUTOML_FLAG=$(oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications -o jsonpath='{.spec.dashboardConfig.automl}' 2>/dev/null)
AUTORAG_FLAG=$(oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications -o jsonpath='{.spec.dashboardConfig.autorag}' 2>/dev/null)
if [ "$AUTOML_FLAG" != "true" ] || [ "$AUTORAG_FLAG" != "true" ]; then
    log_warn "Dashboard flags automl='${AUTOML_FLAG:-not set}' autorag='${AUTORAG_FLAG:-not set}' (expected 'true')"
    log_warn "They are enabled in components/instances/rhoai-instance/base/odh-dashboard-config.yaml —"
    log_warn "sync instance-rhoai (make refresh-apps) before creating optimization runs"
else
    log_info "Dashboard flags: automl=true autorag=true"
fi

# Detect repo URL and branch from existing ArgoCD apps (fork support)
REPO_URL="${GITOPS_REPO_URL:-$(oc get application.argoproj.io/instance-rhoai -n openshift-gitops -o jsonpath='{.spec.source.repoURL}' 2>/dev/null || echo "")}"
BRANCH="${GITOPS_BRANCH:-$(oc get application.argoproj.io/instance-rhoai -n openshift-gitops -o jsonpath='{.spec.source.targetRevision}' 2>/dev/null || echo "")}"

if [ -z "$REPO_URL" ] || [ -z "$BRANCH" ]; then
    log_error "Could not detect GitOps repo URL or branch from instance-rhoai Application."
    log_error "Has 'make deploy' run? Otherwise set GITOPS_REPO_URL and GITOPS_BRANCH explicitly."
    exit 1
fi
log_info "GitOps source: ${REPO_URL} @ ${BRANCH}"

# =============================================================================
# UNINSTALL PATH
# =============================================================================
if [ "$UNINSTALL" = true ]; then
    log_step "Uninstall: deleting $APP_NAME Application (cascade-prunes resources)"

    if oc get application.argoproj.io/$APP_NAME -n openshift-gitops &>/dev/null; then
        run_cmd oc delete application.argoproj.io/$APP_NAME -n openshift-gitops --wait=true
        log_info "$APP_NAME Application deleted"
        log_info "The resources-finalizer cascade-prunes DSPA, pgvector and the"
        log_info "$NAMESPACE namespace (which removes the pg data + secrets with it)."
    else
        log_info "$APP_NAME Application not found — nothing to cascade"
    fi

    # Belt-and-braces: the secret lives inside $NAMESPACE so the namespace
    # prune normally removes it. Delete it explicitly if anything survived.
    if oc get namespace "$NAMESPACE" &>/dev/null; then
        if oc get secret autorag-pg-creds -n "$NAMESPACE" &>/dev/null; then
            run_cmd oc delete secret autorag-pg-creds -n "$NAMESPACE"
            log_info "autorag-pg-creds deleted"
        fi
    fi

    log_info "========================================="
    log_info "AutoML/AutoRAG Uninstall Summary"
    log_info "========================================="
    log_info "Removed: $APP_NAME Application"
    log_info "  (cascade-pruned: DSPA, pgvector Deployment/PVC/Service, autorag-tenant ns)"
    log_info "Removed: autorag-pg-creds (if namespace still present)"
    log_info "========================================="
    exit 0
fi

# =============================================================================
# Phase 2: Create namespace + PostgreSQL secret (MaaS pattern: creds are
# imperative, generated if missing, idempotent with read-back)
# =============================================================================
log_step "Phase 2: Create $NAMESPACE namespace + autorag-pg-creds secret"

if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Would ensure namespace $NAMESPACE exists"
else
    oc create namespace "$NAMESPACE" --dry-run=client -o yaml | oc apply -f - >/dev/null
    log_info "Namespace $NAMESPACE ready (GitOps-owned via namespace-autorag-tenant.yaml)"
fi

if ! oc get secret autorag-pg-creds -n "$NAMESPACE" &>/dev/null; then
    PG_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
    run_cmd oc create secret generic autorag-pg-creds \
      -n "$NAMESPACE" \
      --from-literal=POSTGRES_USER=autorag \
      --from-literal=POSTGRES_DB=autorag \
      --from-literal=POSTGRES_PASSWORD="$PG_PASSWORD"
    log_info "Created autorag-pg-creds"
else
    log_info "autorag-pg-creds already exists, skipping secret creation"
    PG_PASSWORD=$(oc get secret autorag-pg-creds -n "$NAMESPACE" -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d)
fi

# =============================================================================
# Phase 3: Create/update instance-autorag ArgoCD Application
# =============================================================================
log_step "Phase 3: Create/update $APP_NAME ArgoCD Application"

# Idempotent — oc apply re-applies an already-present Application without
# changing Synced/Healthy state. The resources-finalizer enables cascade
# deletion at uninstall time (evalhub pattern).
if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Would apply Application $APP_NAME -> ${REPO_URL}@${BRANCH} ${KUSTOMIZE_PATH}"
else
    cat <<EOF | oc apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${APP_NAME}
  namespace: openshift-gitops
  annotations:
    argocd.argoproj.io/compare-options: IgnoreExtraneous
    argocd.argoproj.io/sync-options: SkipDryRunOnMissingResource=true
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${REPO_URL}
    targetRevision: ${BRANCH}
    path: ${KUSTOMIZE_PATH}
  destination:
    server: https://kubernetes.default.svc
    namespace: openshift-gitops
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    retry:
      limit: 5
      backoff:
        duration: 30s
        factor: 2
        maxDuration: 3m
EOF

    log_info "Waiting for ArgoCD to sync..."
    TIMEOUT=180
    ELAPSED=0
    SYNC_STATUS="Unknown"
    while [ $ELAPSED -lt $TIMEOUT ]; do
        SYNC_STATUS=$(oc get application.argoproj.io/$APP_NAME -n openshift-gitops -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
        HEALTH=$(oc get application.argoproj.io/$APP_NAME -n openshift-gitops -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
        if [ "$SYNC_STATUS" = "Synced" ]; then
            log_info "ArgoCD sync complete (health: ${HEALTH})"
            break
        fi
        sleep 10
        ELAPSED=$((ELAPSED + 10))
        if [ $((ELAPSED % 30)) -eq 0 ]; then
            log_info "Waiting for sync... (${ELAPSED}s, status: ${SYNC_STATUS}, health: ${HEALTH})"
        fi
    done

    if [ "$SYNC_STATUS" != "Synced" ]; then
        log_warn "ArgoCD sync did not complete within ${TIMEOUT}s (status: ${SYNC_STATUS})"
    fi
fi

# =============================================================================
# Phase 4: Validate the test tenant
# =============================================================================
log_step "Phase 4: Validate AutoML/AutoRAG test tenant"

if [ "$DRY_RUN" = true ]; then
    log_info "[DRY RUN] Skipping validation"
    log_info "========================================="
    log_info "AutoML/AutoRAG Install Summary (DRY RUN)"
    log_info "========================================="
    log_info "Tenant namespace: ${NAMESPACE}"
    log_info "pgvector URL:     pgvector.${NAMESPACE}.svc:5432/autorag"
    log_info "========================================="
    exit 0
fi

# Wait for pgvector (DSPA pods take longer; MinIO/MariaDB are DSPO-managed)
log_info "Waiting for pgvector deployment..."
oc rollout status deployment/pgvector -n "$NAMESPACE" --timeout=300s || \
    log_warn "pgvector rollout did not complete within 300s (check the autorag-pg-creds secret exists)"

# Verify the pgvector extension initialized
if oc exec -n "$NAMESPACE" deployment/pgvector -- psql -U autorag -d autorag -tAc "SELECT 1 FROM pg_extension WHERE extname='vector'" 2>/dev/null | grep -q 1; then
    log_info "pgvector extension installed in db 'autorag'"
else
    log_warn "pgvector extension not detected — the init container only runs on first volume use"
    log_warn "Check: oc exec -n $NAMESPACE deployment/pgvector -- psql -U autorag -d autorag -c '\\dx'"
fi

# Wait for DSPA readiness (incl. managed pipelines) — mirrors evalhub's wait
log_info "Waiting for DSPA managed pipelines to validate (may take several minutes)..."
TIMEOUT=300
ELAPSED=0
PIPELINES_VALID=""
while [ $ELAPSED -lt $TIMEOUT ]; do
    PIPELINES_VALID=$(oc get dspa dspa -n "$NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="ManagedPipelineValid")].status}' 2>/dev/null || echo "")
    if [ "$PIPELINES_VALID" = "True" ]; then
        log_info "ManagedPipelineValid=True — AutoML/AutoRAG pipelines registered"
        break
    fi
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done
if [ "$PIPELINES_VALID" != "True" ]; then
    log_warn "ManagedPipelineValid condition not True after ${TIMEOUT}s"
    log_warn "Check: oc get dspa dspa -n $NAMESPACE -o jsonpath='{.status.conditions}'"
fi

# MinIO external route for uploading test data (CSV for AutoML, docs for AutoRAG)
MINIO_ROUTE=$(oc get route -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.spec.host}{"\n"}{end}' 2>/dev/null | grep -i minio | head -1 || echo "")

log_info "========================================="
log_info "AutoML/AutoRAG Install Summary"
log_info "========================================="
log_info "Tenant namespace:   ${NAMESPACE}"
log_info "DSPA:               ManagedPipelineValid=${PIPELINES_VALID:-not ready}"
log_info "pgvector:           pgvector.${NAMESPACE}.svc:5432/autorag (user: autorag)"
if [ -n "$MINIO_ROUTE" ]; then
    log_info "MinIO (test data):  http://${MINIO_ROUTE}"
fi
log_info "Dashboard:          AutoML + AutoRAG pages under the ${NAMESPACE} project"
log_info "========================================="
log_info "Next steps:"
log_info "  - Connect pgvector in the dashboard (Data connections) using the"
log_info "    autorag-pg-creds secret values, or:"
log_info "      oc get secret autorag-pg-creds -n ${NAMESPACE} -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d"
log_info "  - AutoML:  upload a CSV to MinIO, create an optimization run"
log_info "  - AutoRAG: prepare test data, create a run against pgvector"
log_info "  - Uninstall: make autorag-uninstall"
log_info "========================================="
