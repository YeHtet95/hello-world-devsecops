# hello-world on Kubernetes — DevSecOps technical assessment

A static nginx "hello world", built into an image by a pipeline, deployed to a
Kubernetes cluster, scanned on a schedule,
and reachable only after authenticating.

The application is one HTML file.

---

## Status: built vs. designed

| Outcome                                     | Status                       | Where                                                                    |
| ------------------------------------------- | ---------------------------- | ------------------------------------------------------------------------ |
| Local cluster, reproducible from the repo   | **Built**                    | [`cluster/`](cluster/), [`Makefile`](Makefile)                           |
| Ingress controller, pinned                  | **Built**                    | [`cluster/ingress-nginx-values.yaml`](cluster/ingress-nginx-values.yaml) |
| Page served from an image built             | **Built**                    | [`app/Dockerfile`](app/Dockerfile), [`k8s/`](k8s/)                       |
| Workload hardening (non-root, read-only FS) | **Built**                    | [`k8s/deployment.yaml`](k8s/deployment.yaml)                             |
| Pod Security Admission (`restricted`)       | **Built**                    | [`k8s/namespace.yaml`](k8s/namespace.yaml)                               |
| NetworkPolicy                               | **Written, inert on kind**   | [`k8s/networkpolicy.yaml`](k8s/networkpolicy.yaml)                       |
| Pipeline: build, scan, publish to GHCR      | **Built**                    | [`.github/workflows/`](.github/workflows/build-scan-publish.yml)         |
| Build-time scan with a blocking threshold   | **Built**                    | same — gates 1 and 3                                                     |
| Manifest misconfiguration scan (blocking)   | **Built**                    | same, plus [`.trivyignore.yaml`](.trivyignore.yaml)                      |
| SBOM + provenance attestations              | **Built**                    | same — `sbom: true`, `provenance: mode=max`                              |
| Reaches the cluster through automation      | **Built**                    | [`gitops/`](gitops/), [`cluster/argocd-values.yaml`](cluster/argocd-values.yaml) |
| Argo CD controller scoped off cluster-admin | **Built**                    | [`cluster/argocd-values.yaml`](cluster/argocd-values.yaml)                       |
| Scheduled vulnerability scanning in-cluster | _Designed, not built_        | [Acting on scan results](#acting-on-scan-results)                        |
| Authentication in front of the page         | _Designed, not built_        | [Authentication](#authentication)                                        |
| AKS provisioning                            | _Discussion only, by design_ |                                                                          |

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

Manual `kubectl` is for iteration only, per the brief. The pipeline path is
live as far as the registry: pushing a change under `app/` triggers
[`build-scan-publish`](.github/workflows/build-scan-publish.yml), which
builds, scans, publishes to GHCR and commits the new digest to
[`k8s/kustomization.yaml`](k8s/kustomization.yaml). The final hop — Argo CD
noticing that commit and reconciling — is not yet installed, so
`kubectl apply -k k8s/` stands in for it. What it deploys is the exact digest
CI published, pulled from GHCR rather than side-loaded:

```console
$ kubectl -n hello-world get pod -o jsonpath='{.items[0].status.containerStatuses[0].imageID}'
ghcr.io/yehtet95/hello-world-devsecops@sha256:32816991ff35…
```

Argo CD is installed by `make argocd && make gitops`. Its UI is at
<https://argocd.127.0.0.1.nip.io:8443/>; `make argocd-password` reads the
generated admin password out of the cluster. That password is deliberately
not in this repo and not in any manifest.

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
                    │  ingress-nginx ──▶ [oauth2-proxy] ──▶ app │
                    │                     ^ not built yet       │
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

Argo CD also holds **no git credential**, because the repo is public — one
fewer long-lived secret in the cluster. Against a private repo this would be
a read-only deploy key or GitHub App installation token scoped to this
repository alone.

**`selfHeal` is the part that is a security control, not just convenience.**
It reverts changes made directly against the cluster, so `kubectl edit` to
drop a `securityContext` — or to swap in an image that never passed the scan
gate — is undone automatically. Verified: an unscanned `nginx:1.25-alpine`
set with `kubectl set image` was reverted in about six seconds. That makes
Git the *only* supported way to change what runs, rather than merely the
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
long-lived bearer credential that typically carries far more scope than one
repo's packages and is rotated only when somebody remembers.

**To the cluster: nothing.** The pipeline has no cluster credential at all,
because it never talks to the cluster. It ends by committing an image digest
to this repository; the cluster is what reaches out. There is no kubeconfig,
no service principal, and no inbound network path to the cluster anywhere
in CI.

**What the token _can_ do, and why.** The job requests three scopes and no
more: `packages: write` to push the image, `security-events: write` to file
SARIF, and `contents: write` to commit the digest. The workflow's top-level
default is `contents: read`, so anything added later starts read-only and has
to ask. `contents: write` is the one worth scrutinising — it lets CI push to
`main`. It is scoped to this repository and dies with the job, but on a
protected branch this is where you would instead have CI open a PR, or move
image updates to Argo CD Image Updater and drop the scope entirely.

**Third-party actions are pinned to commit SHAs, not tags.** Every `uses:`
line references a 40-character SHA with the version in a trailing comment.
A tag like `@v4` is a mutable pointer controlled by someone else, and these
actions run inside the job with access to its token — `@v4` is a promise that
the code behind that tag will not change. The SHA is not a promise. The cost
is that updates no longer arrive silently, which is the intended trade: in a
real repo Dependabot raises them as reviewable PRs.

**One long-lived credential does still exist**, and it is worth naming rather
than glossing: my own GitHub account's access to this repository. Nothing in
the pipeline can be more secure than the account that can rewrite the
pipeline. In production that is addressed with branch protection, required
reviews, and enforced SSO/MFA on the org — not with anything inside the
workflow file.

### Acting on scan results

Layers 1 and 4 are **built**; 2 and 3 are designed.

1. **In the pipeline (blocking) — built.** Trivy runs against the built image
   before push and **fails the build** on HIGH/CRITICAL with a fix available.
   This is the only place a block is cheap
2. **In the cluster (detecting).** **Trivy Operator** scans running workloads
   continuously and writes `VulnerabilityReport` CRDs. This catches what the
   pipeline cannot: a CVE disclosed _after_ the image shipped.
3. **Getting it to a human.** The reports are CRDs, so they are queryable — but
   nobody runs `kubectl get vulnerabilityreports` unprompted. Route them
   outward: metrics scraped to an alert on "critical count > 0 in a running
   workload", or a scheduled job that opens/updates a ticket per finding.
4. **Manifest misconfiguration (blocking) — built.** A second blocking gate
   scans `k8s/` for misconfiguration, a failure class the package scanners
   cannot see at all. It reports to the Security tab as well as failing.
5. **Blocking deployment of what is already known-bad — designed.** A Kyverno
   policy refusing images without a passing scan, or unsigned images, closes
   the gap where something reaches the cluster without passing through CI.

**Two decisions inside the blocking gate that are worth defending.**

_Only fixable findings block._ The gate runs with `ignore-unfixed: true`.
Blocking on a vulnerability with no available patch does not make anyone
safer — it makes the pipeline permanently red, and a permanently red pipeline
gets bypassed. Unfixed findings are still reported in full by the SARIF gate;
they just do not stop the build.

_Scanning happens before push, not after._ The image is built single-arch and
loaded into the runner's local Docker, scanned there, and only then rebuilt
multi-arch and pushed. Scanning after push means a failing image is already
in the registry and pullable while the pipeline decides whether to fail it.

**This gate has already caught something real.** The base image was originally
`nginx-unprivileged:1.29.1-alpine`. It carries fixable HIGH/CRITICAL CVEs in
pcre2, zlib, musl, libxml2 and nghttp2, inherited from an older Alpine layer —
so the gate rejected it. The fix was to move to `1.30-alpine` (nginx stable),
which scans clean. That is the gate doing its job rather than a hypothetical.

**Triage, not blanket suppression.** The first run put four misconfiguration
findings in the Security tab. Each got a decision rather than a bulk ignore:

| Finding                                       | Decision                                                                                                                                                                                                                                                                    |
| --------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `KSV-0020` / `KSV-0021` — UID/GID below 10000 | **Fixed.** Moved the workload to UID 10101. Low UIDs risk colliding with real accounts on the node, so a container escape lands as a host user. Possible here because nginx writes only to `/tmp` (an `emptyDir`, writable by any UID) and reads only world-readable files. |
| `KSV-0013` — "should specify an image tag"    | **Accepted.** The manifest pins by digest, which is strictly stronger than a tag. The rule penalises the safer choice.                                                                                                                                                      |
| `KSV-0125` — "untrusted registry"             | **Accepted, with a real fix named.** `ghcr.io` is not in Trivy's default trust list but is this project's own registry. Configuring the trust list is the proper fix and belongs with the ACR work.                                                                         |

The two accepted findings live in [`.trivyignore.yaml`](.trivyignore.yaml)
with a written reason and an **expiry date**, not a bare rule ID. The expiry
is the point: acceptance is temporary by default, and a lapsed entry
reappears and has to be re-argued. This is the same mechanism the
[unfixable-CVE process](#the-finding-you-cant-fix) below describes.

With the baseline at zero, the manifest gate was switched from reporting to
**blocking**. The sequencing matters: get to zero first, then fail on
regression. A gate turned on over a non-zero baseline just fails constantly
and teaches people to ignore it.

**What does not roll back automatically, and why.** Automatic rollback on a new
CVE is a bad default: the CVE is usually in a base-image layer, so the previous
image is affected too. Rolling back trades a known vulnerability for an older
known vulnerability while looking like remediation. The action that helps is
rebuild-and-redeploy on a patched base, which is forward, not backward.

### Scan coverage: what each layer catches that the others miss

| Layer                                                  | Catches                                                                                                                                   | Misses                                                                      |
| ------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| **Build-time image scan** (**built**, blocking)        | Vulnerable packages in the image, before it ships. Cheapest place to fix.                                                                 | Anything disclosed after the build. Misconfiguration in how it is deployed. |
| **Runtime workload scan** (_designed_, Trivy Operator) | Newly-disclosed CVEs in already-running images; drift between what CI approved and what is actually running.                              | Nothing, until it is already running.                                       |
| **Manifest scan** (**built**, blocking)                | `privileged: true`, missing `runAsNonRoot`, no resource limits, a public AKS API server, an unrestricted NSG. Misconfiguration, not CVEs. | Vulnerable packages. Different failure class entirely.                      |
| **SBOM + provenance** (**built**, attested)            | What is actually in the image, so that when a CVE lands you can answer "are we affected?" in minutes rather than days.                    | Nothing by itself — it is the inventory the other layers query.             |

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

*The AppProject* ([`gitops/appproject.yaml`](gitops/appproject.yaml)) narrows
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

*The controller's own RBAC* is the control people miss, because an AppProject
looks like it covers this and does not. The AppProject constrains what an
Application may *declare*; the controller's ServiceAccount is what performs
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

- Trivy Operator (scheduled in-cluster scanning) and oauth2-proxy
  (authentication) are not yet built. These are the two remaining items from
  the brief's outcome list.
- `argocd-server` still runs on its default ClusterRole, and the Argo CD
  initial admin account still exists. Both are noted under
  [least privilege](#least-privilege).
- The blocking thresholds — HIGH/CRITICAL for images, MEDIUM and above for
  manifests — are a judgement call, not a standard.
