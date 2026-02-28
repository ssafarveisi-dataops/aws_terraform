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
