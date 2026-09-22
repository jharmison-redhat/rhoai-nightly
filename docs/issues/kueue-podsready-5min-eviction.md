# Kueue `gangScheduling: ByWorkload` hardcodes a 5m PodsReady timeout — LLM workloads evicted in a loop before the model loads

**Status:** NOT FILED — and no bug to file: the fix is already merged upstream
and tracked. This file documents the trap (still shipped in `stable-v1.4`), the
workaround, and the remove-when, so nobody re-enables gang scheduling on this
rig.
**Found:** 2026-09-22, cluster.internal.rhai-tmm.dev (rhai-tmm dev rig), RHOAI
3.5.1 nightly (`rhods-operator.3.5.1`), **kueue-operator v1.4.2** (channel
`stable-v1.4`).
**Workaround in this repo:** `components/instances/kueue-instance/kueue.yaml` —
the entire `gangScheduling` block removed (workarounds.md **A14**).
**Temporary** — restore only as an explicit `byWorkload.timeoutSeconds` (or
`policy: None`) once kueue-operator ≥ 2ec61a1 (1.5.x) reaches the channel.

## Upstream status (re-searched 2026-09-22)

- Fix: [openshift/kueue-operator commit 2ec61a1](https://github.com/openshift/kueue-operator/commit/2ec61a163a7ec00382251ad8451745e29d16142f)
  "Allow configuration of waitForPodsReady feature" (MaysaMacedo, merged
  2026-08-21) — adds `config.gangScheduling.byWorkload.timeoutSeconds`
  (default 1800s, min 30 / max 86400), `recoveryTimeoutSeconds`,
  `requeuingStrategy` (backoff + retryLimit), and a new `ByWorkloadDefaults`
  policy. Tracked as [OCPSTRAT-3301](https://redhat.atlassian.net/browse/OCPSTRAT-3301)
  (cluster/operator-level `waitForPodsReady` configuration, **Kueue 1.5**;
  docs story [OSDOCS-22178](https://redhat.atlassian.net/browse/OSDOCS-22178),
  labeled 5.0-top-priority / Kueue-1.5).
- Next step (per-workload timeout overrides): [OCPKUEUE-862](https://redhat.atlassian.net/browse/OCPKUEUE-862)
  / [OCPSTRAT-3594](https://redhat.atlassian.net/browse/OCPSTRAT-3594)
  (Kueue 1.6; upstream KEP [kueue#12776](https://github.com/kubernetes-sigs/kueue/pull/12776)).
- [OCPKUEUE-843](https://redhat.atlassian.net/browse/OCPKUEUE-843) (M1 manual
  test) confirms the post-fix `policy: None` behavior: operator sets
  `waitForPodsReady` timeout to **one year** with `blockAdmission: false` —
  eviction-free either way.
- Our channel `stable-v1.4` tops out at **v1.4.2** (catalog offers only
  stable-v1.3 → v1.3.2 and stable-v1.4 → v1.4.2) — the fixed operator is not
  installable on this cluster as of 2026-09-22.

## Symptom

GPU LLMInferenceService (`qwen3-6-27b-fp8`, 30.9 GB modelcar + vLLM weight
load) pods are deleted every ~5 minutes; the LLMInferenceService never goes
Ready. Event cycle in the `llm` namespace:

```
Pulled    Successfully pulled image ...modelcar... in 3.9s (Image size: 30914601776 bytes)
Started   Started container main
Unhealthy Startup probe failed: Get "https://10.131.2.27:8000/health": connection refused   ← vLLM still loading
Killing   Stopping container main / Stopping container modelcar                              ← ~4m37s after start
SuccessfulCreate Created pod: <next one>                                                      ← loop
```

The CPU simulator model (`facebook-opt-125m`, starts in seconds) is unaffected —
only workloads whose model takes >5 min to reach Ready loop.

## Root cause

On kueue-operator **1.4.x**, `buildWaitForPodsReady`
([pkg/configmap/configmap.go](https://github.com/openshift/kueue-operator/blob/d3857a018c88c3eb1a103475aa1759a4c6197b33/pkg/configmap/configmap.go#L142))
hardcodes `WaitForPodsReady{Timeout: 5 * time.Minute, BlockAdmission: false}`
whenever the Kueue CR sets `config.gangScheduling.policy: ByWorkload` — with
**no CR knob to change the timeout**. vLLM needs >5 min to pull + load a 27B
model, so Kueue marks the admitted Workload `Evicted` (PodsReadyTimeout) before
the pod is ever healthy; KServe deletes the pod, the Workload is requeued and
re-admitted, and the cycle repeats indefinitely. Direct proof on the cluster:

```yaml
# oc get cm kueue-manager-config -n openshift-kueue-operator -o jsonpath='{.data.controller_manager_config\.yaml}'
waitForPodsReady:
  blockAdmission: false
  timeout: 5m0s
```

Note the CRD shape that fooled us at first: the CRD text "policy is a required
field" applies **within** `gangScheduling` — `gangScheduling` itself is
optional ("If gangScheduling is not specified, the operator will decide the
default. This default could change over time."). So removing the whole section
is CRD-legal, and on v1.4.2 the operator default is `None` →
`buildWaitForPodsReady` returns `nil` → no `waitForPodsReady` at all.
`preemption`, `integrations` and `workloadManagement` are mapped independently
and survive the removal.

## Detection

```bash
oc get cm kueue-manager-config -n openshift-kueue-operator \
  -o jsonpath='{.data.controller_manager_config\.yaml}' | grep -A2 waitForPodsReady
# non-empty  = the PodsReady eviction behavior is armed
# timeout: 5m0s = the 1.4.x hardcoded trap (evicts anything >5m-to-Ready)

oc get workloads -n llm -o jsonpath='{range .items[*]}{.metadata.name}: {.status.conditions[?(@.type=="PodsReady")].reason}{"\n"}{end}'
# PodsReady=False reason=WaitForStart persisting near the 5m mark + Killing events = the loop
```

## Workaround (this repo, A14)

Delete the entire `gangScheduling` block from
`components/instances/kueue-instance/kueue.yaml` (commit `ee8870b`, 2026-09-22).
Verified same day on rhai-tmm: ArgoCD synced → `kueue-manager-config`
regenerated **without** `waitForPodsReady` → kueue-controller-manager rolled →
the new qwen pod survived past its 5m boundary, reached 2/2 with 0 restarts,
and the LLMInferenceService went Ready. (One final kill occurred exactly at the
controller-rollout boundary — the old leader's last 5m eviction during leader
election; after that, no kills.)

## Remove when

kueue-operator ≥ 2ec61a1 (1.5.x) lands in the channel, then restore gang
scheduling **explicitly** — `byWorkload.timeoutSeconds: 3600` (the intended
fix; 3600s covers a cold 30 GB modelcar pull + weight load) or `policy: None`.
**Do NOT rely on an absent section**: post-2ec61a1 the operator default for
absent `gangScheduling` becomes `ByWorkloadDefaults` (a 30-min eviction
timeout), so "absent = None" silently changes meaning on upgrade. The A14
Detection command settles it on the cluster, not on release notes.

## Steps to reproduce

1. Kueue CR with `config.gangScheduling.policy: ByWorkload` on kueue-operator
   ≤ 1.4.2.
2. Deploy an LLMInferenceService whose model needs >5 min to become Ready
   (GPU modelcar pull + weight load; here qwen3-6-27b-fp8, 30.9 GB).
3. Watch `oc get pods -n llm -w`: pod killed ~4m37s after start
   (`Killing: Stopping container main`), recreated, Startup probe still
   failing — repeating indefinitely. LLMInferenceService never Ready.
4. Confirm the mechanism: `kueue-manager-config` shows
   `waitForPodsReady: {timeout: 5m0s}`; remove `gangScheduling`, wait for the
   controller rollout, and the next pod survives.

## Filing draft

No upstream filing needed — the fix is merged and tracked (OCPSTRAT-3301 /
Kueue 1.5). Optional follow-up: comment on
[OCPKUEUE-862](https://redhat.atlassian.net/browse/OCPKUEUE-862) /
[OCPSTRAT-3594](https://redhat.atlassian.net/browse/OCPSTRAT-3594) adding
real-world evidence for the 1.5/1.6 timeline — *"LLMInferenceService
(qwen3-6-27b-fp8, 30.9 GB modelcar) on kueue-operator 1.4.2 +
`gangScheduling.policy: ByWorkload` is evicted every ~5m in an infinite loop
(pod deleted ~4m37s after start, LLMInferenceService never Ready); the
hardcoded 5m `waitForPodsReady` timeout cannot be configured from the CR.
Disabling gang scheduling entirely was the only workaround until 1.5."*
