output "cluster_name" {
  description = "Name of the provisioned EKS cluster"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Endpoint for the EKS Kubernetes API"
  value       = module.eks.cluster_endpoint
}

output "rancher_cluster_id" {
  description = "ID of the imported cluster in Rancher"
  value       = rancher2_cluster.imported.id
}
