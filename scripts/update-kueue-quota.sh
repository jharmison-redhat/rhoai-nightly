#!/usr/bin/env bash
#
# update-kueue-quota.sh - Size the Kueue Cohort (rhoai) quota from the
# cluster's provisionable worker capacity (autoscaler max x per-node
# allocatable), managed OUTSIDE GitOps.
#
# The Cohort's /spec/resourceGroups is covered by ignoreDifferences on the
# instance-kueue Application, so this patch survives ArgoCD. Git holds the
# defaults for this cluster's shape; run this to resize for a different
# cluster. 'make refresh-apps' runs this automatically after its syncs (an
# explicit sync resets quota to the git defaults; auto-sync/selfHeal never
# does — ignored diffs are not acted on).
#
# Inputs (.env, exported by the Makefile):
#   CPU_INSTANCE_TYPE (default: m6a.4xlarge)   CPU_MAX (default: 3)
#   GPU_INSTANCE_TYPE (default: g6e.2xlarge)   GPU_MAX (default: 3)
#
# Capacity is looked up live-first (a node with the instance type answers with
# its allocatable); a small static map covers fresh installs with no nodes yet.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

APP_NAME=instance-kueue
COHORT_NAME=rhoai
CPU_TYPE="${CPU_INSTANCE_TYPE:-m6a.4xlarge}"
CPU_MAX="${CPU_MAX:-3}"
GPU_TYPE="${GPU_INSTANCE_TYPE:-g6e.2xlarge}"
GPU_MAX="${GPU_MAX:-3}"

check_cluster_connection

static_capacity() {
    case "$1" in
        m6a.4xlarge)  echo "16|64|0" ;;
        g6e.2xlarge)  echo "8|32|1" ;;
        g5.2xlarge)   echo "8|32|1" ;;
        g4dn.2xlarge) echo "8|32|1" ;;
        m5.4xlarge)   echo "16|64|0" ;;
        m6i.4xlarge)  echo "16|64|0" ;;
        *)            echo "" ;;
    esac
}

mem_to_gi() {
    case "$1" in
        *Ki) echo $(( (${1%Ki} + 1048575) / 1048576 )) ;;
        *Mi) echo $(( (${1%Mi} + 1023) / 1024 )) ;;
        *Gi) echo "${1%Gi}" ;;
        *)   echo 0 ;;
    esac
}

cpu_to_cores() {
    case "$1" in
        *m) echo $(( (${1%m} + 999) / 1000 )) ;;
        *)  echo "$1" ;;
    esac
}

node_capacity() {
    local type="$1" gpu="$2"
    local sel="node.kubernetes.io/instance-type=$type"
    [ "$gpu" = "true" ] && sel="$sel,node-role.kubernetes.io/gpu"
    local cpu mem gpus="0"
    cpu=$(oc get nodes -l "$sel" -o jsonpath='{.items[0].status.allocatable.cpu}' 2>/dev/null || true)
    if [ -n "$cpu" ]; then
        mem=$(oc get nodes -l "$sel" -o jsonpath='{.items[0].status.allocatable.memory}' 2>/dev/null || true)
        if [ "$gpu" = "true" ]; then
            gpus=$(oc get nodes -l "$sel" -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null || true)
            [ -z "$gpus" ] && gpus=1
        fi
        echo "$(cpu_to_cores "$cpu")|$(mem_to_gi "$mem")|$gpus"
        return 0
    fi
    static_capacity "$type"
}

CPU_CAP=$(node_capacity "$CPU_TYPE" false)
GPU_CAP=$(node_capacity "$GPU_TYPE" true)

if [ -z "$CPU_CAP" ] || [ -z "$GPU_CAP" ]; then
    log_error "Unknown instance type (no live node and no static entry): ${CPU_CAP:+} $CPU_TYPE / $GPU_TYPE"
    exit 1
fi

CPU_VCPU=${CPU_CAP%%|*}
CPU_MEM=$(cut -d'|' -f2 <<< "$CPU_CAP")
GPU_VCPU=${GPU_CAP%%|*}
GPU_MEM=$(cut -d'|' -f2 <<< "$GPU_CAP")
GPU_PER_NODE=$(cut -d'|' -f3 <<< "$GPU_CAP")

QUOTA_CPU=$(( CPU_MAX * CPU_VCPU + GPU_MAX * GPU_VCPU ))
QUOTA_MEM=$(( CPU_MAX * CPU_MEM + GPU_MAX * GPU_MEM ))
QUOTA_GPU=$(( GPU_MAX * GPU_PER_NODE ))

log_info "Cohort '$COHORT_NAME' quota: ${QUOTA_CPU} cpu / ${QUOTA_MEM}Gi / ${QUOTA_GPU} gpu"
log_info "  CPU: ${CPU_MAX}x ${CPU_TYPE} (${CPU_VCPU} cpu/${CPU_MEM}Gi each) + GPU: ${GPU_MAX}x ${GPU_TYPE} (${GPU_VCPU} cpu/${GPU_MEM}Gi/${GPU_PER_NODE} gpu each)"

if oc get application "$APP_NAME" -n openshift-gitops >/dev/null 2>&1; then
    proper=$(oc get application "$APP_NAME" -n openshift-gitops -o json | jq '[.spec.ignoreDifferences[]? | select(.group == "kueue.x-k8s.io" and .kind == "Cohort" and ((.jsonPointers // []) | index("/spec/resourceGroups")))] | length')
    if [ "$proper" = "0" ]; then
        broken=$(oc get application "$APP_NAME" -n openshift-gitops -o json | jq '.spec.ignoreDifferences | to_entries[]? | select(.value.group == "kueue.x-k8s.io" and .value.kind == "Cohort") | .key' | head -1)
        if [ -n "$broken" ]; then
            oc patch application "$APP_NAME" -n openshift-gitops --type=json -p "[{\"op\":\"replace\",\"path\":\"/spec/ignoreDifferences/$broken\",\"value\":{\"group\":\"kueue.x-k8s.io\",\"kind\":\"Cohort\",\"jsonPointers\":[\"/spec/resourceGroups\"]}}]" >/dev/null
        else
            oc patch application "$APP_NAME" -n openshift-gitops --type=json -p '[{"op":"add","path":"/spec/ignoreDifferences/-","value":{"group":"kueue.x-k8s.io","kind":"Cohort","jsonPointers":["/spec/resourceGroups"]}}]' >/dev/null
        fi
        log_info "Added Cohort ignoreDifferences (jsonPointers) to the $APP_NAME Application"
    fi
fi

wait_start=$(date +%s)
while ! oc get cohorts.kueue.x-k8s.io "$COHORT_NAME" >/dev/null 2>&1; do
    elapsed=$(($(date +%s) - wait_start))
    if [ $elapsed -ge 120 ]; then
        log_warn "Cohort '$COHORT_NAME' not found after 120s — quota left at git defaults."
        log_warn "Re-run 'make kueue-quota' once instance-kueue is Synced (make status)."
        exit 0
    fi
    printf "  Waiting for Cohort '%s' (%ds)...\r" "$COHORT_NAME" "$elapsed"
    sleep 5
done
echo ""

oc patch cohorts.kueue.x-k8s.io "$COHORT_NAME" --type=merge -p "{\"spec\":{\"resourceGroups\":[{\"coveredResources\":[\"cpu\",\"memory\"],\"flavors\":[{\"name\":\"default\",\"resources\":[{\"name\":\"cpu\",\"nominalQuota\":\"${QUOTA_CPU}\"},{\"name\":\"memory\",\"nominalQuota\":\"${QUOTA_MEM}Gi\"}]}]},{\"coveredResources\":[\"nvidia.com/gpu\"],\"flavors\":[{\"name\":\"l40s\",\"resources\":[{\"name\":\"nvidia.com/gpu\",\"nominalQuota\":\"${QUOTA_GPU}\"}]}]}]}}"

log_info "Cohort '$COHORT_NAME' quota patched (outside GitOps — re-run after make refresh-apps if it resets)"
