# Mental model and architecture

## One tool, one responsibility

The most important design principle is ownership. Each tool owns the layer it is good at.

| Tool | Owns | Does not own |
| --- | --- | --- |
| Terraform | AWS resources, IAM, EKS, ECR, controller installation | Routine app releases |
| Helm | Packaging and configuring third-party controllers | The first-party app deployment |
| Kustomize | Composing the app's plain Kubernetes resources | AWS infrastructure |
| Flux | Continuously reconciling Git with Kubernetes | Building application images |
| GitHub Actions | Testing and producing immutable images | Direct production deployment |
| External Secrets | Copying approved secret values into Kubernetes | Creating the source secret value |

This avoids two tools fighting over the same object. For example, Terraform does not manage the app `Deployment`; Flux does.

## The architecture

```text
┌─────────────────────┐                 ┌──────────────────────┐
│ idunno app Git repo │                 │ GitOps Git repository│
└──────────┬──────────┘                 └──────────┬───────────┘
           │ push                                   │ desired state
           ▼                                        ▼
┌─────────────────────┐   immutable image   ┌───────────────────┐
│ GitHub Actions      │────────────────────▶│ Amazon ECR        │
│ test/build/smoke    │                     └─────────┬─────────┘
└─────────────────────┘                               │ observe tags
                                                      ▼
                                            ┌━━━━━━━━━━━━━━━━━━━┐
                                            ┃ Flux in EKS       ┃
                                            ┃ observe/commit/   ┃
                                            ┃ reconcile         ┃
                                            └━━━━━━━┳━━━━━━━━━━━┘
                                                    ┃ apply
                                                    ▼
┌─────────────────────┐                 ┌───────────────────────┐
│ AWS Secrets Manager │────External────▶│ Pods, Service, ALB    │
└─────────────────────┘     Secrets     └───────────────────────┘
```

The decisive GitOps property is that Flux **pulls** desired state from Git. CI does not need broad Kubernetes administrator credentials.

## Why Terraform is split into two roots

`terraform/cluster` creates EKS. `terraform/platform` connects to that existing cluster and installs controllers.

Trying to do both in one Terraform root creates a bootstrap cycle:

```text
Kubernetes provider needs EKS endpoint
             ▲
             │
Terraform is still creating EKS
```

Separate state and separate applies make the dependency explicit:

```text
terraform/cluster ━━━▶ existing EKS ━━━▶ terraform/platform
```

The platform root reads selected cluster outputs through `terraform_remote_state` rather than duplicating identifiers.

## Why Helm for controllers but not the app

Flux, External Secrets, and AWS Load Balancer Controller are third-party systems containing many resources and CRDs. Their maintainers publish versioned Helm charts, so this repository consumes those charts instead of copying upstream YAML.

The idunno app currently needs a small, readable set of resources. Plain YAML plus Kustomize has less indirection than a custom chart:

```text
Deployment + Service + Ingress + ExternalSecret + policies
```

Create an app Helm chart only when there is genuine reusable configuration across multiple consumers or environments. Do not introduce templates merely because Helm is available.

## Security boundaries

- GitHub obtains short-lived AWS credentials through OIDC; no long-lived AWS access keys are stored in GitHub.
- EKS workers run in private subnets.
- The public Kubernetes API rejects unrestricted `0.0.0.0/0` access.
- Controllers receive narrow AWS permissions through IRSA.
- Secret values remain in Secrets Manager; Git stores only references.
- The app runs as non-root, drops Linux capabilities, uses a read-only root filesystem, and receives a small `/tmp` volume.
- The ALB redirects HTTP to HTTPS and has deletion protection enabled.
- ECR tags are immutable, so a deployed tag cannot silently change contents.

## Sources of truth

| Question | Source of truth |
| --- | --- |
| What should the app do? | `idunno` source code |
| How is the image built? | `idunno/Dockerfile` and app CI workflow |
| Which AWS resources should exist? | `terraform/` |
| Which image should production run? | `clusters/production/apps/idunno/deployment.yaml` |
| What secret value should the app receive? | AWS Secrets Manager |
| What is actually running now? | Kubernetes and AWS APIs; this is observed state, not desired state |
