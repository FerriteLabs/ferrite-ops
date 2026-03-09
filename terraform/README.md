# Ferrite Terraform Modules

Infrastructure-as-Code modules for deploying Ferrite on major cloud providers.

## Modules

| Module | Description | Cloud Provider |
|--------|-------------|---------------|
| `aws-ecs/` | Deploy Ferrite on AWS ECS Fargate with ALB, CloudWatch, and ElastiCache-compatible networking | AWS |
| `aws-eks/` | Deploy Ferrite on AWS EKS using the Helm chart with IRSA, EBS CSI, and Prometheus integration | AWS |

## Quick Start

### AWS ECS (Serverless containers)

```hcl
module "ferrite" {
  source = "github.com/ferritelabs/ferrite-ops//terraform/aws-ecs"

  name               = "ferrite-prod"
  vpc_id             = "vpc-abc123"
  subnet_ids         = ["subnet-1", "subnet-2"]
  ferrite_version    = "0.3.0"
  cpu                = 2048
  memory             = 4096
  desired_count      = 2
  enable_persistence = true
}
```

### AWS EKS (Kubernetes)

```hcl
module "ferrite" {
  source = "github.com/ferritelabs/ferrite-ops//terraform/aws-eks"

  cluster_name    = "my-cluster"
  namespace       = "ferrite"
  ferrite_version = "0.3.0"
  replica_count   = 3
  storage_size    = "50Gi"
  enable_ha       = true
  enable_monitoring = true
}
```

## Prerequisites

- Terraform >= 1.5
- AWS CLI configured with appropriate credentials
- For EKS: `kubectl` and `helm` installed

## Variables

See individual module READMEs for complete variable documentation.

## Outputs

All modules export:
- `endpoint` — Ferrite connection endpoint
- `port` — Ferrite port (default: 6379)
- `metrics_endpoint` — Prometheus metrics URL

## Related

- [Helm Chart](../charts/ferrite/) — Kubernetes-native deployment
- [Docker Compose](../docker-compose.yml) — Local development
- [GitOps](../gitops/) — ArgoCD, Flux, Kustomize
