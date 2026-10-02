variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "ap-southeast-1"
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
  default     = "idunno-production"
}

variable "kubernetes_version" {
  description = "EKS Kubernetes minor version."
  type        = string
  default     = "1.35"
}

variable "vpc_cidr" {
  description = "CIDR for the EKS VPC."
  type        = string
  default     = "10.42.0.0/16"
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "Trusted CIDRs allowed to reach the public EKS API endpoint. Never use 0.0.0.0/0."
  type        = list(string)

  validation {
    condition     = length(var.cluster_endpoint_public_access_cidrs) > 0 && !contains(var.cluster_endpoint_public_access_cidrs, "0.0.0.0/0")
    error_message = "Provide at least one trusted administration CIDR; 0.0.0.0/0 is forbidden."
  }
}

variable "admin_principal_arns" {
  description = "IAM role ARNs that receive EKS cluster-admin access."
  type        = set(string)
  default     = []
}

variable "node_instance_types" {
  description = "Allowed EC2 types for the managed node group."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "github_repository" {
  description = "GitHub owner/repository allowed to publish images."
  type        = string
  default     = "phucle297/idunno"
}
