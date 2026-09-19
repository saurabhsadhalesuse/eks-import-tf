# ------------------------------------------------------------------------------
# 1. PROVIDER CONFIGURATIONS
# ------------------------------------------------------------------------------

provider "aws" {
  region = var.aws_region
}

provider "rancher2" {
  api_url   = var.rancher_url
  token_key = var.rancher_token
}

# ------------------------------------------------------------------------------
# 2. AWS EKS CLUSTER PROVISIONING
# ------------------------------------------------------------------------------

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = "1.31"

  cluster_endpoint_public_access = true

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

  eks_managed_node_groups = {
    default = {
      min_size     = 1
      max_size     = 3
      desired_size = 2
      instance_types = ["t3.medium"]
    }
  }
}

# ------------------------------------------------------------------------------
# 3. RANCHER CLUSTER IMPORT & AGENT DEPLOYMENT
# ------------------------------------------------------------------------------

# Register imported cluster entry in Rancher
resource "rancher2_cluster" "imported" {
  name                 = var.cluster_name
  description          = "EKS Cluster managed by Rancher v2.14"
  fleet_workspace_name = "fleet-default"
}

# Apply the Rancher agent manifest directly using local execution
resource "null_resource" "apply_rancher_agent" {
  triggers = {
    manifest_url = rancher2_cluster.imported.cluster_registration_token[0].manifest_url
    cluster_id   = module.eks.cluster_id
  }

  provisioner "local-exec" {
    command = <<EOT
      aws eks update-kubeconfig --region ${var.aws_region} --name ${var.cluster_name}
      curl -sSL -k ${rancher2_cluster.imported.cluster_registration_token[0].manifest_url} | kubectl apply -f -
    EOT
  }

  depends_on = [
    module.eks,
    rancher2_cluster.imported
  ]
}
