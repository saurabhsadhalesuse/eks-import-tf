variable "aws_region" {
  type    = string
  default = "us-west-2"
}

variable "vpc_id" {
  type        = string
  description = "Existing VPC ID for EKS deployment"
}

variable "subnet_ids" {
  type        = list(string)
  description = "Subnet IDs for EKS deployment (at least 2 in different AZs)"
}

variable "rancher_url" {
  type        = string
  description = "Rancher URL (e.g., https://rancher.yourdomain.com)"
}

variable "rancher_token" {
  type        = string
  sensitive   = true
  description = "Rancher API Bearer Token"
}

variable "cluster_name" {
  type    = string
  default = "my-eks-cluster"
}
