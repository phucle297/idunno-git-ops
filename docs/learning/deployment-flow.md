# Follow one deployment

This chapter traces a normal application change after the one-time Terraform setup is complete.

## 1. A developer pushes app code

The push enters `idunno/.github/workflows/ci.yaml`.

The test job runs:

```text
npm ci
  ├── lint
  ├── typecheck
  ├── tests
  └── Next.js production build
```

If any check fails, no image is published and production does not change.

## 2. CI proves the production image can run

CI builds the actual Docker image, launches it with production-like restrictions, and calls `GET /api/health`.

This catches failures that a source build cannot catch, including:

- wrong image entrypoint;
- server binding only to localhost;
- inability to run as non-root;
- attempts to write outside `/tmp`;
- a missing health route.

## 3. CI pushes an immutable ECR image

On `main`, GitHub exchanges its OIDC token for the narrowly scoped AWS role created in `terraform/cluster/main.tf`.

The resulting tag looks like:

```text
main-20261002193000-a1b2c3d
```

It contains a sortable UTC timestamp and the source commit prefix. ECR rejects attempts to overwrite it.

## 4. Flux discovers the image

Three Flux resources in `clusters/production/image-automation.yaml` divide the work:

```text
ImageRepository      scans ECR tags
       │
       ▼
ImagePolicy          selects the newest valid main-* tag
       │
       ▼
ImageUpdateAutomation edits deployment.yaml and pushes a Git commit
```

The marker beside the image in `deployment.yaml` tells Flux which field it may update.

## 5. Git records the release

Flux commits the selected image into this GitOps repository. That commit is the deployment audit record.

This is different from CI running `kubectl set image`: with a direct command, the cluster changes but Git can remain stale. Here Git changes first, and reconciliation follows.

## 6. Flux reconciles Kubernetes

The Flux `Kustomization` watches `clusters/production`. It renders the nested `kustomization.yaml` files and substitutes cluster-specific values such as:

- ECR repository URL;
- public hostname;
- ACM certificate ARN.

Flux then applies the resources and prunes resources removed from Git.

## 7. Kubernetes performs a safe rollout

The `Deployment` requests two replicas and uses:

- `maxUnavailable: 0`, keeping old Pods until replacements are ready;
- a startup probe, allowing bounded startup time;
- a readiness probe, preventing traffic before readiness;
- a liveness probe, restarting a persistently unhealthy process;
- a PodDisruptionBudget, retaining one available Pod during voluntary disruption.

The Service gives Pods a stable internal endpoint. The ALB Ingress routes public HTTPS traffic to that Service.

## 8. Runtime configuration arrives separately

The secret path is independent of the image path:

```text
AWS Secrets Manager
        │ IRSA-authenticated read
        ▼
External Secrets Operator
        │ creates/refreshes
        ▼
Kubernetes Secret: idunno-env
        │ envFrom
        ▼
Application Pod
```

The image contains no environment-specific Supabase values. The Next.js `/api/config` route reads injected process environment at runtime and exposes the intentionally public Supabase URL and anon key to the browser.

## Failure behavior

| Failure | Result |
| --- | --- |
| Test or build fails | No image is pushed. |
| Image health test fails | No image is pushed. |
| ECR cannot be read | Flux leaves the previous image selected. |
| Flux cannot push its Git update | Cluster remains on Git's current desired image. |
| New Pod never becomes ready | Rolling update retains old ready Pods. |
| Secret does not exist | Pod creation waits/fails rather than starting with partial configuration. |
