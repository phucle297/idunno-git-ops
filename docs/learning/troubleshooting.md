# Troubleshooting by layer

Debug from the earliest failing layer. Do not jump directly to restarting Pods.

## Decision path

```text
Did app CI pass?
  ├─ no  → inspect test/build/smoke-test logs
  └─ yes
      ▼
Was an image pushed to ECR?
  ├─ no  → inspect GitHub OIDC role and ECR permissions
  └─ yes
      ▼
Did Flux select and commit it?
  ├─ no  → inspect ImageRepository, ImagePolicy, ImageUpdateAutomation
  └─ yes
      ▼
Did Flux reconcile the commit?
  ├─ no  → inspect GitRepository and Kustomization
  └─ yes
      ▼
Did Kubernetes complete the rollout?
  ├─ no  → inspect Events, Pods, probes, and ExternalSecret
  └─ yes → inspect Service, Ingress, ALB, DNS, and application logs
```

## CI or image build

```bash
# Local equivalents of the app checks
npm ci
npm run lint
npm run typecheck
npm test
npm run build
docker build -t idunno:debug .
```

If local checks pass but GitHub fails, compare Node versions, repository variables, workflow permissions, and the exact commit being tested.

## GitHub cannot push to ECR

Check:

1. `AWS_REGION`, `AWS_DEPLOY_ROLE_ARN`, and `ECR_REGISTRY` repository variables.
2. The workflow has `id-token: write`.
3. The IAM trust condition matches `repo:phucle297/idunno:ref:refs/heads/main`.
4. The workflow is running from `main`, because pull requests intentionally cannot assume the publishing role.

Do not solve OIDC problems by creating a long-lived AWS access key.

## Flux source or reconciliation

```bash
flux get sources git -A
flux get kustomizations -A
kubectl -n flux-system describe gitrepository flux-system
kubectl -n flux-system describe kustomization flux-system
```

Typical causes:

- deploy key missing, revoked, or lacking write permission;
- GitHub host key mismatch;
- branch protection blocking Flux's image commit;
- invalid YAML or an unresolved `${...}` substitution;
- a resource health check timing out.

## Image automation

```bash
flux get images repository idunno -n flux-system
flux get images policy idunno -n flux-system
flux get images update idunno -n flux-system
kubectl -n flux-system logs deployment/image-reflector-controller
kubectl -n flux-system logs deployment/image-automation-controller
```

Check that the ECR tag matches `main-<14 digits>-<7 lowercase hex characters>`. Other tags are intentionally ignored.

## Secret synchronization

```bash
kubectl get clustersecretstore aws-secrets-manager
kubectl -n idunno describe externalsecret idunno
kubectl -n external-secrets logs deployment/external-secrets
```

Check the IRSA annotation and whether `/idunno/production/app` contains both expected JSON properties. Avoid printing the resulting Kubernetes Secret.

## Pod rollout

```bash
kubectl -n idunno rollout status deployment/idunno
kubectl -n idunno get pods -o wide
kubectl -n idunno describe pod <pod-name>
kubectl -n idunno logs <pod-name>
kubectl -n idunno get events --sort-by=.lastTimestamp
```

Interpret common states:

| State | First place to inspect |
| --- | --- |
| `Pending` | scheduling events, node capacity, topology constraints |
| `CreateContainerConfigError` | existence of `idunno-env` Secret |
| `ImagePullBackOff` | image name/tag, node ECR access |
| Running but not Ready | `/api/health`, readiness probe, app logs |
| Repeated restarts | liveness probe and previous container logs |

## Ingress and ALB

```bash
kubectl -n idunno describe ingress idunno
kubectl -n idunno get service idunno
kubectl -n kube-system logs deployment/aws-load-balancer-controller
curl -v "https://<hostname>/api/health"
```

Check ACM certificate region and hostname coverage, DNS target, ALB target health, and security groups. The Service remains `ClusterIP`; the ALB reaches Pods through IP targets.

## Emergency changes and GitOps

If an approved emergency requires a direct cluster change, make the equivalent Git change immediately. Otherwise Flux will either revert the emergency change or Git will no longer describe production.

Prefer rollback by reverting the Git image-update commit. That preserves the audit trail and lets Flux perform the rollback consistently.
