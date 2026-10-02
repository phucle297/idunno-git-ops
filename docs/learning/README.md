# Learn the idunno GitOps stack

This documentation explains why the repository is structured this way, not only which commands to copy. Work through it in order:

1. [Mental model and architecture](architecture.md)
2. [Follow one deployment](deployment-flow.md)
3. [Hands-on exercises](hands-on-labs.md)
4. [Troubleshooting by layer](troubleshooting.md)

The production setup commands remain in the repository [README](../../README.md).

## What you should be able to explain

After completing the learning path, you should be able to answer:

- Why does Terraform create the cluster, but Flux deploy the app?
- Why are third-party controllers installed with Helm while the app uses Kustomize?
- Why does CI push an image but not run `kubectl apply`?
- How does a Git commit eventually become a running Pod?
- How does the app receive secrets without committing secret values to Git?
- Which repository is the source of truth for application code, infrastructure, and deployed state?

## Vocabulary

| Term | Meaning in this repository |
| --- | --- |
| Desired state | The version-controlled description of what should exist. |
| Reconciliation | A controller repeatedly comparing desired state with actual state and correcting drift. |
| GitOps | Git stores desired deployment state; an in-cluster controller applies it. |
| Controller | A Kubernetes process that watches resources and moves the cluster toward their requested state. |
| Custom Resource Definition (CRD) | An extension that adds a new resource kind, such as Flux `GitRepository`. |
| Immutable image | A uniquely tagged container image that is never overwritten. |
| Workload identity | Short-lived AWS access derived from workload identity instead of stored AWS keys. |
| IRSA | IAM Roles for Service Accounts: EKS maps a Kubernetes ServiceAccount to an AWS IAM role. |
| Reproducible build | The same committed inputs and pinned dependencies produce the same deployment artifact. |

## Repository map

```text
idunno/                              application source repository
├── Dockerfile                      production image contract
└── .github/workflows/ci.yaml       test, build, smoke-test, push

idunno-git-ops/                      infrastructure and deployment state
├── terraform/cluster/              AWS network, EKS, ECR, GitHub OIDC
├── terraform/platform/             Helm-installed cluster controllers
├── clusters/production/            Flux-reconciled desired state
│   ├── image-automation.yaml        ECR discovery and Git image updates
│   └── apps/idunno/                 app Deployment, Service, Ingress, secrets
└── .github/workflows/validate.yaml  infrastructure checks only
```

## Learning rule

Before running a command, classify it:

- **Read-only:** inspect or render state; safe for learning.
- **Local mutation:** changes local files or local Docker images; reversible.
- **Cloud mutation:** creates, changes, or deletes AWS/Kubernetes resources; review a plan first.
- **Git mutation:** changes the desired state Flux will eventually apply.

The exercises label commands accordingly.
