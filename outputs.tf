output "lb_dns_name" {
  value = aws_lb.load_balancer.dns_name
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "ecs_cluster_id" {
  value = aws_ecs_cluster.ecs_cluster.id
}

output "lb_listener_arn" {
  value = aws_lb_listener.lb_listener.arn
}

output "alb_security_group_id" {
  value = aws_security_group.alb_security_group.id
}

output "public_subnet_list" {
  value = aws_subnet.public_subnets[*].id
}
