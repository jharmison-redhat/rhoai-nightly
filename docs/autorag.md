# AutoML & AutoRAG (Tech Preview)

AutoML and AutoRAG are RHOAI 3.5 **Technology Preview** features:

- **AutoML** — automated model selection for tabular data: upload a CSV, it trains and
  evaluates multiple models, ranks them on a leaderboard, and produces notebooks plus a
  registry entry you can deploy. [Docs](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/working_with_automl)
- **AutoRAG** — automated RAG optimization: point it at documents + test data, it tests
  chunking/embedding/retrieval/generation combinations and ranks RAG patterns on a
  leaderboard. [Docs](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.5/html/working_with_autorag)

They are **opt-in** (`make autorag`), **orthogonal** to MaaS / observability / Eval Hub,
and ship as their own `instance-autorag` ArgoCD Application. Tech Preview = no SLA —
bugs are expected; file what you find in `docs/issues/`.

## Prerequisites

- RHOAI 3.5+ installed and `Ready` (see [Install with make](install-make.md)).
- **Dashboard feature flags** — `automl: true` and `autorag: true` in
  `components/instances/rhoai-instance/base/odh-dashboard-config.yaml`; they ship enabled
  with the `instance-rhoai` Application. Verify:
  ```bash
  oc get odhdashboardconfig odh-dashboard-config -n redhat-ods-applications \
    -o jsonpath='{.spec.dashboardConfig.automl} {.spec.dashboardConfig.autorag}'
  ```
- **A pipeline server with the managed pipelines** — the DSPA deployed by `make autorag`
  sets `spec.apiServer.managedPipelines: {}` (the "Enable AutoML and AutoRAG pipelines"
  checkbox). AutoML/AutoRAG pages light up per-project: they appear for projects that
  have such a pipeline server. Reuse this component's pattern to add one elsewhere.
- **A remote vector DB for AutoRAG** — Tech Preview supports **Milvus and pgvector
  (PostgreSQL) only**, no inline vector databases. This component deploys pgvector.
- **A default StorageClass** for the pgvector PVC (see [Eval Hub prerequisites](evalhub.md)).

## What gets deployed

All manifests live in `components/instances/autorag/` (one `autorag-tenant` namespace).

| Component | Description |
|-----------|-------------|
| `autorag-tenant` namespace | Dashboard-visible project (test tenant) |
| `DataSciencePipelinesApplication/dspa` | Pipelines backend with the managed AutoML/AutoRAG pipelines — brings its own MinIO (external route) + MariaDB, and reports `ManagedPipelineValid` once the pipeline definitions are uploaded |
| `Deployment/pgvector` + PVC + Service | pgvector PostgreSQL (`pgvector/pgvector:pg16`) for the AutoRAG vector store; `CREATE EXTENSION vector` via an init ConfigMap |
| `autorag-pg-creds` secret | Generated password (**not in git**) — created by `make autorag` |

The pgvector Deployment mirrors the MaaS PostgreSQL pattern
(`components/instances/maas-instance/chart/`): Recreate strategy, PVC-backed data dir,
probes, 512Mi/1Gi. The image differs because the pgvector extension isn't in the RHEL9
postgres image.

## Install

```bash
make autorag            # secret + instance-autorag ArgoCD Application (auto-syncs)
make autorag-uninstall  # deletes the Application; the resources-finalizer
                        # cascade-prunes DSPA, pgvector, and autorag-tenant
```

`make autorag` waits for `ManagedPipelineValid=True` (the AutoML/AutoRAG pipeline
definitions are compiled and uploaded by a DSPA init container) and prints the
pgvector connection details.

## Using it

1. Log into the RHOAI console, open the **autorag-tenant** project — the **AutoML** and
   **AutoRAG** nav items appear when the project has a pipeline server.
2. **AutoML**: upload a CSV (≤32 MiB from the dashboard; ≤100 MB from S3) to the MinIO
   route and create an optimization run. Binary/multiclass classification, regression,
   and time series are supported; no custom hyperparameter tuning in Tech Preview.
3. **AutoRAG**: create a pgvector **Data connection** in the project
   (`pgvector.autorag-tenant.svc:5432`, user/db from the `autorag-pg-creds` secret),
   upload documents + test data to MinIO, and create a run. Limits: ≤3 foundation models
   + 2 embedding models per run; CPU-only mode works with lightweight models.
4. Tutorials: [red-hat-data-services/red-hat-ai-examples](https://github.com/red-hat-data-services/red-hat-ai-examples)
   (`examples/automl/`, `examples/autorag/`).

## Verification

```bash
oc get application.argoproj.io/instance-autorag -n openshift-gitops
oc get dspa dspa -n autorag-tenant -o jsonpath='{.status.conditions[?(@.type=="ManagedPipelineValid")].status}'
oc get pods -n autorag-tenant
oc exec -n autorag-tenant deployment/pgvector -- psql -U autorag -d autorag -c '\dx'
```

## Known issues

- [RHOAIENG-64768](https://redhat.atlassian.net/browse/RHOAIENG-64768) — pipeline
  definitions shipped a hardcoded `odh-autorag-rhel9@sha256:...` missing from
  `registry.redhat.io`, so every AutoML/AutoRAG run failed with ImagePullBackOff.
  **Fixed upstream 2026-07-01**; a fresh DSPA uploads the fixed definitions at startup.
  If an older DSPA persists broken definitions, delete and let it recreate.
- `ManagedPipelineValid=False` despite working pipelines — the DSPO reports the
  condition False with "Managed pipelines not configured or no explicit pipeline
  list" for the documented `{}` form, fails permanently on an empty image with an
  explicit list, and cannot read the image it deploys (in-process fetch without
  registry credentials). The pipelines themselves are staged, loadable, and
  register in the DSP API with `managed=true` tags — only the condition is wrong
  (verified 2026-09-21: the dashboard AutoML/AutoRAG Tech Preview pages render
  and detect the DSPA regardless).
  See [docs/issues/dspo-managedpipelines-validation.md](issues/dspo-managedpipelines-validation.md)
  (NOT FILED — ready-to-file draft). Related:
  [RHOAIENG-93742](https://redhat.atlassian.net/browse/RHOAIENG-93742) (default-on
  for GA in 3.6),
  [RHOAIENG-94320](https://redhat.atlassian.net/browse/RHOAIENG-94320)
  (`{}` upgrade opt-in semantics).
