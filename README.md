# hello-world on Kubernetes — DevSecOps technical assessment

A static nginx "hello world", built into an image by a pipeline, deployed to a
Kubernetes cluster, scanned on a schedule,
and reachable only after authenticating.

The application is one HTML file.

---

## Status: built vs. designed

| Outcome (brief §2)                          | Status                       | Where                                                                              |
| ------------------------------------------- | ---------------------------- | ---------------------------------------------------------------------------------- |
| Local cluster, reproducible from the repo   | **Built**                    | [`cluster/`](cluster/), [`Makefile`](Makefile)                                     |
| Ingress controller, pinned                  | **Built**                    | [`cluster/ingress-nginx-values.yaml`](cluster/ingress-nginx-values.yaml)           |
| Page served from an image built             | **Built**                    | [`app/Dockerfile`](app/Dockerfile), [`k8s/`](k8s/)                                 |
| Workload hardening (non-root, read-only FS) | **Built**                    | [`k8s/deployment.yaml`](k8s/deployment.yaml)                                       |
| Pod Security Admission (`restricted`)       | **Built**                    | [`k8s/namespace.yaml`](k8s/namespace.yaml)                                         |
| NetworkPolicy                               | **Written, inert on kind**   | [`k8s/networkpolicy.yaml`](k8s/networkpolicy.yaml)                                 |
| Reaches the cluster through automation      | _Designed, not built_        | [Deployment model](#deployment-model-the-pipeline-never-holds-cluster-credentials) |
| Scheduled vulnerability scanning in-cluster | _Designed, not built_        | [Acting on scan results](#acting-on-scan-results)                                  |
| Authentication in front of the page         | _Designed, not built_        | [Authentication](#authentication)                                                  |
| AKS provisioning                            | _Discussion only, by design_ | brief §4                                                                           |

---

## How to run what exists today

Prerequisites: Docker Desktop, `kind`, `kubectl`, `helm`.

```bash
make cluster-up     # kind cluster, pinned node image, ingress host ports mapped
make ingress        # ingress-nginx via Helm, pinned chart version
```

The cluster writes to its own kubeconfig at `~/.kube/assessment.yaml`:

```bash
export KUBECONFIG=~/.kube/assessment.yaml
kubectl get pods -A
```

Verify the ingress path is live end to end:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/   # 404 = controller up, no Ingress yet
```

Tear down with `make cluster-down`.

### Deploying the application

While iterating, the image is built locally and side-loaded into kind:

```bash
docker build -t ghcr.io/yehtet95/hello-world-devsecops:dev app/
kind load docker-image ghcr.io/yehtet95/hello-world-devsecops:dev --name hello-world
kubectl apply -k k8s/
```

Then: <https://hello.127.0.0.1.nip.io:8443/> (self-signed certificate, so
expect a browser warning).

### Verified working

Each of these was checked against the running cluster, not assumed:

| Check                                       | Result                                                          |
| ------------------------------------------- | --------------------------------------------------------------- |
| Page served over HTTPS through the ingress  | `HTTP 200`                                                      |
| Plain HTTP                                  | `HTTP 308` redirect to HTTPS                                    |
| Container user                              | `uid=101(nginx)` — not root                                     |
| Write to web root (`/usr/share/nginx/html`) | `Read-only file system`                                         |
| Write to `/tmp`                             | permitted — the one writable path, an `emptyDir` capped at 16Mi |
| ServiceAccount token inside the pod         | `No such file or directory` — not mounted                       |
| Pod Security Admission                      | a non-compliant test pod was **rejected by the API server**     |
| nginx version disclosure                    | no `Server` version header in responses                         |

The Pod Security Admission check:

```console
$ kubectl -n hello-world run psa-test --image=curlimages/curl:8.11.1 --command -- sleep 30
Error from server (Forbidden): pods "psa-test" is forbidden:
violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false,
unrestricted capabilities, runAsNonRoot != true, seccompProfile
```

**What is not verified: the NetworkPolicies.** kind's default CNI (kindnet)
does not implement NetworkPolicy, so the objects in
[`k8s/networkpolicy.yaml`](k8s/networkpolicy.yaml) are accepted by the API
server and enforce nothing locally.
Enforcing them locally would mean recreating the cluster with
`disableDefaultCNI: true` and installing Calico.

Screenshots in [`docs/evidence/`](docs/evidence/).

---

## Shape of the deployment

```
  developer ──push──▶ GitHub ──▶ Actions (hosted runner)
                                   │  build image (multi-arch)
                                   │  scan image  ─┐ fails build over threshold
                                   │  generate SBOM │
                                   ▼                │
                                 GHCR  ◀────────────┘
                                   ▲
                                   │ pull (cluster reaches outward)
                    ┌──────────────┴───────────────────────────┐
                    │  kind cluster (stand-in for AKS)         │
                    │                                          │
                    │  Argo CD ──reconciles──▶ hello-world      │
                    │                            ▲             │
                    │  Trivy Operator ─scans─────┘             │
                    │                                          │
                    │  ingress-nginx ──▶ oauth2-proxy ──▶ app   │
                    └──────────────────────────────────────────┘
                                   ▲
                              :8443 (host)
```

---

## Decisions, and what they were weighed against

### Kubernetes version: pinned, and chosen to match AKS

```yaml
image: kindest/node:v1.36.1@sha256:3489c7674813ba5d8b1a9977baea8a6e553784dab7b84759d1014dbd78f7ebd5
```

Tags are mutable. `kindest/node:v1.36.1` can be repushed with different
contents; the digest cannot.

### Deployment model: the pipeline never holds cluster credentials

**split responsibility**:
GitHub Actions builds, scans, signs and pushes to GHCR, and **Argo CD inside
the cluster pulls and reconciles**.

| Option                                      | Why not                                                                                                                                            |
| ------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| Self-hosted runner with cluster access      | Solves the routing, but hands CI a kubeconfig. A long-lived, highly-privileged credential sitting in a runner is exactly the thing worth avoiding. |
| Real AKS cluster, pipeline deploys directly | Same credential problem, plus cost                                                                                                                 |
| **Pull-based (chosen)**                     | The cluster reaches outward. Nothing needs inbound access to it, and the pipeline holds no cluster credential to leak, rotate, or scope.           |

---

## Security expectations

### Pipeline credentials

**To the registry.** GitHub Actions authenticates to GHCR with the
workflow-scoped `GITHUB_TOKEN`, using `permissions: packages: write` and
nothing else. It is minted per job, expires when the job ends, and is scoped to
this repository. There is no PAT in a CI variable, because a PAT is a
long-lived bearer credential that typically carries far more scope than one
repo's packages and is rotated only when somebody remembers.

**To the cluster: nothing.** The pipeline has no cluster credential at all,
because it never talks to the cluster.

### Acting on scan results

**Designed, not built:**

1. **In the pipeline (blocking).** Trivy runs against the built image before
   push and **fails the build** on HIGH/CRITICAL with a fix available. This is
   the only place a block is cheap
2. **In the cluster (detecting).** **Trivy Operator** scans running workloads
   continuously and writes `VulnerabilityReport` CRDs. This catches what the
   pipeline cannot: a CVE disclosed _after_ the image shipped.
3. **Getting it to a human.** The reports are CRDs, so they are queryable — but
   nobody runs `kubectl get vulnerabilityreports` unprompted. Route them
   outward: metrics scraped to an alert on "critical count > 0 in a running
   workload", or a scheduled job that opens/updates a ticket per finding.
4. **Blocking deployment of what is already known-bad.** A Kyverno policy
   refusing images without a passing scan, or unsigned images, closes the gap
   where something reaches the cluster without passing through CI.

**What does not roll back automatically, and why.** Automatic rollback on a new
CVE is a bad default: the CVE is usually in a base-image layer, so the previous
image is affected too. Rolling back trades a known vulnerability for an older
known vulnerability while looking like remediation. The action that helps is
rebuild-and-redeploy on a patched base, which is forward, not backward.

### Scan coverage: what each layer catches that the others miss

| Layer                                               | Catches                                                                                                                                   | Misses                                                                      |
| --------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| **Build-time image scan** (planned, blocking)       | Vulnerable packages in the image, before it ships. Cheapest place to fix.                                                                 | Anything disclosed after the build. Misconfiguration in how it is deployed. |
| **Runtime workload scan** (planned, Trivy Operator) | Newly-disclosed CVEs in already-running images; drift between what CI approved and what is actually running.                              | Nothing, until it is already running.                                       |
| **IaC / manifest scan** (not built — see below)     | `privileged: true`, missing `runAsNonRoot`, no resource limits, a public AKS API server, an unrestricted NSG. Misconfiguration, not CVEs. | Vulnerable packages. Different failure class entirely.                      |
| **Dependency / SBOM scan** (SBOM planned)           | What is actually in the image, so that when a CVE lands you can answer "are we affected?" in minutes rather than days.                    | Nothing by itself — it is the inventory the other layers query.             |

**Skipped deliberately:** infrastructure-code scanning, because there is no
Terraform in this repo. On a
real repo this is `checkov`/`tfsec`/`trivy config` in CI against the Terraform,
failing on a public API server, unencrypted state, or over-broad role
assignment. It is the layer that catches an entire class the image scanners are
blind to, and it is the one most often missing.

### Image hygiene

**Planned:** `nginxinc/nginx-unprivileged:<version>@sha256:...` on Alpine.

- **Pinned by digest**, for the same reason the kind node image is: a tag is a
  mutable pointer, and "we deployed `1.29-alpine`" does not identify what ran.
- **Non-root.** Stock `nginx` starts as root to bind port 80 and then drops
  privileges for workers — the master process stays root. The unprivileged
  variant listens on 8080 as a non-root user throughout, so the container needs
  no `NET_BIND_SERVICE` and the pod can run under `runAsNonRoot: true` with a
  `readOnlyRootFilesystem` and all capabilities dropped. The ingress terminates
  on 443 regardless, so binding a low port inside the container buys nothing.
- **Alpine over Debian** for a smaller package surface — fewer packages is
  fewer CVEs to triage, and for serving one static file nothing in the larger
  base is needed.

### Least privilege

**In the cluster.** The workload serves a static file. It needs no Kubernetes
API access at all: `automountServiceAccountToken: false`, its own
ServiceAccount with no RoleBindings, no Secrets mounted, and a NetworkPolicy
allowing ingress only from the ingress-nginx namespace and denying egress.

Argo CD holds cluster-write by design. It
should be scoped per-namespace rather than cluster-admin, which is the default.

**In Azure.** The cluster's kubelet identity needs `AcrPull` on the registry
and nothing else — not `Contributor` on the resource group, which is the
common shortcut. Human access to the cluster goes through Entra ID groups with
Kubernetes RBAC bound to them, not shared admin kubeconfigs, so access is
revoked by removing someone from a group rather than by rotating a credential
everybody has a copy of. Local accounts on the AKS cluster disabled.

### The finding you can't fix

A critical CVE in the nginx base image with no patch available is the normal
case, not the exception, and the first move is not technical: establish whether
it is reachable. A critical in a library that ships in the image but is never
loaded by a process serving static files is a different problem from one in the
request path.

The process I would run:

1. **Triage for reachability and exposure.** Is the affected component actually
   invoked? Is the workload reachable by an attacker who could trigger it —
   here, behind authentication and an ingress, which narrows it considerably?
2. **Compensate.** If it is reachable and unpatched: restrict the path at the
   ingress, tighten NetworkPolicy, or drop the capability the exploit needs.
   The vulnerability stays; the route to it closes.
3. **Accept explicitly, with an owner and an expiry.** A documented exception
   naming who accepted it, on what evidence, and when it is revisited — not a
   suppression file that silently grows. The scanner keeps reporting it; the
   exception keeps it from blocking unrelated work.
4. **Watch for the fix.** The exception expiry forces the re-check. When the
   upstream patch lands, the rebuild is routine because the base image is
   pinned and bumping it is a one-line PR that re-runs every scan layer.

### Authentication

**Designed, not built:** oauth2-proxy in front of nginx, against a GitHub OAuth
app, enforced at the ingress so an anonymous request never reaches the pod.

**What the demo would not protect against, and production would.** A demo
oauth2-proxy with a GitHub OAuth app proves the request path is gated; it does
not give real identity governance. In production this is Entra ID, so access is
granted by group membership, revoked centrally on offboarding, subject to
conditional access and MFA, and audited. The demo also relies on a self-signed
certificate and `nip.io`; production terminates TLS on a real certificate.

Authentication at the ingress is also not a substitute for NetworkPolicy —
anything already inside the cluster bypasses the ingress entirely, which is why
the workload restriction above matters independently.

---

## What I'd do differently for production

- **Terraform for the AKS cluster**, with the security-relevant decisions in
  review: private API server, Entra-integrated RBAC with local accounts
  disabled, `AcrPull` via kubelet identity, Workload Identity for pods, and
  network exposure through a single ingress. Provisioning is a showcase
  conversation per brief §4.
- **Admission policy (Kyverno)** enforcing signed images, non-root, no
  `:latest`, resource limits — so the controls are not merely conventions the
  next person can skip.
- **Image signing (cosign) with verification at admission**, closing the gap
  where a correctly-named image that CI never built gets deployed.
- **Alerting on scan results** wired to wherever the team actually looks, and
  an SLA per severity rather than a dashboard.
- **Argo CD scoped per-namespace**, not cluster-admin.

## Open items

- Pipeline (GitHub Actions), Argo CD, Trivy Operator and oauth2-proxy are not
  yet built.
