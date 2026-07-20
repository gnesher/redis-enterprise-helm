# Redis Radar Helm Chart

Redis Radar is a fleet management platform for Redis Enterprise, Redis Cloud,
and OSS Redis clusters. This chart installs the runtime on Kubernetes or
OpenShift.

The chart deploys:

- **API server** (`mcm-api`) — HTTP API + UI
- **Async worker** (`mcm-worker`) — background job runner (River queue)
- **Database migration job** (`mcm-migrate`) — runs once per install/upgrade
- **PostgreSQL** — required; optional bundled Bitnami subchart for non-production

---

## Table of contents

- [Prerequisites](#prerequisites)
- [Production install](#production-install)
  - [PostgreSQL](#postgresql)
  - [Credential KEK (required)](#credential-kek-required)
  - [Legacy credential encryption key (optional)](#legacy-credential-encryption-key-optional)
  - [Image registry and pull secrets](#image-registry-and-pull-secrets)
  - [Service accounts and Workload Identity](#service-accounts-and-workload-identity)
  - [Exposing the API: Ingress, Route, LoadBalancer](#exposing-the-api)
  - [TLS](#tls)
  - [Resources and sizing](#resources-and-sizing)
- [OpenShift](#openshift)
- [Verifying the install](#verifying-the-install)
- [Observability](#observability)
- [Tracing (OpenTelemetry)](#tracing-opentelemetry)
- [Upgrade and uninstall](#upgrade-and-uninstall)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

- Kubernetes **1.23+** (chart uses `autoscaling/v2` and `batch/v1` Job TTL)
- Helm **3.x**
- Validated on OpenShift 4.x — see [`docs/OPENSHIFT_VALIDATION.md`](../../docs/OPENSHIFT_VALIDATION.md)
- An external PostgreSQL instance for production
  _(or use the bundled Bitnami Postgres subchart for non-production)_
- Outbound network access from the cluster to:
  - Your Redis Enterprise / Redis Cloud / OSS Redis clusters being managed
  - Your image registry
  - _(Optional)_ Your OpenTelemetry collector

---

## Production install

A production install has four moving parts you must supply:

1. **An external PostgreSQL connection** ([details](#postgresql))
2. **A credential KEK** — required; Radar will not safely persist credentials
   on Kubernetes without one ([details](#credential-kek-required))
3. **Image pull access** ([details](#image-registry-and-pull-secrets))
4. **External access path** (Ingress / Route / LoadBalancer — [details](#exposing-the-api))

Recommended minimal production install:

```bash
helm install radar ./helm/radar \
  --namespace radar \
  --create-namespace \
  --set database.existingSecret=radar-db \
  --set credentials.existingSecret=radar-credentials \
  --set ingress.enabled=true \
  --set ingress.className=nginx \
  --set ingress.hosts[0].host=radar.example.com \
  --set ingress.hosts[0].paths[0].path=/ \
  --set ingress.hosts[0].paths[0].pathType=Prefix
```

The two Secrets (`radar-db`, `radar-credentials`) are created out-of-band —
see the next sections.

### PostgreSQL

Radar uses PostgreSQL as its primary store. **Use an external managed
PostgreSQL in production.** The bundled Bitnami subchart (`postgresql.enabled:
true`) is fine for evaluation but is not hardened for production.

**Option A — connection string via Helm value (development):**

```bash
--set 'database.url=postgres://radar:secret@postgres.example.com:5432/radar?sslmode=require'
```

**Option B — connection string via existing Secret (recommended):**

Create the Secret yourself:

```bash
kubectl create secret generic radar-db \
  --namespace radar \
  --from-literal=DATABASE_URL='postgres://radar:secret@postgres.example.com:5432/radar?sslmode=require'
```

Reference it from values:

```yaml
database:
  host: postgres.example.com # used by TCP probe init container
  port: 5432
  existingSecret: radar-db
  urlSecretKey: DATABASE_URL # default
```

If you also want to split read/write traffic, add `RUNTIME_DATABASE_URL` to
the same Secret and set `database.runtimeUrlSecretKey: RUNTIME_DATABASE_URL`.

**TLS to managed Postgres:** include `sslmode=require` (or stricter) in the
URL. Radar passes the connection string through unmodified.

### Credential KEK (required)

Radar stores connector and auth credentials with envelope encryption: every
tenant gets a per-tenant data key (DEK), and all of those DEKs are wrapped by a
single **Key-Encryption-Key (KEK)** that you supply.

**The KEK is a file, not an env var.** It is **32 raw bytes** (a binary
AES-256 key — *not* base64, *not* hex). The only KEK-related environment
variable is `CREDENTIAL_KEK_PATH`, which just tells the process *where the file
is*; you never put the key bytes themselves in an env var. The chart wires this
up for you: it mounts the 32-byte key read-only at `credentials.kekPath`
(default `/var/lib/mcm/kek`, mode `0440`, read via the pod `fsGroup`) on **both**
the API and worker pods and sets `CREDENTIAL_KEK_PATH` to that path, so the two
share one key.

> 🔴 **You must provide a stable KEK for any real install.** If you don't, each
> pod generates its own ephemeral KEK — which fails immediately on the
> read-only root filesystem, and even if it didn't, the API and worker would
> generate *different* keys, so credentials sealed by one become
> **permanently undecryptable** by the other or after any restart. Treat the KEK
> like the database's other half: **back it up alongside the database** (each is
> useless without the other) and store that backup separately. Full backup,
> restore, and rotation procedures are in the
> [KEK lifecycle runbook](../../docs/kek-lifecycle-runbook.md).

**Production — provide the KEK via a Secret (recommended):**

Generate exactly 32 random bytes into a file and load it with `--from-file`
(this is the "where do I put the right KEK" answer — it goes into this Secret):

```bash
# Write exactly 32 raw bytes to a file, then load it with --from-file.
# Do NOT use --from-literal="$(head -c 32 /dev/urandom)": command substitution
# truncates at NUL bytes and won't be exactly 32 bytes.
head -c 32 /dev/urandom > kek.bin

kubectl create secret generic radar-credentials \
  --namespace radar \
  --from-file=CREDENTIAL_KEK=./kek.bin

shred -u kek.bin   # remove the raw key from disk
```

Point the chart at it:

```yaml
credentials:
  existingSecret: radar-credentials   # MUST contain the CREDENTIAL_KEK key
```

> When `existingSecret` is set, the enterprise chart mounts `CREDENTIAL_KEK`
> from it onto both pods. The Secret **must** include that key (32 bytes), or the
> pods stay in `ContainerCreating` referencing a missing key — an intentional
> loud failure that beats silent credential loss. **Upgrading an existing
> release:** add `CREDENTIAL_KEK` to the Secret *before* rolling out. If you also
> need the optional legacy encryption key (below), add both keys to this same
> Secret.

**Development only — inline:**

```yaml
credentials:
  kek: '32-byte-string-exactly-this-long'   # raw 32-byte string; dev only
```

> This exact sample is a documented placeholder: it is **rejected at startup**
> in cloud and packaged deployments (the service fails closed rather than seal
> data under a public, well-known key). Generate a real 32-byte key for anything
> other than a local dev throwaway.

> ⚠️ Inline keys are written into your values.yaml and into the Helm release
> Secret in cluster. Anyone with `helm get values --all` or
> `kubectl get secret` in the namespace can read them. Use `existingSecret`
> for anything production-bound.

### Legacy credential encryption key (optional)

The `CREDENTIAL_ENCRYPTION_KEY` is a separate, older AES-256-GCM key used only
by the pre-KEK LDAP/SAML credential path. It is **not** required for the KEK
envelope encryption above — only add it if your deployment still uses that
legacy path. When present, supply it as a **32-byte raw string** in the *same*
`radar-credentials` Secret as the KEK:

```bash
kubectl create secret generic radar-credentials \
  --namespace radar \
  --from-file=CREDENTIAL_KEK=./kek.bin \
  --from-literal=CREDENTIAL_ENCRYPTION_KEY="$(openssl rand -hex 16)" \
  --from-literal=CREDENTIAL_ENCRYPTION_KEY_VERSION=v1
```

```yaml
credentials:
  existingSecret: radar-credentials
```

Inline (development only) uses `credentials.encryptionKey` /
`credentials.encryptionKeyVersion`, with the same inline-secret caveat as the
KEK above.

### Feature flags (LaunchDarkly, optional)

The API evaluates feature flags via LaunchDarkly using a server-side SDK key
(`LAUNCHDARKLY_SDK_KEY`). It is entirely optional: when neither
`launchDarkly.sdkKey` nor `launchDarkly.existingSecret` is set, LaunchDarkly is
disabled and every flag falls back to its in-code default (a no-op provider), so
existing releases are unaffected. Use the SDK key for the LaunchDarkly
environment this deployment targets (e.g. the `test` environment key for
non-production).

Recommended (production) — supply the key via a pre-existing Secret:

```bash
kubectl create secret generic radar-launchdarkly \
  --namespace radar \
  --from-literal=LAUNCHDARKLY_SDK_KEY="sdk-xxxxxxxx"
```

```yaml
launchDarkly:
  existingSecret: radar-launchdarkly
```

Inline (development only) renders the key into the chart-managed
`radar-launchdarkly` Secret, with the same inline-secret caveat as the KEK
above:

```yaml
launchDarkly:
  sdkKey: sdk-xxxxxxxx
```

The key inside the Secret must be named `LAUNCHDARKLY_SDK_KEY`. The env entry is
injected with `optional: true`, so referencing an `existingSecret` that does not
yet carry the key never blocks the API from starting.

### Image registry and pull secrets

By default the chart pulls images from the public Redis registry. Override for
air-gapped or private registries:

```yaml
global:
  imageRegistry: registry.example.com/redislabs
  imagePullSecrets:
    - name: registry-creds

image:
  app:
    repository: radar-app # final URL: registry.example.com/redislabs/radar-app
    tag: '' # empty → uses .Chart.AppVersion
  worker:
    repository: radar-worker
  migrate:
    repository: radar-migrate
```

Create the pull secret beforehand:

```bash
kubectl create secret docker-registry registry-creds \
  --namespace radar \
  --docker-server=registry.example.com \
  --docker-username='<user>' \
  --docker-password='<password>'
```

### Service accounts and Workload Identity

The chart renders two ServiceAccounts by default:

- `serviceAccount.name` for the API and worker runtime pods
- `serviceAccount.migrate.name` for the database migration Job

When `serviceAccount.create: false`, the chart does not render ServiceAccounts.
The API/worker and migration Job fall back to the namespace `default`
ServiceAccount unless `serviceAccount.name` or `serviceAccount.migrate.name` is
set to a pre-created account.

Cloud environments can bind each KSA to its own GCP IAM service account by
setting annotations in values:

```yaml
serviceAccount:
  name: radar
  annotations:
    iam.gke.io/gcp-service-account: radar-<env>@<project>.iam.gserviceaccount.com
  migrate:
    name: radar-flyway-migrator
    annotations:
      iam.gke.io/gcp-service-account: radar-<env>-mig@<project>.iam.gserviceaccount.com
```

The chart-created ServiceAccount resources keep ServiceAccount token automount
disabled by default. API/worker pods and the migration Job enable pod token
automount only when their corresponding values annotations include
`iam.gke.io/gcp-service-account`, which is required for GKE Workload Identity.
For pre-created ServiceAccounts, keep the annotation in values too so the chart
can render the pod token automount correctly.

The migrate ServiceAccount is rendered as a Helm hook resource so external-DB
pre-install migrations can run under `radar-flyway-migrator` instead of the
namespace `default` ServiceAccount.

### Exposing the API

The API/UI is served on port 80 (`service.port`) of an in-cluster Service. To
expose it externally, pick one of:

**Ingress (plain Kubernetes — most common):**

```yaml
ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod # if using cert-manager
  hosts:
    - host: radar.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: radar-tls
      hosts:
        - radar.example.com
```

**Route (OpenShift only):**

```yaml
route:
  enabled: true
  host: radar.apps.example.com
  tls:
    termination: edge
```

**Service of type LoadBalancer (cloud K8s, no Ingress controller):**

```yaml
service:
  type: LoadBalancer
  port: 80
  annotations:
    # cloud-specific annotations for NLB/ALB go here
```

### TLS

- **At the edge (Ingress / Route):** terminate TLS at the Ingress controller
  or Route using `tls.secretName` (Ingress) / `route.tls.termination` (Route).
  Combine with cert-manager for automatic certs.
- **Between API and Postgres:** include `sslmode=require` (or stricter) in
  `DATABASE_URL`.
- **Browser session cookie:** `app.sessionCookieSecure: true` by default —
  only flip to `false` if you intentionally serve over plain HTTP.

### Resources and sizing

The chart leaves `resources: {}` empty by default so you set explicit floors
for your environment. The cloud overlay (`values-cloud.yaml`) uses these
production-oriented starting points:

| Component           | CPU request | CPU limit | Memory request | Memory limit |
| ------------------- | ----------- | --------- | -------------- | ------------ |
| `mcm-api`           | 1           | 1         | 1Gi            | 1Gi          |
| `mcm-worker`        | 1           | 1         | 1Gi            | 1Gi          |
| `mcm-migrate` (job) | 500m        | 500m      | 256Mi          | 256Mi        |

Bump the worker concurrency (`worker.riverMaxWorkers`, default `10`) and add
replicas if you manage a large fleet — the worker is the typical scaling
bottleneck.

The cloud overlay also enables HPA with two minimum replicas for the API and
worker, plus PodDisruptionBudgets. Keep the base values small for evaluation or
QA namespaces; use the cloud overlay or equivalent environment values for
SLO-bearing environments.

The cloud overlay keeps CPU and memory requests equal to limits for cloud
workload pods and chart-owned helper pods.

### Availability and autoscaling

Radar exposes the availability knobs separately for the API and worker:

- `app.autoscaling.*` renders the API `HorizontalPodAutoscaler`
- `worker.autoscaling.*` renders the worker `HorizontalPodAutoscaler`
- `podDisruptionBudget.enabled` renders separate API and worker
  `PodDisruptionBudget` resources
- `app.replicaCount` and `worker.replicaCount` are used only when the matching
  HPA is disabled

For staging/prod, run at least two effective replicas for both API and worker
and set CPU requests before enabling CPU-based HPA. Kubernetes computes CPU
utilization from requests; an HPA without requests cannot make useful scaling
decisions.

The worker is safe to scale horizontally under the existing durable queue model:
all worker pods share the same River queue in PostgreSQL, each pod processes up
to `worker.riverMaxWorkers` jobs concurrently, and River claims jobs durably so
replicas are competing consumers rather than independent schedulers. The worker
job contracts are tenant-scoped/versioned (`specs/032-tenant-aware-worker-jobs`)
and priority scheduling keeps interactive collection ahead of bulk action work
(`specs/023-protect-collection-jobs`). Long-running scale validation lives in
`api/internal/worker/scale_stress_integration_test.go`.

---

## OpenShift

Use `values-openshift.yaml` for OpenShift `restricted-v2` clusters. It enables
`openshift.enabled` (drops `runAsUser`/`fsGroup` from pod specs so OpenShift
assigns namespace-scoped IDs) and switches the default external-access path
from Ingress to Route. It also sets resource requests and memory limits for the
main chart workloads.

```bash
helm install radar ./helm/radar \
  --namespace radar \
  --create-namespace \
  -f ./helm/radar/values-openshift.yaml \
  --set database.existingSecret=radar-db \
  --set credentials.existingSecret=radar-credentials \
  --set route.host=radar.apps.example.com
```

Notes:

- The chart does **not** require `anyuid`, privileged SCCs, host paths, or
  cluster-admin permissions for the Radar workloads.
- For production OpenShift, use a managed or operator-provisioned PostgreSQL
  (not the in-tree `deploy/e2e-k8s/postgres.yaml`, which is for kind/plain
  Kubernetes e2e only).
- For local OpenShift validation only, apply
  `deploy/e2e-k8s/postgres-openshift.yaml` before installing the chart.

See [`docs/OPENSHIFT_VALIDATION.md`](../../docs/OPENSHIFT_VALIDATION.md) for
the full validation runbook.

---

## Verifying the install

After `helm install`, walk through these checks:

**1. Pods are running:**

```bash
kubectl get pods -n radar
# Expect: radar-mcm-api-*, radar-mcm-worker-*, radar-mcm-migrate-* (Completed)
```

**2. Migration job completed successfully:**

```bash
kubectl logs -n radar job/radar-mcm-migrate
# Should end with "migration complete" or similar
```

**3. Health endpoints respond:**

```bash
kubectl port-forward -n radar svc/radar 8080:80
curl http://localhost:8080/healthz/startup  # 200 OK
curl http://localhost:8080/healthz/ready    # 200 OK
curl http://localhost:8080/healthz/live     # 200 OK
```

The API deployment uses those dedicated Kubernetes health endpoints by default:

- startup probe: `/healthz/startup`
- liveness probe: `/healthz/live`
- readiness probe: `/healthz/ready`

The worker exposes its own internal health endpoints on `worker.httpPort`
(default `8081`) and the chart wires probes to them by default:

- startup probe: `/healthz/startup`
- liveness probe: `/healthz/live`
- readiness probe: `/healthz/ready`

Worker startup/readiness become healthy only after the River runtime starts.
Readiness becomes unhealthy again while the process is draining, which lets
rollouts and disruption handling wait for replacement capacity.

Set `worker.httpPort` to change the worker metrics/health listener port. Do
not override `WORKER_METRICS_ADDR` through `worker.extraEnv`; the chart renders
that environment variable from `worker.httpPort` and fails rendering if it is
redefined so the listener, container port, and probes cannot drift.

The worker `/healthz/*` probes require a worker image that serves those paths on
`WORKER_METRICS_ADDR`. Older worker images only served `/metrics`; if this chart
syncs ahead of the worker image in a pinned-image GitOps rollout,
`/healthz/startup` returns 404 and the worker will crash-loop until the image
tag catches up. Roll out the chart bump and worker image bump together.

**4. Chart-provided readiness test:**

```bash
helm test radar --namespace radar
```

**5. External access works** (only if you enabled Ingress/Route/LB):

```bash
curl https://radar.example.com/healthz/ready
```

---

## Observability

The API server exposes Prometheus metrics on `GET /metrics` over the existing
`http` Service port. No extra port, no extra Service. The endpoint is
unauthenticated by Prometheus convention; restrict access via
NetworkPolicy/ingress posture.

This chart does not render a `ServiceMonitor`. Point Prometheus at the
existing Service with a manual scrape config:

```yaml
scrape_configs:
  - job_name: mcm-api
    metrics_path: /metrics
    static_configs:
      - targets: ['<release-name>.<namespace>.svc:<service.port>']
```

The wire-level contract (metric names, label schema, cardinality bounds, and
backward-compatibility commitments) lives next to the feature spec in
[`specs/021-prometheus-http-metrics/contracts/metrics-endpoint.md`](../../specs/021-prometheus-http-metrics/contracts/metrics-endpoint.md).

### Exposed metrics

| Name                            | Type      | Labels                      | Notes                                                                                                                                        |
| ------------------------------- | --------- | --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `http_requests_total`           | counter   | `method`, `route`, `status` | Total HTTP requests. `route` is the Gin route template (e.g., `/api/v1/clusters/:uid`), never a raw path; `status` is the numeric HTTP code. |
| `http_request_duration_seconds` | histogram | `method`, `route`, `status` | End-to-end handler latency. Buckets: Prometheus defaults (5 ms … 10 s).                                                                      |
| `http_requests_in_flight`       | gauge     | `method`, `route`           | Currently-executing requests. No `status` label.                                                                                             |

Cardinality is bounded by the registered route table (~30 routes today) times
HTTP methods times bounded statuses — adding clusters, tenants, or users does
not grow the series count. Scraping `/metrics` does not instrument itself, and
`/metrics`/`/healthz/*` do not appear in request logs.

### Starter alerts

Drop these into your Prometheus rule files. Thresholds are starting points —
tune to your fleet.

```yaml
groups:
  - name: mcm-api
    rules:
      - alert: MCMAPIHighErrorRate
        expr: |
          sum by (route) (rate(http_requests_total{status=~"5.."}[5m]))
          /
          sum by (route) (rate(http_requests_total[5m]))
          > 0.05
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: '>5% of {{ $labels.route }} requests are returning 5xx (last 5m)'

      - alert: MCMAPILatencyP95High
        expr: |
          histogram_quantile(
            0.95,
            sum by (le, route) (rate(http_request_duration_seconds_bucket[5m]))
          ) > 1.0
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: 'p95 latency of {{ $labels.route }} > 1s (last 5m)'
```

---

## Tracing (OpenTelemetry)

The `mcm-api` and `mcm-worker` processes ship with an OpenTelemetry
tracer-provider bootstrap. **It is off by default** — without
`OTEL_EXPORTER_OTLP_ENDPOINT`, both processes behave exactly as before: no
exporter, no outbound telemetry, no collector required.

Enable tracing through the chart's first-class `opentelemetry:` block. The
chart renders the standard `OTEL_*` environment variables on both the
`mcm-api` and `mcm-worker` deployments.

```yaml
opentelemetry:
  enabled: true
  endpoint: https://otel-collector.observability.svc.cluster.local:4317
  sampler:
    name: parentbased_traceidratio
    arg: '0.05'
  resourceAttributes: deployment.environment=prod
```

For vendor backends that need authentication, supply the headers via a Secret —
MCM never logs `OTEL_EXPORTER_OTLP_HEADERS`:

```yaml
opentelemetry:
  enabled: true
  endpoint: https://otlp.vendor.example:4317
  headersSecret:
    name: otel-vendor-creds
    key: headers # Secret value e.g. "Authorization=Bearer <token>"
```

**Endpoint rules** (rejected at startup with a clear error otherwise):

- Scheme MUST be `http` or `https` only.
- Userinfo (`user:pass@host`) is NOT permitted — use `OTEL_EXPORTER_OTLP_HEADERS` for auth.
- On startup the endpoint is logged as `scheme://host:port` only (path,
  query, fragment, userinfo stripped before logging).

**Default sampling** is conservative: `parentbased_traceidratio` with ratio
`0.1`. Override via `OTEL_TRACES_SAMPLER_ARG` — set to `1.0` for local
validation, lower for very high-traffic deployments.

---

## Upgrade and uninstall

**Upgrade:**

```bash
helm upgrade radar ./helm/radar \
  --namespace radar \
  -f your-values.yaml
```

Every upgrade re-runs `mcm-migrate` as a fresh Job. Schema migrations are
applied forward-only — there is no automated rollback for DB changes.

**Chart/image skew warning:** the worker health probes in this chart call
`/healthz/startup`, `/healthz/live`, and `/healthz/ready` on the worker metrics
listener. Those endpoints are served by the worker binary in this release.
Do not sync this chart ahead of the matching worker image tag; older images
only serve `/metrics` on that listener, so the startup probe fails with 404 and
Kubernetes restarts the worker until the image is updated.

**Uninstall:**

```bash
helm uninstall radar --namespace radar
```

The chart does not provision PVCs itself, so uninstall is non-destructive for
external PostgreSQL data. If you installed with `postgresql.enabled: true`,
the bundled Postgres PVC is retained per Bitnami subchart defaults — delete
manually if you want a clean slate.

---

## Troubleshooting

**Migration job stuck in `Pending` or `Init:0/1`:**
Usually the `dbWaitInitContainer` can't reach `database.host:database.port`.
Confirm DNS resolves and a network policy isn't blocking egress to Postgres
from the namespace.

**API pod CrashLoopBackOff with `tracing endpoint rejected`:**
Your `opentelemetry.endpoint` includes userinfo, a non-http(s) scheme, or
is malformed. Strip credentials and put them in `opentelemetry.headersSecret`
instead.

**`helm test` pod returns non-200:**
The test pod calls `/healthz/ready` on the in-cluster Service. A non-200 means
the API is up but not ready — usually a DB connectivity issue. Check
`kubectl logs -n radar deploy/radar-mcm-api`.

**Inline `credentials.encryptionKey` validation error:**
The key must be exactly 32 bytes as a raw string. `openssl rand -hex 16`
gives you 32 hex characters = 32 bytes raw.

**API/worker pods stuck in `ContainerCreating` after setting
`credentials.existingSecret`:**
The chart mounts `CREDENTIAL_KEK` from that Secret, but the Secret is missing
that key. Add the 32-byte KEK to the Secret (`--from-file=CREDENTIAL_KEK=...`,
see [Credential KEK](#credential-kek-required)) and let the pods reschedule.

**API/worker `CrashLoopBackOff` with a KEK load/permission error, or
credentials that decrypted yesterday now fail:**
Almost always a KEK mismatch — the pod is reading a different KEK than the one
that sealed the data (a regenerated/ephemeral key, or a restored DB paired with
the wrong KEK backup). The file must be exactly 32 bytes and mode `0400`/`0440`.
See the [KEK lifecycle runbook](../../docs/kek-lifecycle-runbook.md) for the
fail-closed conditions and restore order.

**Pods can't pull images:**
Confirm `global.imagePullSecrets` (or `imagePullSecrets`) references a Secret
that exists in the install namespace, and the Secret has the right
credentials for `global.imageRegistry`.
