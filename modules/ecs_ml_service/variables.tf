variable "resource_prefix" {
  description = "Prefix for all resource names"
  type        = string
}

variable "vpc_id" {
  description = "VPC id"
  type        = string
}

variable "alb_security_group_id" {
  description = "ID for the ALB security group"
  type        = string
}

variable "lb_listener_arn" {
  description = "ARN for the ALB listener"
  type        = string
}

variable "listener_rule_priority" {
  description = "Priority for the ALB listener rule"
  type        = number
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "app_port" {
  description = "FastAPI server port"
  type        = number
}

variable "triton_image" {
  description = "Triton image uri"
  type        = string
  default     = "nvcr.io/nvidia/tritonserver:25.10-py3"
}

variable "fastapi_image" {
  description = "FastAPI image uri"
  type        = string
  default     = "docker.io/ciaa/triton-api-gateway:latest"
}

variable "ecs_cluster_id" {
  description = "ID for the ECS cluster"
  type        = string
}

variable "public_subnet_list" {
  description = "Ordered list of public subnet IDs to use for the service"
  type        = list(string)
}

variable "s3_bucket" {
  description = "S3 bucket where the artifacts are stored"
  type        = string
}

variable "s3_prefix" {
  description = "S3 prefix where the artifacts are stored"
  type        = string
}
