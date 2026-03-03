resource "aws_security_group" "ecs_tasks" {
  name        = "ecs-traffic"
  description = "Allow inbound traffic to ECS containers from ALB"
  vpc_id      = local.vpc_id

  tags = {
    Name = "Poc deployment ECS container instance SG"
  }
}

resource "aws_security_group_rule" "ecs_ingress" {
  type              = "ingress"
  security_group_id = aws_security_group.ecs_tasks.id

  from_port   = local.app_port
  to_port     = local.app_port
  protocol    = "tcp"
  cidr_blocks = [local.vpc_cidr]

  description = "HTTP from ALB"
}

resource "aws_security_group_rule" "ecs_egress" {
  type              = "egress"
  security_group_id = aws_security_group.ecs_tasks.id

  from_port   = 0
  to_port     = 0
  protocol    = "-1"
  cidr_blocks = ["0.0.0.0/0"]
}

resource "aws_ecs_cluster" "ecs_cluster" {
  name = "poc-deployment-cluster"
}

resource "aws_ecs_cluster_capacity_providers" "ecs_providers" {
  cluster_name       = aws_ecs_cluster.ecs_cluster.name
  capacity_providers = ["FARGATE"]
  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    base              = 1
    weight            = 100
  }
}

resource "aws_ssm_parameter" "openai_key" {
  name        = "/science-dev/poc-deployment/run-rime/openapi_key"
  type        = "SecureString"
  description = "Dummy key for OpenAI"
  value       = var.openapi_key
  tier        = "Standard"
}

resource "aws_ecr_repository" "poc-ecr-repository" {
  name                 = "poc-deployment"
  image_tag_mutability = "MUTABLE"
  force_delete         = true
}

resource "aws_s3_bucket" "poc_bucket" {
  bucket = local.s3_bucket_name
}

resource "aws_s3_bucket_public_access_block" "poc_bucket" {
  bucket = aws_s3_bucket.poc_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "poc_bucket" {
  bucket = aws_s3_bucket.poc_bucket.id

  versioning_configuration {
    status = "Disabled"
  }
}
