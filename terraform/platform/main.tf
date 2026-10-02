data "terraform_remote_state" "cluster" {
  backend = "s3"
  config = {
    bucket = var.cluster_state_bucket
    key    = var.cluster_state_key
    region = var.aws_region
  }
}

locals {
  oidc_provider_arn = data.terraform_remote_state.cluster.outputs.cluster_oidc_provider_arn
}

module "load_balancer_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.8.2"

  name                                   = "${var.cluster_name}-aws-load-balancer-controller"
  attach_load_balancer_controller_policy = true
  oidc_providers = {
    cluster = {
      provider_arn               = local.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "aws_secretsmanager_secret" "app" {
  name                    = "/idunno/production/app"
  description             = "Runtime and build configuration for idunno"
  recovery_window_in_days = 30
}

module "external_secrets_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.8.2"

  name                                  = "${var.cluster_name}-external-secrets"
  attach_external_secrets_policy        = true
  external_secrets_secrets_manager_arns = [aws_secretsmanager_secret.app.arn]
  oidc_providers = {
    cluster = {
      provider_arn               = local.oidc_provider_arn
      namespace_service_accounts = ["external-secrets:external-secrets"]
    }
  }
}

module "flux_ecr_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "6.8.2"

  name = "${var.cluster_name}-flux-ecr"
  policies = {
    ecr_read_only = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  }
  oidc_providers = {
    cluster = {
      provider_arn               = local.oidc_provider_arn
      namespace_service_accounts = ["flux-system:image-reflector-controller"]
    }
  }
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "3.5.0"

  values = [yamlencode({
    clusterName = var.cluster_name
    region      = var.aws_region
    vpcId       = data.aws_eks_cluster.this.vpc_config[0].vpc_id
    serviceAccount = {
      name = "aws-load-balancer-controller"
      annotations = {
        "eks.amazonaws.com/role-arn" = module.load_balancer_controller_irsa.arn
      }
    }
    resources = {
      requests = { cpu = "100m", memory = "128Mi" }
      limits   = { memory = "256Mi" }
    }
  })]
}

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  namespace        = "external-secrets"
  create_namespace = true
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = "2.11.0"

  values = [yamlencode({
    serviceAccount = {
      name = "external-secrets"
      annotations = {
        "eks.amazonaws.com/role-arn" = module.external_secrets_irsa.arn
      }
    }
    extraObjects = [{
      apiVersion = "external-secrets.io/v1"
      kind       = "ClusterSecretStore"
      metadata   = { name = "aws-secrets-manager" }
      spec = {
        provider = {
          aws = {
            service = "SecretsManager"
            region  = var.aws_region
            auth = {
              jwt = {
                serviceAccountRef = {
                  name      = "external-secrets"
                  namespace = "external-secrets"
                }
              }
            }
          }
        }
      }
    }]
  })]
}

resource "helm_release" "flux" {
  name             = "flux2"
  namespace        = "flux-system"
  create_namespace = true
  repository       = "https://fluxcd-community.github.io/helm-charts"
  chart            = "flux2"
  version          = "2.19.1"

  values = [yamlencode({
    imageReflectionController = {
      serviceAccount = {
        annotations = {
          "eks.amazonaws.com/role-arn" = module.flux_ecr_irsa.arn
        }
      }
    }
    extraObjects = [
      {
        apiVersion = "v1"
        kind       = "Secret"
        metadata = {
          name      = "flux-system"
          namespace = "flux-system"
        }
        type = "Opaque"
        data = {
          identity      = base64encode(var.git_ssh_private_key)
          "known_hosts" = base64encode("github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl")
        }
      },
      {
        apiVersion = "v1"
        kind       = "ConfigMap"
        metadata = {
          name      = "cluster-config"
          namespace = "flux-system"
        }
        data = {
          AWS_REGION          = var.aws_region
          APP_HOSTNAME        = var.app_hostname
          ACM_CERTIFICATE_ARN = var.acm_certificate_arn
          ECR_REPOSITORY      = data.terraform_remote_state.cluster.outputs.ecr_repository_url
        }
      },
      {
        apiVersion = "source.toolkit.fluxcd.io/v1"
        kind       = "GitRepository"
        metadata = {
          name      = "flux-system"
          namespace = "flux-system"
        }
        spec = {
          interval  = "1m"
          ref       = { branch = var.git_branch }
          secretRef = { name = "flux-system" }
          url       = var.git_url
        }
      },
      {
        apiVersion = "kustomize.toolkit.fluxcd.io/v1"
        kind       = "Kustomization"
        metadata = {
          name      = "flux-system"
          namespace = "flux-system"
        }
        spec = {
          interval = "10m"
          path     = "./clusters/production"
          prune    = true
          wait     = true
          timeout  = "5m"
          sourceRef = {
            kind = "GitRepository"
            name = "flux-system"
          }
          postBuild = {
            substituteFrom = [{ kind = "ConfigMap", name = "cluster-config" }]
          }
        }
      }
    ]
  })]
  depends_on = [helm_release.external_secrets, helm_release.aws_load_balancer_controller]
}
