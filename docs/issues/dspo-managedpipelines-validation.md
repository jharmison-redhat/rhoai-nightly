# DSPO `ManagedPipelineValid` can never validate when managed pipelines are enabled — three defects in one path

**Jira: NOT FILED** — this file is the ready-to-file draft. Target: **RHOAIENG,
AI Pipelines component** (DSPO = `data-science-pipelines-operator`). Directly
related open items: [RHOAIENG-93742](https://redhat.atlassian.net/browse/RHOAIENG-93742)
(default-on for AutoML/AutoRAG GA in 3.6) and
[RHOAIENG-94320](https://redhat.atlassian.net/browse/RHOAIENG-94320)
(`managedPipelines: {}` upgrade opt-in semantics).

Found 2026-09-21 on **cluster.internal.rhai-tmm.dev** (RHOAI 3.5.1, nightly
`rhoai-3.5@sha256:53c03c57` built ~2026-09-20, DSPO
`odh-data-science-pipelines-operator-controller-rhel9@sha256:74daf312`).
The evalhub-tenant DSPA (field absent) and a fresh 3.5 DSPA confirm the
field-absent default is disabled, so **every user who enables managed
pipelines in 3.5 — which is required for AutoML/AutoRAG Tech Preview — hits
this chain.**

## Symptom chain

Enabling managed pipelines is a documented prerequisite for AutoML/AutoRAG
(3.5 docs, `working_with_automl`: "set `spec.apiServer.managedPipelines: {}`").
Three defects, each independently blocking the `ManagedPipelineValid`
condition:

### 1. The documented `{}` import works, but the condition reports "not configured"

With `spec.apiServer.managedPipelines: {}` the DSPO treats the field as
opt-in to **all** managed pipelines (matching
[RHOAIENG-94320](https://redhat.atlassian.net/browse/RHOAIENG-94320)'s
findings): the `init-managed-pipelines` container runs
(`ALL_PIPELINES=true`), compiles all four definitions
(`documents-indexing-pipeline`, `autogluon-tabular-training-pipeline`,
`autogluon-timeseries-training-pipeline`, `documents-rag-optimization-pipeline`)
and the DSP API server loads them ("Loaded 4 managed pipeline(s) from
/config/managed-pipelines/managed-pipelines.json"). **But**
`ManagedPipelineValid=False` with:

> Managed pipelines not configured or no explicit pipeline list

The validation path does not match the import path: the pipelines are
imported and loadable while the condition says they are not configured.

### 2. Explicit pipelines list without `image` → permanent "invalid image reference"

Following the condition's own message and listing the pipelines explicitly:

```yaml
apiServer:
  managedPipelines:
    pipelines:
      - name: documents-indexing-pipeline
      ...
```

the reconcile fails permanently:

> Managed pipeline configuration error (permanent) {"error": "invalid image
> reference \"\": could not parse reference:", "image": ""}

The CRD says `managedPipelines.image` is "Optional: when omitted, empty (""),
or whitespace-only, DSPO uses operator config Images.PipelinesComponents" —
and the operator config **has** it set
(`registry.redhat.io/rhoai/odh-pipelines-components-rhel9@sha256:509cc594...`
in `RELATED_IMAGE_ODH_PIPELINES_COMPONENTS_IMAGE` and the
`data-science-pipelines-operator-dspo-config` ConfigMap). The params step
does not apply that fallback for `ManagedPipelines.Image` the way it does
for the other image fields; the error is classified **permanent**, so the
reconcile never retries and the deployment is never updated.

### 3. With `image` pinned, the DSPO controller cannot read the image it just validated

Adding the image reference explicitly unblocks defect 2 and the init
container compiles and stages the pipelines successfully. But the DSPO
**controller itself** then does an in-process fetch of
`managed-pipelines.json` from the image to validate, and that fetch fails:

> Failed to fetch managed-pipelines.json from image (transient) {"error":
> "failed to pull image \"registry.redhat.io/rhoai/odh-pipelines-components-
> rhel9@sha256:509cc...\": ... UNAUTHORIZED: Please login to the Red Hat
> Registry ..."}

Root cause: the controller performs this pull in-process (not via CRI), so it
cannot use the node-level global pull secret the way every normal Deployment
pod does. Its ServiceAccount
(`data-science-pipelines-operator-controller-manager` in
`redhat-ods-applications`) carries only the internal-registry `dockercfg`
that OpenShift auto-creates per namespace — no `registry.redhat.io`
credentials. The error is classified **transient** and retried forever, so
`ManagedPipelineValid` stays False even though the init container staged all
four pipelines (Completed, exit 0) and the API server loaded them.

Note the asymmetry: the same image pulled fine from the *pod* side on the
node that already had it cached — the failure is specific to the
controller's in-process pull.

## Why this matters

- AutoML/AutoRAG are Tech Preview in 3.5 and require managed pipelines; the
  only documented enablement (`{}`) leaves the condition False (defect 1),
  and the condition's own suggested fix leads to defect 2, then defect 3.
- [RHOAIENG-93742](https://redhat.atlassian.net/browse/RHOAIENG-93742)
  plans default-on for 3.6 GA — defects 2 and 3 would make every DSPA with
  an explicit default fail validation unless the controller's credential
  path is fixed first.
- The pipelines themselves **do** work: the init stages them and the API
  server loads them. Verified 2026-09-21 via the DSP API with an admin
  bearer token — all four registered with tags `managed=true,
  rhoai-version=3.5.1`:

  ```
  documents-rag-optimization-pipeline
  autogluon-timeseries-training-pipeline
  autogluon-tabular-training-pipeline
  documents-indexing-pipeline
  ```

  Only the DSPO's own condition is wrong. Note the DSP API requires the
  caller to hold RBAC on `datasciencepipelinesapplications/api` in the
  project — the namespace's own `ds-pipeline-dspa` SA gets 403; use a
  dashboard-capable token.

- **The dashboard does NOT gate on the condition** (verified 2026-09-21 with
  a headed browser, logged in as admin): the **AutoML** and **AutoRAG** Tech
  Preview pages render in the RHOAI dashboard (`rh-ai.apps...` host, nav
  items `Develop & train → AutoML Tech Preview` at
  `/develop-train/automl/experiments/<project>` and `Gen AI studio → AutoRAG
  Tech Preview` at `/gen-ai-studio/autorag/experiments/<project>`)
  **despite** `ManagedPipelineValid=False`. For a project with the DSPA
  (`autorag-tenant`) the AutoRAG page shows the full interface ("Create an
  AutoRAG optimization run"); for a project without a DSPA (`ai-tenants`) it
  shows the "Configure a pipeline server" empty state. The UI keys on the
  project's DSPA and its pipelines, not on the condition — so defect 3's
  blast radius is limited to the misleading condition itself, not the user
  experience.

## Detection

```bash
# Condition stuck False while the init container succeeded
oc get dspa dspa -n autorag-tenant \
  -o jsonpath='{.status.conditions[?(@.type=="ManagedPipelineValid")].status}'
oc get pod -n autorag-tenant -l app=ds-pipeline-dspa \
  -o jsonpath='{range .items[*].status.initContainerStatuses[*]}{.name}{"="}{.state.terminated.exitCode}{"\n"}{end}'

# The controller's own failed fetch (transient, retried forever)
oc logs -n redhat-ods-applications \
  deployment/data-science-pipelines-operator-controller-manager \
  | grep "Failed to fetch managed-pipelines.json"

# Defect 1 vs 2: DSPO reconcile log
#   "Managed pipelines not configured or no explicit pipeline list"  ({})
#   "Managed pipeline configuration error (permanent)" + empty image (explicit list, no image)
```

## Filing draft (RHOAIENG / AI Pipelines)

**Title**: DSPO `ManagedPipelineValid` never validates when managed pipelines
are enabled: `{}` reports "not configured" despite importing all pipelines;
explicit list without image fails permanently on empty image; controller's
in-process image fetch has no registry credentials

**Description of problem**: The 3.5 AutoML/AutoRAG docs instruct setting
`spec.apiServer.managedPipelines: {}` to enable managed pipelines. On 3.5.1
the condition `ManagedPipelineValid` then reports "Managed pipelines not
configured or no explicit pipeline list" even though the init container
compiles all four managed pipelines and the DSP API server loads them.
Following the condition's message and listing the pipelines explicitly makes
the reconcile fail permanently with "Managed pipeline configuration error
(permanent) / invalid image reference \"\"" — the params step does not apply
the `Images.PipelinesComponents` operator-config fallback that the CRD
documents for an omitted `managedPipelines.image`. Pinning the image
explicitly unblocks the init, but the DSPO controller then performs an
in-process fetch of `managed-pipelines.json` from the image which fails with
UNAUTHORIZED: the controller performs this pull outside CRI, so it cannot use
the node-level global pull secret, and its ServiceAccount has only the
namespace's internal-registry `dockercfg`. The error is classified transient
and retried forever, leaving `ManagedPipelineValid=False` although the
pipelines are staged and loaded.

**Steps to reproduce**: On RHOAI 3.5.1, create a DSPA with
`spec.apiServer.managedPipelines: {}`; observe the condition False with
"not configured" while the init container compiles all pipelines. Then set
`managedPipelines.pipelines` explicitly; observe the permanent empty-image
error. Then pin `managedPipelines.image` to the pipelines-components image;
observe the controller's repeated "Failed to fetch managed-pipelines.json
from image (transient)" UNAUTHORIZED errors.

**Expected results**: `ManagedPipelineValid=True` when the managed pipelines
are staged and loadable, consistent between import and validation; the
documented `{}` form and the documented image fallback both work; the
controller can read the image it deploys.

**Workaround**: pin `managedPipelines.image` explicitly (defects 1 and 2
mitigated; defect 3 leaves the condition False but the pipelines remain
functional — the DSP API lists them and runs accept them).

**Component**: AI Pipelines (data-science-pipelines-operator). Related:
[RHOAIENG-93742](https://redhat.atlassian.net/browse/RHOAIENG-93742) (GA
default-on), [RHOAIENG-94320](https://redhat.atlassian.net/browse/RHOAIENG-94320)
(`{}` upgrade semantics), [RHOAIENG-64768](https://redhat.atlassian.net/browse/RHOAIENG-64768)
(prior hardcoded-SHA bug in the same upload path).
