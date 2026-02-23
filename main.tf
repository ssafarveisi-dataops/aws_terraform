resource "aws_vpc" "main" {
  cidr_block = var.base_cidr
  tags = {
    Name = "Poc deployment"
  }
}

resource "aws_subnet" "public_subnets" {
  count             = length(var.public_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = element(var.public_subnet_cidrs, count.index)
  availability_zone = element(var.azs, count.index)
  tags = {
    Name = "Poc deployment public subnet ${count.index + 1}"
  }
}

resource "aws_internet_gateway" "example" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "Poc deployment VPC IGW"
  }
}

resource "aws_route_table" "second_rt" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.example.id
  }
  tags = {
    Name = "Poc deployment 2nd Route Table"
  }
}

resource "aws_route_table_association" "public_subnet_asso" {
  count          = length(var.public_subnet_cidrs)
  subnet_id      = element(aws_subnet.public_subnets[*].id, count.index)
  route_table_id = aws_route_table.second_rt.id
}

resource "aws_security_group" "alb_security_group" {
  name        = "poc-deployment-alb-traffic"
  description = "Allow inbound traffic to ALB on port 80"
  vpc_id      = aws_vpc.main.id
  ingress {
    description = "HTTP from anywhere"
    from_port   = 80
    to_port     = 80
    protocol    = "TCP"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "Poc deployment ALB SG"
  }
}

resource "aws_lb" "load_balancer" {
  name               = "poc-deployment-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_security_group.id]
  subnets            = aws_subnet.public_subnets[*].id
  tags = {
    Name = "Poc deployment ALB"
  }
}

resource "aws_lb_target_group" "alb_target_group" {
  name            = "default-poc-deployment-tg"
  port            = 8080
  protocol        = "HTTP"
  target_type     = "ip"
  ip_address_type = "ipv4"
  vpc_id          = aws_vpc.main.id

  health_check {
    enabled  = true
    path     = "/health"
    interval = 20
    protocol = "HTTP"
  }

  tags = {
    Name = "Poc deployment ALB Target Group"
  }
}

resource "aws_lb_listener" "lb_listener" {
  load_balancer_arn = aws_lb.load_balancer.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.alb_target_group.arn
  }
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
