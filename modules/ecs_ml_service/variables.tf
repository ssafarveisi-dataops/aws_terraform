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

variable "litserve_image" {
  description = "Litserve image uri"
  type        = string
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
  description = "S3 key for the stored artifact"
  type        = string
}

variable "fastapi_root_path" {
  description = "The root path for the FastAPI app"
  type        = string
}
