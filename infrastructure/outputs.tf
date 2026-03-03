output "ecs_cluster_id" {
  value = aws_ecs_cluster.ecs_cluster.id
}

output "alb_listener_arn" {
  value = data.terraform_remote_state.alb.outputs.alb_listener_arn
}

output "ecs_task_execution_role_arn" {
  value = aws_iam_role.ecs_task_execution_role.arn
}

output "ecs_task_role_arn" {
  value = aws_iam_role.ecs_task_role.arn
}

output "ecs_security_group_id" {
  value = aws_security_group.ecs_tasks.id
}
