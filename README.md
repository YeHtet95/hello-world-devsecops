# hello-world on Kubernetes — DevSecOps technical assessment

A static nginx "hello world", built into an image by a pipeline, deployed to a
Kubernetes cluster, scanned on a schedule,
and reachable only after authenticating.

The application is one HTML file.

---

## Status: built vs. designed

| Outcome                                     | Status                       | Where                                                                              |
| ------------------------------------------- | ---------------------------- | ---------------------------------------------------------------------------------- |
| Local cluster, reproducible from the repo   | **Built**                    | [`cluster/`](cluster/), [`Makefile`](Makefile)                                     |
| Ingress controller, pinned                  | **Built**                    | [`cluster/ingress-nginx-values.yaml`](cluster/ingress-nginx-values.yaml)           |
| Page served from an image built             | **Built**                    | [`app/Dockerfile`](app/Dockerfile), [`k8s/`](k8s/)                                 |
| Workload hardening (non-root, read-only FS) | **Built**                    | [`k8s/deployment.yaml`](k8s/deployment.yaml)                                       |
| Pod Security Admission (`restricted`)       | **Built**                    | [`k8s/namespace.yaml`](k8s/namespace.yaml)                                         |
| NetworkPolicy                               | **Written, inert on kind**   | [`k8s/networkpolicy.yaml`](k8s/networkpolicy.yaml)                                 |
| Pipeline: build, scan, publish to GHCR      | **Built**                    | [`.github/workflows/`](.github/workflows/build-scan-publish.yml)                   |
| Build-time scan with a blocking threshold   | **Built**                    | same — gates 1 and 3                                                               |
| Manifest misconfiguration scan (blocking)   | **Built**                    | same, plus [`.trivyignore.yaml`](.trivyignore.yaml)                                |
| SBOM + provenance attestations              | **Built**                    | same — `sbom: true`, `provenance: mode=max`                                        |
| Reaches the cluster through automation      | **Built**                    | [`gitops/`](gitops/), [`cluster/argocd-values.yaml`](cluster/argocd-values.yaml)   |
| Argo CD controller scoped off cluster-admin | **Built**                    | [`cluster/argocd-values.yaml`](cluster/argocd-values.yaml)                         |
| Scheduled vulnerability scanning in-cluster | **Built**                    | [`cluster/trivy-operator-values.yaml`](cluster/trivy-operator-values.yaml)         |
| Scan results reaching a human               | **Built**                    | [`k8s-security/vulnerability-digest.yaml`](k8s-security/vulnerability-digest.yaml) |
| Authentication in front of the page         | **Built**                    | [`k8s/oauth2-proxy.yaml`](k8s/oauth2-proxy.yaml)                                   |
| AKS provisioning                            | _Discussion only, by design_ |                                                                                    |

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

Pushing a change under `app/` triggers
[`build-scan-publish`](.github/workflows/build-scan-publish.yml), which
builds, scans, publishes to GHCR and commits the new digest to
[`k8s/kustomization.yaml`](k8s/kustomization.yaml):

```console
$ kubectl -n hello-world get pod -o jsonpath='{.items[0].status.containerStatuses[0].imageID}'
ghcr.io/yehtet95/hello-world-devsecops@sha256:32816991ff35…
```

Argo CD is installed by `make argocd && make gitops`. Its UI is at
<https://argocd.127.0.0.1.nip.io:8443/>; `make argocd-password` reads the
generated admin password out of the cluster.

Scheduled scanning is `make trivy-operator`. `make digest` runs the
vulnerability digest immediately instead of waiting for 08:00.

**Authentication needs a one-time setup**, because the OAuth credentials are
not in this repository. Create a GitHub OAuth app with callback URL
`https://hello.127.0.0.1.nip.io:8443/oauth2/callback`, then:

```bash
kubectl -n hello-world create secret generic oauth2-proxy \
  --from-literal=client-id='<client id>' \
  --from-literal=client-secret='<client secret>' \
  --from-literal=cookie-secret="$(openssl rand -base64 32 | tr -- '+/' '-_')"
```

Change `--github-user` in [`k8s/oauth2-proxy.yaml`](k8s/oauth2-proxy.yaml) to
your own GitHub username

### Verified working

Each of these was checked against the running cluster, not assumed:

| Check                                       | Result                                                          |
| ------------------------------------------- | --------------------------------------------------------------- |
| Page served over HTTPS through the ingress  | `HTTP 200`                                                      |
| Plain HTTP                                  | `HTTP 308` redirect to HTTPS                                    |
| Container user                              | `uid=10101` — not root, and above the host-collision range      |
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
GitHub Actions builds, scans and pushes to GHCR, and **Argo CD inside the
cluster pulls and reconciles**. This is built and the full loop is verified —
a push to `app/` reaches the browser with no human touching the cluster:

```
git push
  → Actions: build → scan (blocking) → push to GHCR → commit digest to k8s/
  → Argo CD: sees the commit → syncs → new pod running the exact digest
  → https://hello.127.0.0.1.nip.io:8443/ serves the new page
```

**`selfHeal` is the part that is a security control, not just convenience.**
It reverts changes made directly against the cluster, so `kubectl edit` to
drop a `securityContext` — or to swap in an image that never passed the scan
gate — is undone automatically. Verified: an unscanned `nginx:1.25-alpine`
set with `kubectl set image` was reverted in about six seconds. That makes
Git the _only_ supported way to change what runs, rather than merely the
recommended one.

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
long-lived bearer credential.

**To the cluster: nothing.** The pipeline has no cluster credential at all,
because it never talks to the cluster. It ends by committing an image digest
to this repository; the cluster is what reaches out. There is no kubeconfig,
no service principal, and no inbound network path to the cluster anywhere
in CI.

**What the token _can_ do, and why.** The job requests three scopes and no
more: `packages: write` to push the image, `security-events: write` to file
SARIF, and `contents: write` to commit the digest. The workflow's top-level
default is `contents: read`, so anything added later starts read-only and has
to ask.

**Third-party actions are pinned to commit SHAs, not tags.** Every `uses:`
line references a 40-character SHA with the version in a trailing comment.

### Acting on scan results

Layers 1 and 4 are **built**; 2 and 3 are designed.

1. **In the pipeline (blocking) — built.** Trivy runs against the built image
   before push and **fails the build** on HIGH/CRITICAL with a fix available.
2. **In the cluster (detecting) — built.** **Trivy Operator** scans running
   workloads on a schedule and writes `VulnerabilityReport`,
   `ConfigAuditReport` and `ExposedSecretReport` CRDs. This catches what the
   pipeline cannot: a CVE disclosed _after_ the image shipped. It watches only
   the application namespace

3. **Manifest misconfiguration (blocking) — built.** A second blocking gate
   scans `k8s/` for misconfiguration, a failure class the package scanners
   cannot see at all. It reports to the Security tab as well as failing.

**Two decisions inside the blocking gate that are worth defending.**

_Only fixable findings block._ The gate runs with `ignore-unfixed: true`.

\_Scanning happens before push, not after.

**What does not roll back automatically, and why.** Automatic rollback on a new
CVE is a bad default: the CVE is usually in a base-image layer, so the previous
image is affected too. Rolling back trades a known vulnerability for an older
known vulnerability while looking like remediation. The action that helps is
rebuild-and-redeploy on a patched base, which is forward, not backward.

### Scan coverage: what each layer catches that the others miss

| Layer                                                 | Catches                                                                                                                                   | Misses                                                                      |
| ----------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| **Build-time image scan** (**built**, blocking)       | Vulnerable packages in the image, before it ships. Cheapest place to fix.                                                                 | Anything disclosed after the build. Misconfiguration in how it is deployed. |
| **Runtime workload scan** (**built**, Trivy Operator) | Newly-disclosed CVEs in already-running images; drift between what CI approved and what is actually running.                              | Nothing, until it is already running.                                       |
| **Manifest scan** (**built**, blocking)               | `privileged: true`, missing `runAsNonRoot`, no resource limits, a public AKS API server, an unrestricted NSG. Misconfiguration, not CVEs. | Vulnerable packages. Different failure class entirely.                      |
| **SBOM + provenance** (**built**, attested)           | What is actually in the image, so that when a CVE lands you can answer "are we affected?" in minutes rather than days.                    | Nothing by itself — it is the inventory the other layers query.             |

**Still skipped deliberately:** infrastructure-code scanning of _cloud_
resources, because there is no
Terraform in this repo. On a
real repo this is `checkov`/`tfsec`/`trivy config` in CI against the Terraform,
failing on a public API server, unencrypted state, or over-broad role
assignment. It is the layer that catches an entire class the image scanners are
blind to, and it is the one most often missing.

### Image hygiene

**Built:** `nginxinc/nginx-unprivileged:1.30-alpine@sha256:daa17b94...`

- **Pinned by digest**, for the same reason the kind node image is: a tag is a
  mutable pointer, and "we deployed `1.30-alpine`" does not identify what ran.
- **nginx _stable_ (1.30.x), not mainline.** Stable gets security fixes
  without mainline's feature churn, which is what you want under an image
  rebuilt on a schedule. This specific version was also chosen because it
  scans clean — 1.29.x still carries fixable HIGH/CRITICAL CVEs that the
  pipeline's blocking gate correctly rejects.
- **Runs as UID 10101**, not the image's own 101. Low UIDs can collide with
  real accounts on the node, so a container escape lands as a host user
  rather than as nobody. Raised in response to an actual Trivy finding
  (`KSV-0020`/`KSV-0021`) rather than by guesswork, and verified to still
  work under a read-only root filesystem.
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

**Argo CD, which is the interesting one.** It holds cluster-write by design,
so it is the highest-value target in the cluster — more so than the workload
it deploys. Two separate controls, because they do different things and only
having one is a common mistake:

_The AppProject_ ([`gitops/appproject.yaml`](gitops/appproject.yaml)) narrows
what an Application may declare: one repo, one cluster, one namespace, and an
allow-list of resource kinds. Cluster-scoped access is limited to `Namespace`,
so an Application in this project cannot create a ClusterRoleBinding. Argo
CD's built-in `default` project permits any repo into any namespace, and most
installs never move off it. Verified — an Application pointing at a foreign
repo is rejected:

```console
InvalidSpecError: application repo https://github.com/argoproj/argocd-example-apps.git
is not permitted in project 'hello-world'
```

_The controller's own RBAC_ is the control people miss, because an AppProject
looks like it covers this and does not. The AppProject constrains what an
Application may _declare_; the controller's ServiceAccount is what performs
the writes. Out of the box it is effectively cluster-admin. Measured, not
assumed:

```console
$ kubectl auth can-i list secrets --all-namespaces \
    --as=system:serviceaccount:argocd:argocd-application-controller
yes
$ kubectl auth can-i create clusterrolebindings --as=...
yes
```

Being able to create ClusterRoleBindings means it can grant itself anything;
being able to read every Secret means every credential in the cluster. So the
default ClusterRole was replaced with rules covering only the resource kinds
the AppProject allows, plus the pods/replicasets needed for health assessment
and the events it writes. After:

```console
list secrets cluster-wide:      no
create clusterrolebindings:     no
delete nodes:                   no
read configmaps in kube-system: no
update deployments in hello-world: yes   <- still works
```

And it still functions: `selfHeal` reverted a tampered image in about six
seconds under the reduced permissions, which proves the write path is intact
rather than merely that nothing has broken yet.

The honest cost: this instance can now manage only these resource kinds.
Adding a ConfigMap to `k8s/` fails to sync until both the AppProject and
these rules are updated. That friction is the control working, but at
multi-application scale you would run one Argo CD per tenant rather than
grow a single cluster-wide list forever.

**What is still over-privileged.** `argocd-server` was left on its default
ClusterRole — it is the API behind the UI and narrowing it needs more care
than the time here allowed. The initial admin account also still exists; in
production that is disabled in favour of Entra ID via OIDC, the same as for
the AKS API server itself.

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

**Built:** oauth2-proxy in front of nginx, against a GitHub OAuth app,
enforced at the ingress so an anonymous request never reaches the pod.

ingress-nginx issues an `auth-url` subrequest to oauth2-proxy before
proxying anything. A 401 means the request is never forwarded and the
visitor is redirected to GitHub instead.

Verified:

```console
$ curl -sk -o /dev/null -w '%{http_code} -> %{redirect_url}' https://hello.127.0.0.1.nip.io:8443/
302 -> https://hello.127.0.0.1.nip.io:8443/oauth2/start?rd=%2F

# following the chain ends at GitHub's login page, not at the content
$ curl -skL --max-redirs 5 -o /dev/null -w '%{url_effective}' https://hello.127.0.0.1.nip.io:8443/
https://github.com/login?client_id=…&return_to=%2Flogin%2Foauth%2Fauthorize…
```

---

## What I'd do differently for production

- **Terraform for the AKS cluster**, with the security-relevant decisions in
  review: private API server, Entra-integrated RBAC with local accounts
  disabled, `AcrPull` via kubelet identity, Workload Identity for pods, and
  network exposure through a single ingress.
- **Admission policy (Kyverno)** enforcing signed images, non-root, no
  `:latest`, resource limits — so the controls are not merely conventions the
  next person can skip.
- **Image signing (cosign) with verification at admission**, closing the gap
  where a correctly-named image that CI never built gets deployed.
- **Alerting on scan results** wired to wherever the team actually looks, and
  an SLA per severity rather than a dashboard.
- **Argo CD scoped per-namespace**, not cluster-admin.
