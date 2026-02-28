output "ecs_cluster_id" {
  value = aws_ecs_cluster.ecs_cluster.id
}

output "alb_listener_arn" {
  value = data.terraform_remote_state.alb.outputs.alb_listener_arn
}


