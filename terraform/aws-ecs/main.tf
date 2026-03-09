# Ferrite on AWS ECS Fargate
#
# Deploys Ferrite as an ECS Fargate service with:
# - Network Load Balancer for TCP traffic
# - EFS for persistent storage (AOF/checkpoints)
# - CloudWatch logging and Container Insights
# - Auto-scaling based on CPU/memory
# - Security groups with least-privilege access

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------

variable "name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "ferrite"
}

variable "vpc_id" {
  description = "VPC ID for deployment"
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs for ECS tasks (private subnets recommended)"
  type        = list(string)
}

variable "lb_subnet_ids" {
  description = "Subnet IDs for the NLB (public subnets for external access, or same as subnet_ids for internal)"
  type        = list(string)
  default     = []
}

variable "ferrite_version" {
  description = "Ferrite Docker image tag"
  type        = string
  default     = "0.3.0"
}

variable "ferrite_image" {
  description = "Ferrite Docker image repository"
  type        = string
  default     = "ghcr.io/ferritelabs/ferrite"
}

variable "cpu" {
  description = "CPU units for Fargate task (256, 512, 1024, 2048, 4096)"
  type        = number
  default     = 1024
}

variable "memory" {
  description = "Memory (MiB) for Fargate task"
  type        = number
  default     = 2048
}

variable "desired_count" {
  description = "Number of Ferrite task replicas"
  type        = number
  default     = 1
}

variable "max_memory" {
  description = "Ferrite maxmemory setting"
  type        = string
  default     = "1GB"
}

variable "enable_persistence" {
  description = "Enable EFS-backed AOF persistence"
  type        = bool
  default     = true
}

variable "enable_monitoring" {
  description = "Enable CloudWatch Container Insights"
  type        = bool
  default     = true
}

variable "internal_lb" {
  description = "Use internal NLB (no public access)"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# Locals
# ---------------------------------------------------------------------------

locals {
  lb_subnets = length(var.lb_subnet_ids) > 0 ? var.lb_subnet_ids : var.subnet_ids

  default_tags = merge(var.tags, {
    "app"        = "ferrite"
    "managed-by" = "terraform"
  })
}

# ---------------------------------------------------------------------------
# ECS Cluster
# ---------------------------------------------------------------------------

resource "aws_ecs_cluster" "ferrite" {
  name = var.name

  setting {
    name  = "containerInsights"
    value = var.enable_monitoring ? "enabled" : "disabled"
  }

  tags = local.default_tags
}

# ---------------------------------------------------------------------------
# Security Groups
# ---------------------------------------------------------------------------

resource "aws_security_group" "ferrite" {
  name_prefix = "${var.name}-"
  vpc_id      = var.vpc_id
  description = "Ferrite ECS tasks"

  ingress {
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    description = "Ferrite RESP protocol"
    cidr_blocks = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
  }

  ingress {
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    description = "Prometheus metrics"
    cidr_blocks = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }

  tags = local.default_tags

  lifecycle {
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# EFS (persistent storage)
# ---------------------------------------------------------------------------

resource "aws_efs_file_system" "ferrite" {
  count = var.enable_persistence ? 1 : 0

  creation_token = "${var.name}-data"
  encrypted      = true

  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"

  tags = merge(local.default_tags, {
    Name = "${var.name}-data"
  })
}

resource "aws_efs_mount_target" "ferrite" {
  count = var.enable_persistence ? length(var.subnet_ids) : 0

  file_system_id  = aws_efs_file_system.ferrite[0].id
  subnet_id       = var.subnet_ids[count.index]
  security_groups = [aws_security_group.ferrite.id]
}

# ---------------------------------------------------------------------------
# IAM
# ---------------------------------------------------------------------------

resource "aws_iam_role" "task_execution" {
  name_prefix = "${var.name}-exec-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = local.default_tags
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task" {
  name_prefix = "${var.name}-task-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })

  tags = local.default_tags
}

# ---------------------------------------------------------------------------
# CloudWatch Logs
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "ferrite" {
  name              = "/ecs/${var.name}"
  retention_in_days = 30
  tags              = local.default_tags
}

# ---------------------------------------------------------------------------
# Task Definition
# ---------------------------------------------------------------------------

resource "aws_ecs_task_definition" "ferrite" {
  family                   = var.name
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name      = "ferrite"
    image     = "${var.ferrite_image}:${var.ferrite_version}"
    essential = true

    portMappings = [
      { containerPort = 6379, protocol = "tcp" },
      { containerPort = 9090, protocol = "tcp" },
    ]

    environment = [
      { name = "RUST_LOG", value = "ferrite=info" },
      { name = "FERRITE_BIND", value = "0.0.0.0" },
      { name = "FERRITE_PORT", value = "6379" },
      { name = "FERRITE_MAX_MEMORY", value = var.max_memory },
      { name = "FERRITE_METRICS_ENABLED", value = "true" },
      { name = "FERRITE_METRICS_PORT", value = "9090" },
      { name = "FERRITE_AOF_ENABLED", value = tostring(var.enable_persistence) },
    ]

    mountPoints = var.enable_persistence ? [{
      sourceVolume  = "ferrite-data"
      containerPath = "/data"
      readOnly      = false
    }] : []

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ferrite.name
        "awslogs-region"        = data.aws_region.current.name
        "awslogs-stream-prefix" = "ferrite"
      }
    }

    healthCheck = {
      command     = ["CMD-SHELL", "ferrite-cli PING || exit 1"]
      interval    = 15
      timeout     = 5
      retries     = 3
      startPeriod = 10
    }
  }])

  dynamic "volume" {
    for_each = var.enable_persistence ? [1] : []
    content {
      name = "ferrite-data"
      efs_volume_configuration {
        file_system_id     = aws_efs_file_system.ferrite[0].id
        transit_encryption = "ENABLED"
      }
    }
  }

  tags = local.default_tags
}

# ---------------------------------------------------------------------------
# Network Load Balancer
# ---------------------------------------------------------------------------

resource "aws_lb" "ferrite" {
  name_prefix        = "frte-"
  internal           = var.internal_lb
  load_balancer_type = "network"
  subnets            = local.lb_subnets

  tags = local.default_tags
}

resource "aws_lb_target_group" "ferrite" {
  name_prefix = "frte-"
  port        = 6379
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled  = true
    port     = 6379
    protocol = "TCP"
  }

  tags = local.default_tags
}

resource "aws_lb_listener" "ferrite" {
  load_balancer_arn = aws_lb.ferrite.arn
  port              = 6379
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ferrite.arn
  }
}

# ---------------------------------------------------------------------------
# ECS Service
# ---------------------------------------------------------------------------

resource "aws_ecs_service" "ferrite" {
  name            = var.name
  cluster         = aws_ecs_cluster.ferrite.id
  task_definition = aws_ecs_task_definition.ferrite.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.ferrite.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.ferrite.arn
    container_name   = "ferrite"
    container_port   = 6379
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  tags = local.default_tags
}

# ---------------------------------------------------------------------------
# Auto Scaling
# ---------------------------------------------------------------------------

resource "aws_appautoscaling_target" "ferrite" {
  max_capacity       = var.desired_count * 3
  min_capacity       = var.desired_count
  resource_id        = "service/${aws_ecs_cluster.ferrite.name}/${aws_ecs_service.ferrite.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.name}-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ferrite.resource_id
  scalable_dimension = aws_appautoscaling_target.ferrite.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ferrite.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 70.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

# ---------------------------------------------------------------------------
# Data sources
# ---------------------------------------------------------------------------

data "aws_region" "current" {}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "endpoint" {
  description = "Ferrite NLB endpoint"
  value       = aws_lb.ferrite.dns_name
}

output "port" {
  description = "Ferrite port"
  value       = 6379
}

output "cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.ferrite.name
}

output "service_name" {
  description = "ECS service name"
  value       = aws_ecs_service.ferrite.name
}

output "log_group" {
  description = "CloudWatch log group"
  value       = aws_cloudwatch_log_group.ferrite.name
}

output "security_group_id" {
  description = "Security group ID (for allowing client access)"
  value       = aws_security_group.ferrite.id
}

output "metrics_endpoint" {
  description = "Prometheus metrics endpoint (via task IP:9090/metrics)"
  value       = "Use ECS service discovery or CloudMap for metrics scraping"
}
