# idunno GitOps

Production AWS EKS infrastructure and GitOps delivery for the `idunno` English-practice app.

## Learn this stack

If you are learning GitOps, begin with the [learning path](docs/learning/README.md). It explains the responsibility of each tool, traces a deployment from commit to EKS, and includes safe hands-on exercises before the production provisioning steps below.

## Architecture

- Terraform creates a three-AZ VPC, private EKS worker nodes, ECR, GitHub Actions OIDC access, and EKS audit/control-plane logging.
- A separate Terraform root installs Flux, AWS Load Balancer Controller, and External Secrets Operator with IRSA.
- GitHub Actions in `phucle297/idunno` tests and builds the app, then pushes an immutable `main-<UTC timestamp>-<short SHA>` image to ECR.
- Flux detects the newest image, commits the new tag to this repository, and reconciles the deployment.
- External Secrets reads the Supabase configuration from AWS Secrets Manager. No secret value is stored in Git.
- An internet-facing ALB terminates TLS and redirects HTTP to HTTPS.

## Prerequisites

- Terraform 1.16.4, AWS CLI v2, `kubectl`, and AWS credentials able to create IAM, VPC, EKS, ECR, Secrets Manager, and ELB resources.
- An S3 state bucket with versioning, encryption, public-access blocking, and deletion protection. Terraform uses native S3 lockfiles.
- A validated ACM certificate in the EKS region and a DNS hostname you control.
- The trusted public `/32` CIDR(s) used to administer EKS. The configuration rejects `0.0.0.0/0`.

## Provisioning

Terraform is intentionally split so Kubernetes providers are not initialized before EKS exists.

1. Copy `terraform/cluster/backend.hcl.example` and `terraform/cluster/terraform.tfvars.example` to ignored local files, replace every placeholder, then create the cluster:

   ```bash
   terraform -chdir=terraform/cluster init -backend-config=backend.hcl
   terraform -chdir=terraform/cluster plan -out=cluster.tfplan
   terraform -chdir=terraform/cluster apply cluster.tfplan
   ```

   If the AWS account already has the GitHub Actions OIDC provider, import it before applying:

   ```bash
   terraform -chdir=terraform/cluster import \
     aws_iam_openid_connect_provider.github_actions \
     arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com
   ```

2. Create the Flux deploy key and add its public half to **Settings → Deploy keys** in `phucle297/idunno-git-ops` with write access:

   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/idunno-flux -C flux-idunno -N ''
   cat ~/.ssh/idunno-flux.pub
   export TF_VAR_git_ssh_private_key="$(cat ~/.ssh/idunno-flux)"
   ```

3. Copy the platform examples to `backend.hcl` and `terraform.tfvars`, provide the state bucket, hostname, and ACM certificate ARN, then install the platform:

   ```bash
   aws eks update-kubeconfig --region ap-southeast-1 --name idunno-production
   terraform -chdir=terraform/platform init -backend-config=backend.hcl
   terraform -chdir=terraform/platform plan -out=platform.tfplan
   terraform -chdir=terraform/platform apply platform.tfplan
   ```

   The deploy private key is sensitive but is stored in Terraform state. Restrict state-bucket access accordingly.

4. Populate the secret value created by Terraform:

   ```bash
   aws secretsmanager put-secret-value \
     --region ap-southeast-1 \
     --secret-id /idunno/production/app \
     --secret-string '{"NEXT_PUBLIC_SUPABASE_URL":"https://PROJECT.supabase.co","NEXT_PUBLIC_SUPABASE_ANON_KEY":"REPLACE_ME"}'
   ```

5. In `phucle297/idunno`, create these GitHub repository **variables** (not secrets):

   | Variable | Value |
   | --- | --- |
   | `AWS_REGION` | `ap-southeast-1` (or the configured region) |
   | `AWS_DEPLOY_ROLE_ARN` | `terraform -chdir=terraform/cluster output -raw github_actions_role_arn` |
   | `ECR_REGISTRY` | Registry host from `ecr_repository_url`, without `/idunno` |

   Protect `main`, require the app CI and infrastructure validation checks, and permit the Flux deploy key to bypass the pull-request requirement so image automation can commit. Do not add long-lived AWS access keys.

6. Push both repositories. After Flux creates the ALB, point the hostname at the value from:

   ```bash
   kubectl -n idunno get ingress idunno
   ```

## App contract

The app repository must provide:

- npm with committed `package-lock.json`; `npm ci`, `npm run build`, and any defined `lint`, `typecheck`, and `test` scripts must pass;
- Next.js standalone output (`output: "standalone"`);
- a non-root-compatible server listening on `0.0.0.0:3000` with writable files limited to `/tmp`;
- unauthenticated `GET /api/health`, returning HTTP 200 quickly without depending on Supabase;
- runtime reads of `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_ANON_KEY` from the process environment. Values inlined into browser JavaScript at `next build` time will not see Kubernetes runtime injection, so expose them to client code through a runtime server boundary if needed.

The Supabase anon key is public by design but should still be governed by strict Supabase Row Level Security policies.

## Verification and operations

```bash
terraform fmt -check -recursive terraform
terraform -chdir=terraform/cluster validate
terraform -chdir=terraform/platform validate
ECR_REPOSITORY=example.invalid/idunno \
APP_HOSTNAME=english.example.com \
ACM_CERTIFICATE_ARN=arn:aws:acm:ap-southeast-1:123456789012:certificate/example \
./scripts/render-manifests.sh

flux check
flux get all -A
kubectl -n idunno rollout status deployment/idunno
curl --fail --silent --show-error "https://<hostname>/api/health"
```

ALB deletion protection is enabled. Disable it deliberately before destroying the platform. The production defaults also create one NAT gateway per AZ and two on-demand nodes; adjust only after reviewing availability and cost requirements.
