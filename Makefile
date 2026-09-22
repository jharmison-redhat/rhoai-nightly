# Makefile for RHOAI 3.x Nightly GitOps
#
# Default workflow: Run targets individually and verify each step
# Autonomous workflow: make all

# Load .env file if it exists
ifneq (,$(wildcard ./.env))
    include .env
    export
endif

.PHONY: help gpu cpu icsp uwm setup infra secrets gitops deploy bootstrap status all clean undeploy configure-repo scale refresh restart-catalog sync sync-app sync-disable sync-enable refresh-apps dedicate-masters maas maas-uninstall maas-verify maas-model maas-model-status maas-model-delete maas-external-model maas-external-model-delete maas-subscriptions observability observability-uninstall evalhub evalhub-uninstall autorag autorag-uninstall diagnose compare cleanup-projects preflight validate-config kueue-quota

# Applications owned by our two ApplicationSets, plus `cluster-config` (the
# root app-of-apps that owns those ApplicationSets — included by name so the
# bulk targets keep the ApplicationSet objects aligned with git). Excludes
# out-of-band apps managed by their own scripts (instance-maas,
# instance-maas-observability, instance-evalhub, instance-autorag) and other
# GitOps stacks sharing this ArgoCD namespace (cert-manager, oauth,
# app-of-apps) — they carry no ownerReferences to our ApplicationSets.
RHOAI_APPS = oc get applications.argoproj.io -n openshift-gitops -o json | \
	jq -r '.items[] | select(((.metadata.ownerReferences // []) | any(.kind == "ApplicationSet" and (.name == "cluster-operators-applicationset" or .name == "cluster-oper-instances-applicationset"))) or .metadata.name == "cluster-config") | "application.argoproj.io/" + .metadata.name'

# Default target - run everything
.DEFAULT_GOAL := all

help:
	@echo "RHOAI 3.x Nightly GitOps"
	@echo ""
	@echo "Autonomous (recommended for clean clusters):"
	@echo "  make all          - Full setup: infra → secrets → gitops → deploy → sync → maas"
	@echo ""
	@echo "Phase 1: Infrastructure"
	@echo "  make infra        - Run icsp, cpu, gpu, uwm (no pull-secret, handled by secrets)"
	@echo "  make icsp         - Create ICSP (configure registry mirror)"
	@echo "  make gpu          - Create GPU MachineSet (waits for node Ready)"
	@echo "  make cpu          - Create CPU MachineSet m6a.4xlarge (waits for node Ready)"
	@echo "  make uwm          - Enable User Workload Monitoring (waits for Prometheus pod)"
	@echo "  make dedicate-masters - Remove worker role from masters (optional)"
	@echo ""
	@echo "Phase 2: Secrets"
	@echo "  make secrets      - Setup pull-secret (auto-detects mode)"
	@echo "                      Mode A: QUAY_USER/QUAY_TOKEN set → manual credentials"
	@echo "                      Mode B: Bootstrap repo access → External Secrets"
	@echo ""
	@echo "Phase 3: GitOps"
	@echo "  make gitops       - Install GitOps operator + ArgoCD (waits for ready)"
	@echo ""
	@echo "Phase 4-5: Deploy and Sync"
	@echo "  make deploy       - Deploy root app (creates apps with sync DISABLED)"
	@echo "  make sync         - Sync all apps one-by-one in dependency order"
	@echo "  make sync-app APP=<name> - Sync a single app (e.g., APP=nfd)"
	@echo ""
	@echo "Shortcuts:"
	@echo "  make setup        - Run infra + secrets (pre-GitOps setup)"
	@echo "  make bootstrap    - Run gitops + deploy"
	@echo ""
	@echo "Diagnostics & Validation:"
	@echo "  make diagnose       - Full cluster diagnosis (connectivity, config, RHOAI, MaaS)"
	@echo "  make compare        - Which build is where: git pins vs clusters vs quay (exit 2 = drift)"
	@echo "                        ARGS=\"--no-cluster\" offline, \"--repos\" adds upstream commits,"
	@echo "                        \"--fixes\" hunts ledger Jira keys on the build branch,"
	@echo "                        \"--against :rhoai-3.5\" diffs another catalog build vs ours,"
	@echo "                        \"--image :rhoai-3.6-ea.1-nightly\" adds an explicit reference point"
	@echo "  make preflight      - Quick readiness check (pass/warn/fail)"
	@echo "  make validate-config - Validate .env against cluster capabilities"
	@echo "  make status         - Show ArgoCD application status"
	@echo "  make refresh        - Refresh RHOAI apps from git (hard refresh, no sync, parallel)"
	@echo "  make restart-catalog - Restart catalog pod and operator (force image pull)"
	@echo ""
	@echo "ArgoCD Sync Control:"
	@echo "  make sync-disable - Disable auto-sync on RHOAI apps (for manual changes)"
	@echo "  make sync-enable  - Re-enable auto-sync on RHOAI apps"
	@echo "  make refresh-apps - Refresh and sync RHOAI apps (one-time, keeps current sync setting)"
	@echo ""
	@echo "MaaS (Models as a Service):"
	@echo "  make maas           - Install MaaS platform (PostgreSQL+PVC, Gateway, Authorino TLS)"
	@echo "                        Does NOT install the observability cascade — run 'make observability'"
	@echo "                        separately once the cluster is healthy (settle-gate protects masters)."
	@echo "  make maas-model [MODEL=auto] - Deploy model (auto, qwen3-6-27b-fp8, granite-tiny-gpu, simulator, all)"
	@echo "                                 Default 'auto' picks by GPU VRAM: >=40Gi->qwen3-6-27b-fp8, GPU<40Gi->granite-tiny-gpu, no GPU->simulator"
	@echo "  make maas-model-status - Show deployed model status"
	@echo "  make maas-model-delete [MODEL=qwen3-6-27b-fp8] - Remove a deployed model"
	@echo "  make maas-external-model - Register external model via MaaS External Models APIs (3.5+)"
	@echo "                             Requires MAAS_EXTERNAL_ENDPOINT, MAAS_EXTERNAL_MODEL,"
	@echo "                             MAAS_EXTERNAL_API_KEY in .env (MAAS_EXTERNAL_PATH optional)"
	@echo "  make maas-external-model-delete - Remove the external model"
	@echo "  make maas-subscriptions - Sync unified MaaS subscriptions + auth policy"
	@echo "                        with all registered models (auto-called by model deploys)"
	@echo "  make maas-verify    - Verify MaaS (deploy simulator, test API, auth, rate limits)"
	@echo "  make maas-uninstall - Remove MaaS resources created by install-maas.sh"
	@echo "  make observability  - (Re-)install MaaS observability only (UWM + monitors + Kuadrant)"
	@echo "  make observability-uninstall - Uninstall MaaS observability (leaves UWM ConfigMap in place)"
	@echo ""
	@echo "Eval Hub:"
	@echo "  make evalhub        - Enable eval-hub (EvalHub + MLflow + DSPA in evalhub-tenant ns)"
	@echo "                        Creates instance-evalhub ArgoCD Application; orthogonal to MaaS / observability."
	@echo "  make evalhub-uninstall - Disable eval-hub (deletes Application; ArgoCD prunes resources)"
	@echo ""
	@echo "AutoML/AutoRAG (Tech Preview):"
	@echo "  make autorag        - Enable AutoML/AutoRAG test tenant (DSPA + pgvector in autorag-tenant ns)"
	@echo "                        Creates instance-autorag ArgoCD Application; orthogonal to MaaS / observability / eval-hub."
	@echo "  make autorag-uninstall - Disable test tenant (deletes Application; ArgoCD prunes resources)"
	@echo ""
	@echo "Cleanup:"
	@echo "  make clean        - Full cleanup (runs undeploy + removes leftover operators)"
	@echo "  make undeploy     - Remove ArgoCD apps only (keeps GitOps operator)"
	@echo "  make cleanup-projects - Audit stale dashboard projects (audit only by default)"
	@echo "                        ARGS=\"--delete-empty 30 --delete-stopped 45 --dry-run\" to delete"
	@echo ""
	@echo "Scaling:"
	@echo "  make scale NAME=<machineset> REPLICAS=<N|+N|-N>"
	@echo "                      Scale a MachineSet (e.g., REPLICAS=2 or REPLICAS=+1)"
	@echo ""
	@echo "Configuration (for forks):"
	@echo "  make configure-repo - Update repo URLs in applicationsets"
	@echo "                        Set GITOPS_REPO_URL and GITOPS_BRANCH in .env"
	@echo ""
	@echo "To change RHOAI version, edit components/operators/rhoai-operator/base/catalogsource.yaml"
	@echo ""

# Pre-GitOps: GPU MachineSet
gpu:
	@scripts/create-gpu-machineset.sh

# Pre-GitOps: CPU Worker MachineSet
cpu:
	@scripts/create-cpu-machineset.sh

# Pre-GitOps: ICSP (configure registry mirror)
icsp:
	@scripts/create-icsp.sh

# Pre-GitOps: User Workload Monitoring
# Owned here (not in install-observability.sh) because UWM is a foundational
# capability other workloads depend on, and its rollout adds measurable
# memory pressure best applied while the control plane is idle.
uwm:
	@scripts/enable-uwm.sh

# Infrastructure setup (icsp, workers, UWM — pull-secret handled by secrets)
# Each script waits for its resources to be ready before returning
# CPU before GPU - cheaper instances provision faster
infra: icsp cpu gpu uwm
	@echo ""
	@echo "Infrastructure setup complete!"

# Secrets - auto-detects mode (manual credentials or External Secrets)
secrets:
	@scripts/setup-secrets.sh

# All pre-GitOps setup (infra + secrets)
setup: infra secrets
	@echo ""
	@echo "Pre-GitOps setup complete!"

# Install GitOps operator and ArgoCD
gitops:
	@scripts/install-gitops.sh

# Deploy root application (triggers all GitOps syncs)
deploy:
	@scripts/deploy-apps.sh

# Bootstrap GitOps (install + deploy)
bootstrap: gitops deploy

# Show ArgoCD status
status:
	@scripts/status.sh

# Comprehensive cluster diagnosis (exit 2 = warnings only, still OK)
diagnose:
	@scripts/diagnose.sh || [ $$? -eq 2 ]

# Compare RHOAI builds across git pins, clusters and quay (exit 2 = drift found)
# Pass options through with ARGS, e.g. make compare ARGS="--no-cluster --repos"
compare:
	@scripts/compare-builds.sh $(ARGS)

# Audit stale RHOAI dashboard projects; deletes ONLY with an explicit --delete-* flag
# make cleanup-projects ARGS="--delete-empty 30 --delete-stopped 45 --dry-run"
cleanup-projects:
	@scripts/cleanup-stale-projects.sh $(ARGS)

# Quick cluster readiness check (exit 2 = warnings only, still OK)
preflight:
	@scripts/preflight-check.sh || [ $$? -eq 2 ]

# Validate .env against cluster capabilities (exit 2 = warnings only, still OK)
validate-config:
	@scripts/validate-config.sh || [ $$? -eq 2 ]

# Full autonomous run
# Workflow: setup (infra + secrets) → bootstrap (gitops + deploy) → sync
all: setup bootstrap sync maas
	@echo ""
	@echo "Full setup complete!"
	@echo "RHOAI 3.x nightly with MaaS is now deploying."

# Remove ArgoCD apps with cascade deletion (keeps GitOps operator)
# ArgoCD deletes managed resources before removing the app
# Usage: make undeploy [DRY_RUN=true] [SKIP_CONFIRM=true]
undeploy:
	@scripts/undeploy.sh $(if $(DRY_RUN),--dry-run) $(if $(SKIP_CONFIRM),-y)

# Full cleanup including pre-installed operators
# Chains: undeploy -> clean
# Usage: make clean [DRY_RUN=true] [SKIP_CONFIRM=true]
clean: undeploy
	@scripts/clean.sh $(if $(DRY_RUN),--dry-run) $(if $(SKIP_CONFIRM),-y)

# Configure repo URLs for forks
configure-repo:
	@scripts/configure-repo.sh

# Scale a MachineSet
scale:
	@scripts/scale-machineset.sh --name "$(NAME)" --replicas "$(REPLICAS)"

# Size the Kueue Cohort quota from the cluster's provisionable capacity
# (outside GitOps — survives ArgoCD via ignoreDifferences; re-run after
# make refresh-apps, which resets quota to the git defaults)
kueue-quota:
	@scripts/update-kueue-quota.sh

# GitOps refresh - pull latest from git without triggering sync
# Use this to update ArgoCD's view of git state
# Scopes to ApplicationSet-owned apps (see RHOAI_APPS) and runs in parallel.
refresh:
	@echo "Refreshing RHOAI apps from git (hard refresh, parallel)..."
	@$(RHOAI_APPS) | xargs -P 8 -I {} oc annotate {} -n openshift-gitops argocd.argoproj.io/refresh=hard --overwrite
	@echo "All RHOAI apps refreshed from git."
	@echo "Apps will show OutOfSync if git differs from cluster."
	@echo "Run 'make sync' to apply changes, or 'make status' to check."

# Restart catalog and operator pods + re-resolve Subscription
# Use after updating catalog image and syncing from git
# Pass RESUB=false to skip the Subscription delete (just bounce pods).
# Pass FORCE_RESUB=true to delete the Subscription even when the catalog version
# is unchanged (intentional re-resolve; the default same-version guard otherwise
# skips the delete to avoid the orphaned-CSV deadlock).
restart-catalog:
	@scripts/restart-catalog.sh $(if $(filter false,$(RESUB)),--no-resub) $(if $(filter true,$(FORCE_RESUB)),--force-resub)

# Sync all apps one-by-one in dependency order (RECOMMENDED)
sync:
	@scripts/sync-apps.sh

# Sync a single app and trigger immediate sync
sync-app:
	@echo "Enabling sync for $(APP)..."
	@oc patch application.argoproj.io/$(APP) -n openshift-gitops --type=merge \
	  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
	@echo "Triggering sync..."
	@oc annotate application.argoproj.io/$(APP) -n openshift-gitops \
	  argocd.argoproj.io/refresh=normal --overwrite
	@echo "Sync enabled and triggered for $(APP)"

# Disable auto-sync on ApplicationSet-owned RHOAI apps (for manual changes)
sync-disable:
	@echo "Disabling auto-sync on RHOAI apps (parallel)..."
	@$(RHOAI_APPS) | xargs -P 8 -I {} oc patch {} -n openshift-gitops --type=merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
	@echo "Auto-sync disabled. You can now make manual changes."
	@echo "Re-enable with: make sync-enable"

# Re-enable auto-sync on ApplicationSet-owned RHOAI apps
sync-enable:
	@echo "Re-enabling auto-sync on RHOAI apps (parallel)..."
	@$(RHOAI_APPS) | xargs -P 8 -I {} oc patch {} -n openshift-gitops --type=merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
	@echo "Auto-sync re-enabled."

# Refresh from git AND sync all RHOAI apps (one-time, does not change auto-sync setting)
# Use when auto-sync is disabled and you want to apply latest from git.
# Scopes to ApplicationSet-owned apps + cluster-config (see RHOAI_APPS) and runs
# in parallel — out-of-band apps (instance-maas, instance-evalhub, ...) are
# managed by their own scripts and are left alone.
# The explicit sync operations reset the Cohort quota to the git defaults
# (ignoreDifferences protects against selfHeal, not syncs), so re-size after.
refresh-apps:
	@echo "Refreshing RHOAI apps from git (parallel)..."
	@$(RHOAI_APPS) | xargs -P 8 -I {} oc annotate {} -n openshift-gitops argocd.argoproj.io/refresh=hard --overwrite
	@echo "Triggering sync on RHOAI apps (parallel)..."
	@$(RHOAI_APPS) | xargs -P 8 -I {} oc patch {} -n openshift-gitops --type=merge \
	  -p '{"operation":{"initiatedBy":{"username":"make"},"sync":{"prune":true}}}'
	@echo "All RHOAI apps refreshed and syncing."
	@$(MAKE) --no-print-directory kueue-quota

# Remove worker role from master nodes (run after workers are Ready)
dedicate-masters:
	@echo "Checking for Ready worker nodes..."
	@WORKERS=$$(oc get nodes -l node-role.kubernetes.io/worker,!node-role.kubernetes.io/master --no-headers 2>/dev/null | grep -c " Ready" || echo 0); \
	if [ "$$WORKERS" -eq 0 ]; then \
		echo "ERROR: No dedicated worker nodes are Ready. Create workers first with 'make gpu' or 'make cpu'"; \
		exit 1; \
	fi; \
	echo "Found $$WORKERS Ready worker node(s)"
	@echo "Removing worker role from master nodes..."
	@oc label nodes -l node-role.kubernetes.io/master node-role.kubernetes.io/worker- 2>/dev/null || true
	@echo "Master nodes are now dedicated (no longer schedulable for regular workloads)"
	@oc get nodes

# Install MaaS (PostgreSQL, Gateway, Authorino TLS)
maas:
	@scripts/install-maas.sh

# Deploy MaaS model(s) (default: auto, or MAAS_MODELS from .env)
# Usage: make maas-model [MODEL=qwen3-6-27b-fp8|granite-tiny-gpu|simulator|all]
maas-model:
	@scripts/setup-maas-model.sh $(or $(MODEL),)

# Show status of deployed MaaS models
maas-model-status:
	@scripts/setup-maas-model.sh --status

# Delete deployed MaaS model(s)
# Usage: make maas-model-delete [MODEL=qwen3-6-27b-fp8|granite-tiny-gpu|simulator|all]
maas-model-delete:
	@scripts/setup-maas-model.sh --delete $(or $(MODEL),)

# Register external model via MaaS External Models APIs (RHOAI 3.5+)
# Requires MAAS_EXTERNAL_ENDPOINT, MAAS_EXTERNAL_MODEL, MAAS_EXTERNAL_API_KEY
# in .env (MAAS_EXTERNAL_PATH optional) — see .env.example
maas-external-model:
	@scripts/setup-maas-external-model.sh

# Remove the external model registered by maas-external-model
maas-external-model-delete:
	@scripts/setup-maas-external-model.sh --delete

# Sync the unified MaaS subscriptions + auth policy with all registered
# models (create-if-missing, patch-if-changed; modelRefs from live state)
maas-subscriptions:
	@scripts/setup-maas-subscriptions.sh

# Verify MaaS deployment (deploy test model, test API, auth, rate limits)
maas-verify:
	@scripts/verify-maas.sh

# Remove MaaS resources created by install-maas.sh
maas-uninstall:
	@scripts/uninstall-maas.sh

# Install MaaS observability (UWM + monitors + Kuadrant)
observability: ## Install MaaS observability (UWM + monitors + Kuadrant)
	@chmod +x scripts/install-observability.sh
	@scripts/install-observability.sh

# Uninstall MaaS observability
observability-uninstall: ## Uninstall MaaS observability
	@chmod +x scripts/install-observability.sh
	@scripts/install-observability.sh --uninstall

# Enable eval-hub (creates dedicated instance-evalhub ArgoCD Application)
# Orthogonal to MaaS / observability — does not modify the instance-rhoai overlay
evalhub: ## Enable eval-hub (EvalHub + MLflow + DSPA in evalhub-tenant ns)
	@chmod +x scripts/install-evalhub.sh
	@scripts/install-evalhub.sh

# Disable eval-hub (deletes instance-evalhub Application; ArgoCD prunes resources)
evalhub-uninstall: ## Disable eval-hub (deletes Application)
	@chmod +x scripts/install-evalhub.sh
	@scripts/install-evalhub.sh --uninstall

# Enable AutoML/AutoRAG Tech Preview test tenant (DSPA + pgvector in autorag-tenant ns)
# Orthogonal to MaaS / observability / eval-hub — dashboard flags already in rhoai-instance base
autorag: ## Enable AutoML/AutoRAG test tenant (DSPA + pgvector in autorag-tenant ns)
	@chmod +x scripts/install-autorag.sh
	@scripts/install-autorag.sh

# Disable AutoML/AutoRAG test tenant (deletes instance-autorag Application; ArgoCD prunes resources)
autorag-uninstall: ## Disable AutoML/AutoRAG test tenant (deletes Application)
	@chmod +x scripts/install-autorag.sh
	@scripts/install-autorag.sh --uninstall
