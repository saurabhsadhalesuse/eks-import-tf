##########
provider "aws" {
  region = var.region
}

provider "rancher2" {
  alias      = "admin"
  api_url    = "https://${local.ops-rancher-hostname}"
  access_key = data.terraform_remote_state.ops-rancher.outputs.access-key
  secret_key = data.terraform_remote_state.ops-rancher.outputs.secret-key
  timeout    = "600s"
}

#
# Set local variables
#
locals {
  rancher-domains = {
    "prod" = "rancher.cloud"
    "stg"  = "saas-dev.rancher.space"
  }
  layer                = lookup(var.tags, "layer", null)
  tenant-subdomain     = var.subdomain == null ? local.layer : var.subdomain
  tenant-hostname      = var.domain == null ? "${local.tenant-subdomain}.${local.rancher-domains[var.name]}" : "${local.tenant-subdomain}.${var.domain}"
  ops-rancher-hostname = "ops-${var.ops-region}.${local.rancher-domains[var.name]}"
}

#
# Retrieve data
#
data "aws_route53_zone" "public-hosted-zone" {
  count = var.domain == null ? 1 : 0
  name  = local.rancher-domains[var.name]
}

#
# Rancher Logging
#
module "rancher-logging" {
  name           = var.name
  log-group-name = "/${var.name}/${local.layer}"
  stream-name    = local.layer
  layer          = local.layer
  region         = var.region
  source         = "../../../modules/rancher-logging"
  retention_days = var.cloudwatch_log_retention_days
}

#
# Tenant VPC
#
module "vpc-tenant" {
  name        = var.name
  source      = "../../../modules/vpc-tenant"
  layer       = local.layer
  azs         = var.azs
  cidr        = var.cidr
  public-cidr = var.public-cidr
  tenant-cidr = var.tenant-cidr
  aurora-cidr = var.aurora-cidr
  natgw-count = var.natgw-count
  tgw-id      = var.tgw-id
  tgw-cidr    = var.tgw-cidr
  tags        = merge(var.tags)
}

#
# Tenant | Security Group resources
#
module "sg-tenant" {
  name   = "${var.name}-${local.layer}"
  source = "../../../modules/sg"

  vpc-id      = module.vpc-tenant.vpc-id
  description = "Allow bastion SSH, HTTP, and inter-node connectivity for the ${local.layer} tenant cluster"

  ingress_rules = [
    {
      description = "Inbound HTTP from the ALB"
      from-port   = 80
      to-port     = 80
      protocol    = "tcp"
      group       = module.sg-alb.sg-id
    },
    {
      description = "Inbound kube-apiserver from cluster nodes"
      from-port   = 6443
      to-port     = 6443
      protocol    = "tcp"
      self        = true
    },
    {
      description = "Inbound Canal/Flannel VXLAN from cluster nodes"
      from-port   = 8472
      to-port     = 8472
      protocol    = "udp"
      self        = true
    },
    {
      description = "Inbound Kubelet API from cluster nodes"
      from-port   = 10250
      to-port     = 10250
      protocol    = "tcp"
      self        = true
    },
    {
      description = "Prometheus metrics"
      from-port   = 9796
      to-port     = 9796
      protocol    = "tcp"
      self        = true
    },
    {
      description = "Inbound ingress-nginx metrics from cluster nodes"
      from-port   = 10254
      to-port     = 10254
      protocol    = "tcp"
      self        = true
    },
    {
      description = "Inbound to fluentd from cluster nodes"
      from-port   = 24240
      to-port     = 24240
      protocol    = "tcp"
      self        = true
    },
    {
      description = "Inbound to fluentd from cluster nodes"
      from-port   = 24240
      to-port     = 24240
      protocol    = "udp"
      self        = true
    },
    {
      description = "Inbound to gitjoblb service from ALB"
      from-port   = 1080
      to-port     = 1080
      protocol    = "tcp"
      group       = module.sg-alb.sg-id
    },
    {
      description = "Inbound HTTPS from the ALB"
      from-port   = 443
      to-port     = 443
      protocol    = "tcp"
      group       = module.sg-alb.sg-id
    }
  ]

  egress_rules = [
    {
      description = "Outbound to everywhere"
      from-port   = 0
      to-port     = 0
      protocol    = -1
      cidr        = "0.0.0.0/0"
    }
  ]

  tags = merge(
    {
      "Name" = "${var.name}-${local.layer}-tenant"
    },
    var.tags,
  )
}

# Import and remove rules from the default security group
resource "aws_default_security_group" "default" {
  vpc_id = module.vpc-tenant.vpc-id
}

#
# Aurora | Security Group resources
#
module "sg-aurora" {
  name   = "${var.name}-${local.layer}"
  source = "../../../modules/sg"

  vpc-id      = module.vpc-tenant.vpc-id
  description = "Allow MySQL to Aurora database for ${var.name}-${local.layer}"

  ingress_rules = [
    {
      description = "Inbound MySQL from tenant group"
      from-port   = 3306
      to-port     = 3306
      protocol    = "tcp"
      group       = module.sg-tenant.sg-id
    }
  ]

  egress_rules = [
    {
      description = "Outbound to everywhere"
      from-port   = 0
      to-port     = 0
      protocol    = -1
      cidr        = "0.0.0.0/0"
    }
  ]

  tags = merge(
    {
      "Name" = "${var.name}-${local.layer}-aurora"
    },
    var.tags,
  )
}

#
# ALB | Security Group resources
#
module "sg-alb" {
  name   = "${var.name}-${local.layer}"
  source = "../../../modules/sg"

  vpc-id      = module.vpc-tenant.vpc-id
  description = "Allow HTTP/HTTPS to ALB for ${var.name}-${local.layer}"
  custom-cidr = var.ingress-cidr == "0.0.0.0/0" ? false : true

  ingress_rules = concat(
    [
      {
        description = "Inbound HTTP from everywhere"
        from-port   = 80
        to-port     = 80
        protocol    = "tcp"
        cidr        = "0.0.0.0/0"
      }
    ],
    [for cidr in var.ingress-cidr : {
      description = cidr == "0.0.0.0/0" ? "Inbound HTTPS from everywhere" : "Inbound HTTPS"
      from-port   = 443
      to-port     = 443
      protocol    = "tcp"
      cidr        = cidr
    }]
  )

  egress_rules = [
    {
      description = "Outbound to everywhere"
      from-port   = 0
      to-port     = 0
      protocol    = -1
      cidr        = "0.0.0.0/0"
    }
  ]

  tags = merge(
    {
      "Name" = "${var.name}-${local.layer}-alb"
    },
    var.tags,
  )
}

module "sg-alb-internal" {
  count  = var.internal-alb == true ? 1 : 0
  name   = "${var.name}-${local.layer}"
  source = "../../../modules/sg"

  vpc-id      = module.vpc-tenant.vpc-id
  description = "Allow HTTP/HTTPS to internal ALB for ${var.name}-${local.layer}"

  ingress_rules = [
    {
      description = "Inbound HTTP from everywhere"
      from-port   = 80
      to-port     = 80
      protocol    = "tcp"
      cidr        = "0.0.0.0/0"
    },
    {
      description = "Inbound HTTPS from everywhere"
      from-port   = 443
      to-port     = 443
      protocol    = "tcp"
      cidr        = "0.0.0.0/0"
    }
  ]

  egress_rules = [
    {
      description = "Outbound to everywhere"
      from-port   = 0
      to-port     = 0
      protocol    = -1
      cidr        = "0.0.0.0/0"
    }
  ]

  tags = merge(
    {
      "Name" = "${var.name}-${local.layer}-alb-internal"
    },
    var.tags,
  )
}

resource "aws_security_group_rule" "ingress-rule-tenant" {
  count                    = var.internal-alb == true ? 1 : 0
  type                     = "ingress"
  security_group_id        = module.sg-tenant.sg-id
  description              = "Inbound HTTP from the internal ALB"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  source_security_group_id = module.sg-alb-internal[0].sg-id
}

resource "aws_security_group_rule" "ingress-rule-tenant-1080" {
  count                    = var.internal-alb == true ? 1 : 0
  type                     = "ingress"
  security_group_id        = module.sg-tenant.sg-id
  description              = "Inbound HTTP from the internal ALB"
  from_port                = 1080
  to_port                  = 1080
  protocol                 = "tcp"
  source_security_group_id = module.sg-alb-internal[0].sg-id
}

#
# Instance profile
#
module "instance-profile" {
  name              = var.name
  source            = "../../../modules/instance-profile"
  layer             = local.layer
  ssm-policy        = data.terraform_remote_state.management.outputs.ssm-ec2-policy
  role-policy       = <<-EOF
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Sid": "Allow${replace(local.layer, "-", "")}GetParameter",
        "Effect": "Allow",
        "Action": [
            "ssm:GetParameter"
        ],
        "Resource": [
            "arn:aws:ssm:${var.region}:*:parameter/${var.name}/${local.layer}/database/*",
            "arn:aws:ssm:${var.region}:*:parameter/${var.name}/${local.layer}/k3s/token"
        ]
      },
      {
        "Sid": "Allow${replace(local.layer, "-", "")}ListBucket",
        "Effect": "Allow",
        "Action": [
            "s3:ListBucket",
            "s3:GetEncryptionConfiguration"
        ],
        "Resource": [
          "arn:aws:s3:::${data.terraform_remote_state.management.outputs.node-logs-bucket}",
          "arn:aws:s3:::${data.terraform_remote_state.management.outputs.rancher-backup-bucket}",
          "arn:aws:s3:::${data.terraform_remote_state.management.outputs.systems-summary-bucket}"
        ]
      },
      {
        "Sid": "Allow${replace(local.layer, "-", "")}SyncLogs",
        "Effect": "Allow",
        "Action": [
            "s3:ListObjectsV2",
            "s3:PutObject"
        ],
        "Resource": [
          "arn:aws:s3:::${data.terraform_remote_state.management.outputs.node-logs-bucket}/${local.layer}",
          "arn:aws:s3:::${data.terraform_remote_state.management.outputs.node-logs-bucket}/${local.layer}/*",
          "arn:aws:s3:::${data.terraform_remote_state.management.outputs.systems-summary-bucket}/${var.region}/${local.layer}/*"
        ]
      },
      {
        "Effect": "Allow",
        "Action": [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:PutObjectAcl"
        ],
        "Resource": [
          "arn:aws:s3:::${data.terraform_remote_state.management.outputs.rancher-backup-bucket}/${local.layer}/*",
          "arn:aws:s3:::${data.terraform_remote_state.management.outputs.systems-summary-bucket}/${var.region}/${local.layer}/*"
        ]
      },
      {
        "Effect": "Allow",
        "Action": [
          "logs:DescribeLogGroups",
          "logs:CreateLogGroup"
        ],
        "Resource": "*"
      },
      {
        "Effect": "Allow",
        "Action": [
          "logs:CreateLogStream",
          "logs:DescribeLogStreams",
          "logs:PutLogEvents"
        ],
        "Resource": [
          "arn:aws:logs:*:*:log-group:${module.rancher-logging.name}",
          "arn:aws:logs:*:*:log-group:${module.rancher-logging.name}:log-stream:*"
        ]
      },
      {
        "Effect": "Allow",
        "Action": [
          "ec2:CreateTags"
        ],
        "Resource": [
          "arn:aws:ec2:${var.region}:*:volume/*",
          "arn:aws:ec2:${var.region}:*:snapshot/*"
        ],
        "Condition": {
          "StringEquals": {
            "ec2:CreateAction": [
              "CreateSnapshot",
              "CreateVolume"
            ]
          }
        }
      },
      {
        "Effect": "Allow",
        "Action": [
          "ec2:CreateSnapshot",
          "ec2:CreateVolume"
        ],
        "Resource": "*",
        "Condition": {
          "StringEquals": {
            "aws:RequestTag/layer": "${local.layer}"
          }
        }
      },
      {
        "Effect": "Allow",
        "Action": [
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeInstances",
          "ec2:DescribeSnapshots",
          "ec2:DescribeTags",
          "ec2:DescribeVolumes",
          "ec2:DescribeVolumesModifications"
        ],
        "Resource": "*"
      },
      {
        "Effect": "Allow",
        "Action": [
          "ec2:AttachVolume",
          "ec2:DeleteSnapshot",
          "ec2:DeleteVolume",
          "ec2:DetachVolume",
          "ec2:ModifyVolume"
        ],
        "Resource": "*",
        "Condition": {
          "StringEquals": {
            "aws:ResourceTag/layer": "${local.layer}"
          }
        }
      }
    ]
  }
  EOF
  role-policy-extra = var.customer-log-bucket == "disabled" ? "disabled" : <<-EOF
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Sid": "Allow${replace(local.layer, "-", "")}CustListBucket",
        "Effect": "Allow",
        "Action": [
            "s3:ListBucket",
            "s3:GetEncryptionConfiguration"
        ],
        "Resource": [ "arn:aws:s3:::${var.customer-log-bucket}"
        ]
      },
      {
        "Sid": "Allow${replace(local.layer, "-", "")}CustSyncLogs",
        "Effect": "Allow",
        "Action": [
            "s3:ListObjectsV2",
            "s3:PutObjectAcl",
            "s3:PutObject"
        ],
        "Resource": [
          "arn:aws:s3:::${var.customer-log-bucket}/${local.layer}",
          "arn:aws:s3:::${var.customer-log-bucket}/${local.layer}/*"
        ]
      }
    ]
  }
  EOF
}

#
# ACM certificate
#
module "cert" {
  region             = var.region
  domain             = local.tenant-hostname
  disable-validation = var.domain
  zone               = var.domain == null ? data.aws_route53_zone.public-hosted-zone[0].id : null
  source             = "../../../modules/acm-tenant"
}

#
# Route53 Subdomain
#
module "public-subdomain" {
  source    = "../../../modules/route53"
  zone      = var.domain == null ? data.aws_route53_zone.public-hosted-zone[0].zone_id : null
  subdomain = local.tenant-subdomain
  alias     = module.alb.lb.dns_name
  alias-id  = module.alb.lb.zone_id
}

#
# Public ALB
#
module "alb" {
  name         = var.name
  lb-name      = "tenant"
  region       = var.region
  source       = "../../../modules/lb"
  layer        = local.layer
  type         = "application"
  idle-timeout = 1800
  internal     = false
  subnets      = [module.vpc-tenant.public-subnets[0], module.vpc-tenant.public-subnets[1]]
  sg-list      = [module.sg-alb.sg-id]
  tags         = var.tags
}

module "target-group" {
  name          = var.name
  source        = "../../../modules/lb-tg"
  region        = var.region
  layer         = local.layer
  target-groups = var.public-target-groups
  load-balancer = module.alb.lb.arn_suffix
  tags          = var.tags
  vpc-id        = module.vpc-tenant.vpc-id
}

module "listener" {
  alb    = module.alb.lb.arn
  cert   = module.cert.cert
  source = "../../../modules/lb-listener"
}

module "listener-rule" {
  source   = "../../../modules/lb-rule"
  for_each = { for idx, tg in var.public-target-groups : tg.name => module.target-group.tg[idx] }
  listener = module.listener.listener
  tg       = each.value
  tg_name  = each.key
  domains  = [module.public-subdomain.fqdn]
}

#
# Internal ALB
#
module "alb-internal" {
  count        = var.internal-alb == true ? 1 : 0
  name         = var.name
  lb-name      = "tenant-int"
  region       = var.region
  source       = "../../../modules/lb"
  layer        = local.layer
  type         = "application"
  idle-timeout = 1800
  internal     = true
  subnets      = [module.vpc-tenant.tenant-subnets[0], module.vpc-tenant.tenant-subnets[1]]
  sg-list      = [module.sg-alb-internal[0].sg-id]
  tags         = var.tags
}

module "target-group-internal" {
  count         = var.internal-alb == true ? 1 : 0
  name          = var.name
  source        = "../../../modules/lb-tg"
  region        = var.region
  layer         = local.layer
  target-groups = var.public-target-groups
  load-balancer = module.alb-internal[0].lb.arn_suffix
  internal      = var.internal-alb
  tags          = var.tags
  vpc-id        = module.vpc-tenant.vpc-id
}

module "listener-internal" {
  count  = var.internal-alb == true ? 1 : 0
  alb    = module.alb-internal[0].lb.arn
  cert   = module.cert.cert
  source = "../../../modules/lb-listener"
}

module "listener-rule-internal" {
  count    = var.internal-alb == true ? 1 : 0
  source   = "../../../modules/lb-rule"
  listener = module.listener-internal[0].listener
  tg       = module.target-group-internal[0].tg[0]
  tg_name  = var.public-target-groups[0].name
  domains  = [local.tenant-hostname]
}

#
# Passwords
#
module "database-password" {
  source = "../../../modules/password"
}

module "k3s-password" {
  source = "../../../modules/password"
}

module "rancher-password" {
  source = "../../../modules/password"
}

module "k3s-token" {
  count       = var.generate-k3s-token ? 1 : 0
  source      = "../../../modules/password"
  use-special = false
}

resource "aws_ssm_parameter" "database-password" {
  name        = "/${var.name}/${local.layer}/database/password"
  description = "${local.layer} master database password"
  type        = "SecureString"
  value       = module.database-password.password
  tags        = merge(var.tags)
}

resource "aws_ssm_parameter" "k3s-password" {
  name        = "/${var.name}/${local.layer}/database/k3s-password"
  description = "${local.layer} rancher user database password"
  type        = "SecureString"
  value       = module.k3s-password.password
  tags        = merge(var.tags)
}

resource "aws_ssm_parameter" "rancher-password" {
  name        = "/${var.name}/${local.layer}/rancher/password"
  description = "${local.layer} rancher admin password"
  type        = "SecureString"
  value       = module.rancher-password.password
  tags        = merge(var.tags)
}

resource "aws_ssm_parameter" "k3s-token" {
  count       = var.generate-k3s-token ? 1 : 0
  name        = "/${var.name}/${local.layer}/k3s/token"
  description = "${local.layer} k3s server token"
  type        = "SecureString"
  value       = module.k3s-token[0].password
  tags        = merge(var.tags)
}

#
# Aurora database
#
resource "aws_db_parameter_group" "db-param-group" {
  name_prefix = "${var.name}-${local.layer}-ops-"
  family      = var.db-family

  parameter {
    name  = "max_connections"
    value = var.db-max-connections
  }

  parameter {
    name  = "max_user_connections"
    value = var.db-max-connections
  }

  parameter {
    name  = "slow_query_log"
    value = var.slow-query-log
  }

  parameter {
    name  = "long_query_time"
    value = var.long-query-time
  }

  parameter {
    name  = "general_log"
    value = var.general-log
  }
}

module "aurora" {
  name                      = var.name
  source                    = "../../../modules/aurora"
  region                    = var.region
  id                        = local.layer
  layer                     = local.layer
  subnets                   = module.vpc-tenant.aurora-subnets
  password                  = module.database-password.password
  db-engine                 = var.db-engine
  db-engine-version         = var.db-engine-version
  sg-list                   = module.sg-aurora.sg-id
  db-instance               = var.db-instance
  db-instance-count         = var.db-instance-count
  parameter-group           = aws_db_parameter_group.db-param-group.id
  backtrack-window          = var.backtrack-window
  maintenance-window        = var.maintenance-window
  backup-window             = var.backup-window
  tags                      = var.tags
  logs-exports              = var.logs-exports
  serverlessv2_max_capacity = var.serverlessv2_max_capacity
  serverlessv2_min_capacity = var.serverlessv2_min_capacity
}

#
# Auto scaling group
#
module "asg" {
  name             = var.name
  source           = "../../../modules/asg"
  region           = var.region
  layer            = local.layer
  instance-type    = var.instance-type
  sg-list          = module.sg-tenant.sg-id
  ami              = var.ami
  ebs-volume       = var.ebs-volume
  instance-profile = module.instance-profile.instance-profile
  user-data        = base64encode(templatefile("user-data.yaml", { rancher-hostname = module.public-subdomain.fqdn, rancher-backup-version = var.rancher-backup-version, rancher-version = var.rancher-version, rancher-chart-name = var.rancher-chart-name, rancher-replicas = var.asg-capacity.desired, endpoint = module.aurora.database-endpoint, layer = local.layer, environment = var.name, cluster_registration = rancher2_cluster.tenant-cluster.cluster_registration_token[0].command, cluster_cidr = var.cluster-cidr, service_cidr = var.service-cidr, cluster_dns = var.cluster-dns, node_logs_bucket = data.terraform_remote_state.management.outputs.node-logs-bucket, customer_log_bucket = var.customer-log-bucket, region = var.region, cluster_id = rancher2_cluster.tenant-cluster.id, system_project = split(":", rancher2_cluster.tenant-cluster.system_project_id)[1], fluentd_memory = var.fluentd-memory, rancher-registry = var.rancher-registry }))
  asg-capacity     = var.asg-capacity
  subnets          = [module.vpc-tenant.tenant-subnets[0], module.vpc-tenant.tenant-subnets[1]]
  spot-instances   = var.spot-instances
  dependency       = [module.aurora, module.alb, module.sg-alb, module.sg-aurora, module.vpc-tenant]
  tags             = var.tags
}

resource "aws_autoscaling_attachment" "alb-attachment" {
  depends_on             = [rancher2_cluster_sync.wait-for-cluster]
  for_each               = { for idx, tg in var.public-target-groups : tg.name => module.target-group.tg[idx] }
  autoscaling_group_name = module.asg.asg-id
  lb_target_group_arn    = each.value
}

resource "aws_autoscaling_attachment" "alb-attachment-internal" {
  depends_on             = [rancher2_cluster_sync.wait-for-cluster]
  count                  = var.internal-alb == true ? 1 : 0
  autoscaling_group_name = module.asg.asg-id
  lb_target_group_arn    = module.target-group-internal[0].tg[0]
}

#
# Tenant cluster
#
resource "rancher2_cluster" "tenant-cluster" {
  depends_on  = [module.sg-tenant]
  name        = local.layer
  provider    = rancher2.admin
  description = "Imported cluster for ${local.layer}"
  annotations = { "node-license" = var.node-license }
  labels      = { "customer-type" = var.customer-type }

  dynamic "k3s_config" {
    for_each = var.k3s-version != null ? [1] : []
    content {
      version = var.k3s-version
      upgrade_strategy {
        drain_server_nodes = false
      }
    }
  }

  lifecycle {
    ignore_changes = [
      labels,
      annotations,
    ]
  }
}

#
# Tenant rancher
#
resource "rancher2_cluster_sync" "wait-for-cluster" {
  depends_on = [module.asg]
  cluster_id = rancher2_cluster.tenant-cluster.id
  provider   = rancher2.admin
}

module "rancher-tenant" {
  name                    = var.name
  source                  = "../../../modules/rancher-tenant"
  region                  = var.region
  cluster-name            = rancher2_cluster.tenant-cluster.name
  cluster-id              = rancher2_cluster_sync.wait-for-cluster.id
  namespace-id            = "cattle-system"
  project-id              = rancher2_cluster_sync.wait-for-cluster.system_project_id
  ops-rancher-hostname    = "https://${local.ops-rancher-hostname}"
  access-key              = data.terraform_remote_state.ops-rancher.outputs.access-key
  secret-key              = data.terraform_remote_state.ops-rancher.outputs.secret-key
  rancher-version         = var.rancher-version
  rancher-replicas        = var.asg-capacity.desired
  password                = module.rancher-password.password
  tenant-rancher-hostname = local.tenant-hostname
  dependency              = [module.listener-rule, aws_autoscaling_attachment.alb-attachment]
  disable-bootstrap       = var.disable-bootstrap
}

#
# Tenant monitoring
#
resource "rancher2_cluster_sync" "wait-for-rancher" {
  depends_on    = [module.rancher-tenant]
  cluster_id    = rancher2_cluster.tenant-cluster.id
  provider      = rancher2.admin
  wait_catalogs = substr(var.rancher-version, 0, 3) == "2.6"
}


data "aws_ssm_parameter" "pagerduty-service-key" {
  name = "/${var.name}/${var.region}/pagerduty-service-key"
}

#
# Pingdom
#
module "pingdom" {
  name           = var.name
  layer          = local.layer
  source         = "../../../modules/pingdom"
  url            = local.tenant-hostname
  enable-pingdom = var.enable-pingdom
  dependency     = module.rancher-tenant
}
