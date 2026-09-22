# LLMInferenceService `spec.rolloutStrategy` silently pruned on 3.5 (3.6+ only) — GPU workloads stuck with the RollingUpdate surge

**Status:** NOT FILED — and no filing planned: 3.6 implements the field
(Go type + regenerated CRD), so the gap is 3.5-only, and an API-field backport
to a z-stream would likely be declined per API stability policy. Known-issue +
operational workaround only. Re-open the question if a 3.5.z backport becomes
realistic or if the silent-pruning behavior is reported by others.
**Found:** 2026-09-22, cluster.internal.rhai-tmm.dev (rhai-tmm dev rig), RHOAI
**3.5.1 GA** (released 2026-09-21 — ships the same stale CRD as the nightly;
verified against the GA build's pinned manifests).
**Workaround in this repo:** operational only (not in git, not indexed in
workarounds.md — no Jira exists and 3.6 fixes it): delete the Deployment and
let KServe recreate it, which lands the pod on the warm-cache node.

## Scope (source-traced)

| Lineage | Go type (`WorkloadSpec.RolloutStrategy`) | CRD (minimal) |
|---|---|---|
| `red-hat-data-services/kserve:rhoai-3.5` (3.5.1 GA + nightly) | ✗ absent | ✗ controller-gen v0.19.0, no field |
| `red-hat-data-services/kserve:rhoai-3.6` | ✓ present | ✓ controller-gen v0.21.0, field present (top-level + `prefill`) |
| `opendatahub-io/kserve:release-v0.17` | ✓ | ✓ |

- The GA 3.5.1 build's manifest pin (from `get_all_manifests.sh` on
  `red-hat-data-services/rhods-operator` branch `rhoai-3.5.1`) is
  `red-hat-data-services/kserve:rhoai-3.5@ca4a57f8300033eaac5ccb8acee034bf2d86096b`
  — the CRD there omits the field, as does the `rhoai-3.5` branch tip (so the
  next rebuild does not fix it).
- 3.6 (`rhoai-3.6` branch / `release-v0.17`) has the field in the Go type AND
  the regenerated CRDs. Also note the 3.5 branch is behind on other API
  additions (`Runtime`, `TrustRemoteCode`).

## Symptom

Setting `spec.rolloutStrategy` on an LLMInferenceService has **no effect and no
error** — the field silently disappears from the stored object:

```bash
oc patch llminferenceservice qwen3-6-35b-a3b-fp8 -n llm --type=merge \
  -p '{"spec":{"rolloutStrategy":{"maxSurge":0,"maxUnavailable":1}}}'
oc get llminferenceservice qwen3-6-35b-a3b-fp8 -n llm \
  -o jsonpath='{.spec.rolloutStrategy}'   # empty — pruned
```

The underlying impact: single-replica GPU modelcar workloads cannot avoid the
Deployment's default `RollingUpdate 25%/25%` surge. On a single-GPU-node
cluster the surge pod goes `Pending` (the serving pod holds the only GPU), the
cluster autoscaler spins up another GPU node, and the new pod starts a **cold
40 GB modelcar pull** on every redeploy — minutes of grind instead of a
seconds-long warm-cache restart. (The old pod is only killed once the new one
is Ready, so the GPU never frees up for the surge pod.)

## Root cause (empirically proven live)

Not schema pruning. Verified on the live rig on 2026-09-22:

1. Patched the CRD's served v1alpha2 schema to add `rolloutStrategy` (plus a
   control field `ztest`) — the schema accepted both.
2. Writing `spec.rolloutStrategy` (update AND fresh create) was **stripped
   every time** — including the control field, which has no Go type anywhere.
   `managedFields` even recorded the patch intent while the stored object
   lacked the field. `status.storedVersions` is `["v1alpha2"]` (no conversion
   on write), so the conversion webhook was ruled out.
3. The mechanism: **four mutating webhooks run on every LLMInferenceService
   CREATE+UPDATE** — `llminferenceservice.kserve-webhook-server.{v1alpha1,
   v1alpha2}.defaulter` and `mutating.odh-model-controller.opendatahub.io/
   connection-llmisvc-{v1alpha1,v1alpha2}`. They deserialize the object into
   their Go types and re-serialize; the running binaries are built from the
   `rhoai-3.5` branch, whose `WorkloadSpec` has no `RolloutStrategy` — so any
   field their types don't know is dropped from the webhook response, which is
   what gets stored.

**Implication: a CRD-only fix cannot work.** The gate is the controller/webhook
binaries' Go types; the fix requires the `rhoai-3.5` branch to carry the type
(i.e., sync with `opendatahub-io/kserve:release-v0.17` or cherry-pick
`llm_inference_service_types.go` + CRD regen + rebuilt images).

## Detection

```bash
oc patch llminferenceservice <name> -n llm --type=merge \
  -p '{"spec":{"rolloutStrategy":{"maxSurge":0,"maxUnavailable":1}}}'
oc get llminferenceservice <name> -n llm -o jsonpath='{.spec.rolloutStrategy}'
# empty  = pruned (this issue); non-empty = field expressible (3.6+)

oc get deploy <name>-kserve -n llm -o jsonpath='{.spec.strategy}'
# RollingUpdate 25%/25% persists on 3.5 regardless of what you set
```

## Workaround (operational)

For the redeploy-lands-on-a-cold-node problem:

```bash
oc delete deployment <llmisvc-name>-kserve -n llm
```

KServe's llmisvc controller recreates the Deployment from the
LLMInferenceService; with a single GPU node the pod lands on the warm-cache
node — the cached modelcar makes the restart seconds instead of a 40 GB grind.
Do **not** patch the Deployment's `spec.strategy` to `Recreate`: the KServe
controller owns `spec.strategy` (managedFields) and reverts it on the next
reconcile.

Once the field is expressible (3.6+), `rolloutStrategy: {maxSurge: 0,
maxUnavailable: 1}` gives the same behavior declaratively for `replicas: 1`
(scale down before up — old pod's GPU freed first). There is still no literal
`type: Recreate` in the LLMInferenceService API even in 3.6.

## Remove when

RHOAI upgraded to 3.6 (field expressible, this entry is no longer relevant), or
— unlikely — a 3.5.z backport of the type + CRD.

## Steps to reproduce

1. RHOAI 3.5.x (3.5.1 GA or nightly; the `rhoai-3.5` branch tip is also stale).
2. `oc patch llminferenceservice <name> -n llm --type=merge -p
   '{"spec":{"rolloutStrategy":{"maxSurge":0,"maxUnavailable":1}}}'`
3. `oc get llminferenceservice <name> -n llm -o yaml` — no `rolloutStrategy`
   in the stored spec, no warning, no error event.
4. Confirm the mechanism: `oc get mutatingwebhookconfigurations -o json | jq
   -r '.items[].webhooks[].name'` — the four LLMInferenceService mutators above
   run on CREATE+UPDATE and strip fields their Go types don't know.
