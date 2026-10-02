data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_caller_identity" "current" {}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 3)
  tags = {
    Application = "idunno"
    Environment = "production"
    ManagedBy   = "terraform"
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name = var.cluster_name
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = [for index, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, index)]
  public_subnets  = [for index, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, index + 48)]

  enable_nat_gateway     = true
  one_nat_gateway_per_az = true
  enable_dns_hostnames   = true
  enable_dns_support     = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.26.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  endpoint_private_access      = true
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs
  authentication_mode          = "API"
  enable_irsa                  = true

  enable_cluster_creator_admin_permissions = true
  access_entries = {
    for arn in var.admin_principal_arns : replace(replace(arn, ":", "-"), "/", "-") => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

  enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  addons = {
    coredns    = { most_recent = true }
    kube-proxy = { most_recent = true }
    vpc-cni = {
      most_recent          = true
      before_compute       = true
      configuration_values = jsonencode({ enableNetworkPolicy = "true" })
    }
    eks-pod-identity-agent = { most_recent = true, before_compute = true }
  }

  eks_managed_node_groups = {
    application = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.node_instance_types
      capacity_type  = "ON_DEMAND"

      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }

      min_size     = 2
      max_size     = 4
      desired_size = 2

      update_config = {
        max_unavailable_percentage = 33
      }
    }
  }
}

resource "aws_ecr_repository" "app" {
  name                 = "idunno"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Retain the latest 50 release images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 50
      }
      action = { type = "expire" }
    }]
  })
}

data "aws_iam_policy_document" "github_actions_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repository}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "idunno-github-actions-ecr"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume.json
}

data "aws_iam_policy_document" "github_actions_ecr" {
  statement {
    actions = [
      "ecr:GetAuthorizationToken",
    ]
    resources = ["*"]
  }

  statement {
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [aws_ecr_repository.app.arn]
  }
}

resource "aws_iam_role_policy" "github_actions_ecr" {
  name   = "publish-idunno-image"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions_ecr.json
}
