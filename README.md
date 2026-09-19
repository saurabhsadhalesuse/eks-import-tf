# Terraform EKS + Rancher Integration

This Terraform repository automates the provisioning of an **Amazon EKS Cluster** (`v1.31`) and registers it automatically into a **Rancher v2.x** management server using the Rancher import manifest.

---

## Architecture Overview

1. **AWS EKS Module (`v20.0`)**: Deploys an EKS cluster with managed node groups into your existing VPC and Subnets.
2. **Rancher Provider (`v4.0`)**: Registers the newly created EKS cluster entry in Rancher.
3. **Local-Exec Provisioner**: Fetches the generated registration manifest from Rancher and applies it directly to the cluster via `kubectl`.

---

## Prerequisites

Before running this Terraform module, ensure you have installed and configured:

- [Terraform](https://developer.hashicorp.com/terraform/downloads) `>= 1.3.0`
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) (configured with appropriate credentials)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- An existing **VPC** with at least **2 subnets in different Availability Zones**.
- An operational **Rancher v2.x Server** and a valid **API Bearer Token**.

---

## Quickstart Guide

### 1. Clone the Repository
```bash
git clone https://github.com/saurabhsadhalesuse/eks-import-tf.git
cd eks-import-tf
```

### 2. Configure AWS credentials
```bash
aws configure
```
### 3. Configure Variables
```bash
cp terraform.tfvars.example terraform.tfvars
```
Edit `terraform.tfvars` with your specific configuration values.

### 4. Initialize & Deploy
```bash
# Initialize providers and modules
terraform init

# Plan the deployment
terraform plan

# Apply the infrastructure
terraform apply
```
