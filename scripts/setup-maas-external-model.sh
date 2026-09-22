#!/usr/bin/env bash
#
# setup-maas-external-model.sh - Register an external model via the MaaS
# External Models APIs (ExternalProvider + ExternalModel, RHOAI 3.5+)
#
# Deploys into `llm`:
#   - ExternalProvider "openai" (openai API format, apikey auth) pointing at a
#     remote OpenAI-compatible gateway (e.g. a MaaS gateway on another cluster)
#   - ExternalModel (client-facing name + provider ref, openai-chat format)
#   - MaaSModelRef (registers the model in the MaaS catalog)
# And into `models-as-a-service`:
#   - MaaSAuthPolicy + MaaSSubscription (free + premium tiers)
#
# The provider API key Secret "openai-api-key" in `llm` is created from
# MAAS_EXTERNAL_API_KEY and carries the `inference.llm-d.ai/ipp-managed=true`
# label — without it the Payload Processor cannot read the key.
#
# Resource naming (all derived from MAAS_EXTERNAL_MODEL):
#   - The client-facing model name (ExternalModel CR name, spec.modelName,
#     MaaSModelRef name) is the SANITIZED model name: lowercased, characters
#     outside [a-z0-9-] stripped (e.g. gpt-5.6-luna -> gpt-56-luna). Clients
#     send this value in the "model" field of chat completions.
#   - spec.externalProviderRefs[].targetModel is the RAW model name, verbatim
#     as served by the remote endpoint.
#
# Prerequisites:
#   - MaaS installed (run make maas first)
#   - oc logged into cluster
#   - .env with MAAS_EXTERNAL_ENDPOINT, MAAS_EXTERNAL_MODEL,
#     MAAS_EXTERNAL_API_KEY (MAAS_EXTERNAL_PATH optional) — see .env.example
#
# Usage:
#   make maas-external-model         # deploy
#   make maas-external-model-delete  # remove
#
# Options:
#   --delete        Delete the external model instead of deploying
#   -h, --help      Show this help message
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/components/instances/maas-external-model"

SECRET_NAME="openai-api-key"
PROVIDER_NAME="openai"
IPP_LABEL="inference.llm-d.ai/ipp-managed=true"

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

DELETE=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --delete) DELETE=true; shift ;;
        -h|--help) sed -n '2,38p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) log_error "Unknown option: $1"; exit 1 ;;
    esac
done

# =============================================================================
# Config validation
# =============================================================================
MISSING=()
for var in MAAS_EXTERNAL_ENDPOINT MAAS_EXTERNAL_MODEL MAAS_EXTERNAL_API_KEY; do
    if [ -z "${!var:-}" ]; then
        MISSING+=("$var")
    fi
done
if [ ${#MISSING[@]} -gt 0 ]; then
    log_error "Missing required config: ${MISSING[*]}"
    log_error "Set them in .env (see .env.example) and run 'make maas-external-model':"
    log_error "  MAAS_EXTERNAL_ENDPOINT  - remote OpenAI-compatible gateway FQDN (e.g. maas.apps.<other-cluster>)"
    log_error "  MAAS_EXTERNAL_MODEL     - model name as served by the remote endpoint (e.g. gpt-5.6-luna)"
    log_error "  MAAS_EXTERNAL_API_KEY   - API key accepted by the remote endpoint"
    exit 1
fi

MAAS_EXTERNAL_PATH="${MAAS_EXTERNAL_PATH:-/v1/chat/completions}"

# Client-facing name: lowercase, strip chars outside [a-z0-9-], collapse/trim
# hyphens. Matches the CRD name pattern (no dots): gpt-5.6-luna -> gpt-56-luna.
MODEL_NAME=$(echo "$MAAS_EXTERNAL_MODEL" | tr '[:upper:]' '[:lower:]' \
    | tr -cd 'a-z0-9-' | sed -e 's/-\{2,\}/-/g' -e 's/^-\+//' -e 's/-\+$//')
if [ -z "$MODEL_NAME" ]; then
    log_error "MAAS_EXTERNAL_MODEL '$MAAS_EXTERNAL_MODEL' sanitizes to an empty name"
    exit 1
fi

# =============================================================================
# Delete mode
# =============================================================================
if [ "$DELETE" = true ]; then
    log_step "Deleting external model: $MODEL_NAME"
    oc delete "externalmodel/$MODEL_NAME" -n llm --ignore-not-found=true
    oc delete "maasmodelref/$MODEL_NAME" -n llm --ignore-not-found=true
    oc delete "maassubscription/${MODEL_NAME}-free" "maassubscription/${MODEL_NAME}-premium" \
        "maasauthpolicy/${MODEL_NAME}-access" -n models-as-a-service --ignore-not-found=true
    oc delete "externalprovider/$PROVIDER_NAME" -n llm --ignore-not-found=true
    oc delete "secret/$SECRET_NAME" -n llm --ignore-not-found=true
    log_info "Deleted external model $MODEL_NAME resources"
    exit 0
fi

# =============================================================================
# Preflight
# =============================================================================
log_step "Preflight checks"

if ! oc whoami &>/dev/null; then
    log_error "Not logged into OpenShift cluster"
    exit 1
fi
log_info "Connected to: $(oc whoami --show-server)"

# Refuse to clobber a MaaSModelRef owned by a local LLMInferenceService with
# the same client-facing name (e.g. remote serves the same model name).
if oc get "maasmodelref/$MODEL_NAME" -n llm &>/dev/null; then
    KIND=$(oc get "maasmodelref/$MODEL_NAME" -n llm -o jsonpath='{.spec.modelRef.kind}' 2>/dev/null || echo "?")
    if [ "$KIND" != "ExternalModel" ]; then
        log_error "MaaSModelRef/$MODEL_NAME in llm already exists (modelRef.kind=$KIND)"
        log_error "The client-facing name '$MODEL_NAME' (sanitized from '$MAAS_EXTERNAL_MODEL') would clobber it"
        exit 1
    fi
    log_info "Re-deploying existing external model $MODEL_NAME"
fi

# TLS preflight (warn-only): the endpoint cert must be publicly trusted for the
# IPP to dial it. Cluster egress may succeed where this machine cannot.
if command -v curl &>/dev/null; then
    if ! curl -sI --max-time 10 "https://${MAAS_EXTERNAL_ENDPOINT}/" >/dev/null 2>&1; then
        log_warn "TLS preflight: could not reach https://${MAAS_EXTERNAL_ENDPOINT} from this machine"
        log_warn "May still be reachable from the cluster (egress/firewall); continuing"
    else
        log_info "TLS preflight: https://${MAAS_EXTERNAL_ENDPOINT} reachable, certificate trusted"
    fi
fi

# =============================================================================
# Ensure namespaces + API key Secret
# =============================================================================
log_step "Ensuring namespaces"
oc create namespace llm --dry-run=client -o yaml | oc apply -f - 2>/dev/null
oc label namespace llm opendatahub.io/dashboard=true --overwrite >/dev/null 2>&1 || true
oc create namespace models-as-a-service --dry-run=client -o yaml | oc apply -f - 2>/dev/null

log_step "Creating provider API key Secret: $SECRET_NAME (llm)"
oc create secret generic "$SECRET_NAME" -n llm \
    --from-literal="api-key=${MAAS_EXTERNAL_API_KEY}" \
    --dry-run=client -o yaml | oc apply -f - >/dev/null
oc label secret "$SECRET_NAME" -n llm "$IPP_LABEL" --overwrite >/dev/null
log_info "Secret $SECRET_NAME ready (labeled $IPP_LABEL for the IPP)"

# =============================================================================
# Render + apply
# =============================================================================
log_step "Deploying external model: $MODEL_NAME (target: $MAAS_EXTERNAL_MODEL @ $MAAS_EXTERNAL_ENDPOINT)"

RENDER_DIR=$(mktemp -d)
trap 'rm -rf "$RENDER_DIR"' EXIT

for f in "$TEMPLATE_DIR"/*.yaml; do
    sed -e "s|\${MAAS_EXTERNAL_NAME}|${MODEL_NAME}|g" \
        -e "s|\${MAAS_EXTERNAL_MODEL}|${MAAS_EXTERNAL_MODEL}|g" \
        -e "s|\${MAAS_EXTERNAL_ENDPOINT}|${MAAS_EXTERNAL_ENDPOINT}|g" \
        -e "s|\${MAAS_EXTERNAL_PATH}|${MAAS_EXTERNAL_PATH}|g" \
        "$f" > "$RENDER_DIR/$(basename "$f")"
done

log_info "Applying rendered manifests..."
oc apply --server-side=true -f "$RENDER_DIR"

# =============================================================================
# Wait for readiness
# =============================================================================
log_step "Waiting for external model to be ready"

log_info "Waiting for MaaSModelRef/$MODEL_NAME to be Ready..."
TIMEOUT=120
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    PHASE=$(oc get "maasmodelref/$MODEL_NAME" -n llm -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "$PHASE" = "Ready" ]; then
        log_info "MaaSModelRef/$MODEL_NAME is Ready"
        break
    fi
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done
if [ $ELAPSED -ge $TIMEOUT ]; then
    log_warn "MaaSModelRef/$MODEL_NAME may not be Ready after ${TIMEOUT}s (phase: ${PHASE:-unknown})"
    log_warn "Check: oc get externalmodel $MODEL_NAME -n llm -o jsonpath='{.status.conditions}'"
fi

# =============================================================================
# Summary
# =============================================================================
log_step "External model deployment summary"

echo ""
echo "ExternalModel:"
oc get externalmodel -n llm 2>/dev/null || echo "  (none)"

echo ""
echo "ExternalProvider:"
oc get externalprovider -n llm 2>/dev/null || echo "  (none)"

echo ""
echo "MaaSModelRefs:"
oc get maasmodelref -n llm -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,ENDPOINT:.status.endpoint' 2>/dev/null || echo "  (none)"

CLUSTER_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null || echo "")
if [ -n "$CLUSTER_DOMAIN" ]; then
    echo ""
    log_info "Client-facing model name: $MODEL_NAME (send this as 'model' in chat completions)"
    log_info "MaaS API: https://maas.${CLUSTER_DOMAIN}/maas-api/v1/models"
    log_info "Test: curl -sk https://maas.${CLUSTER_DOMAIN}/v1/chat/completions with a MaaS API key"
fi
