variable "aws_region" {
  type    = string
  default = "ap-southeast-1"
}

variable "cluster_name" {
  type    = string
  default = "idunno-production"
}

variable "cluster_state_bucket" {
  description = "S3 bucket containing the cluster Terraform state."
  type        = string
}

variable "cluster_state_key" {
  type    = string
  default = "idunno/production/cluster.tfstate"
}

variable "git_url" {
  description = "SSH clone URL for this GitOps repository."
  type        = string
  default     = "ssh://git@github.com/phucle297/idunno-git-ops.git"
}

variable "git_branch" {
  type    = string
  default = "main"
}

variable "git_ssh_private_key" {
  description = "Private half of a read/write GitHub deploy key used by Flux."
  type        = string
  sensitive   = true
}

variable "app_hostname" {
  description = "Public DNS hostname served by the ALB ingress."
  type        = string
}

variable "acm_certificate_arn" {
  description = "Validated ACM certificate ARN for app_hostname."
  type        = string
}
