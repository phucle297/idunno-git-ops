# Hands-on exercises

Start with local and read-only exercises. Cloud-mutating exercises incur AWS cost and should only be performed when you intend to provision the environment.

## Lab 1: Render the desired state locally

**Effect:** read-only/local output.

```bash
ECR_REPOSITORY=123456789012.dkr.ecr.ap-southeast-1.amazonaws.com/idunno \
APP_HOSTNAME=english.example.com \
ACM_CERTIFICATE_ARN=arn:aws:acm:ap-southeast-1:123456789012:certificate/example \
./scripts/render-manifests.sh > /tmp/idunno.yaml

less /tmp/idunno.yaml
```

Questions:

1. Which resources have namespace `idunno`?
2. Where were the three `${...}` placeholders replaced?
3. Which resource routes port 80 to container port 3000?

## Lab 2: Trace ownership

**Effect:** read-only.

Find each owner:

```bash
rg 'aws_ecr_repository|helm_release|kind: Deployment|kind: ImagePolicy' .
```

Explain why moving the app Deployment into Terraform would weaken the current ownership boundary.

Expected reasoning: routine releases would require Terraform to manage rapidly changing app state, and Flux and Terraform could compete over the same resource.

## Lab 3: Inspect Terraform without changing AWS

**Effect:** local provider/module downloads; no cloud mutation.

```bash
terraform -chdir=terraform/cluster init -backend=false
terraform -chdir=terraform/cluster validate
terraform -chdir=terraform/platform init -backend=false
terraform -chdir=terraform/platform validate
terraform fmt -check -recursive terraform
```

Then inspect dependencies:

```bash
terraform -chdir=terraform/cluster providers
terraform -chdir=terraform/platform providers
```

Notice that the platform root uses AWS and Helm, while the cluster root does not need Helm.

## Lab 4: Read a Terraform plan

**Effect:** read-only against AWS when correctly configured; creating the saved plan is local.

After configuring the backend and variables:

```bash
terraform -chdir=terraform/cluster plan -out=cluster.tfplan
terraform -chdir=terraform/cluster show cluster.tfplan
```

Do not apply yet. Identify:

- resources that cost money continuously;
- IAM trust policies;
- public entry points;
- resources with deletion protection or recovery windows;
- values known only after apply.

## Lab 5: Observe Flux

**Effect:** read-only against the cluster.

```bash
flux check
flux get sources git -A
flux get kustomizations -A
flux get images repository -A
flux get images policy -A
flux get images update -A
```

For each resource, compare its `READY`, `STATUS`, and last reconciliation time. Then locate its YAML definition in Git.

## Lab 6: Follow a release without changing it

**Effect:** read-only.

```bash
kubectl -n idunno get deployment idunno -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
git log --oneline -- clusters/production/apps/idunno/deployment.yaml
flux get images policy idunno -n flux-system
```

The image in Kubernetes should match the image committed in Git. If the Flux policy sees a newer image, reconciliation may still be in progress or blocked.

## Lab 7: Observe secret synchronization safely

**Effect:** read-only. These commands intentionally do not print secret values.

```bash
kubectl -n idunno describe externalsecret idunno
kubectl get clustersecretstore aws-secrets-manager
kubectl -n idunno get secret idunno-env \
  -o jsonpath='{range $k,$v := .data}{$k}{"\n"}{end}'
```

Confirm that the expected keys exist. Do not decode or paste secret values into terminals, tickets, or Git.

## Lab 8: Make a controlled application release

**Effect:** Git and production mutation after merge.

1. Make a small app change in `idunno`.
2. Open a pull request and observe test plus image smoke-test behavior.
3. Merge to `main`.
4. Watch the image appear in ECR.
5. Watch Flux create an image-update commit in `idunno-git-ops`.
6. Watch the Deployment rollout.
7. Verify `/api/health` through the public hostname.

Do not manually patch the Deployment during this exercise. The goal is to observe the complete GitOps path.

## Lab 9: See reconciliation repair drift

**Effect:** temporary production mutation. Use only in a learning environment or approved maintenance window.

First record the desired replica count from Git. Then temporarily change live state:

```bash
kubectl -n idunno scale deployment/idunno --replicas=1
kubectl -n idunno get deployment idunno --watch
```

Flux should restore the Git-declared replica count. This demonstrates reconciliation: the controller does not merely deploy once; it continually corrects drift.

Never use deliberate drift as a routine operational method.
