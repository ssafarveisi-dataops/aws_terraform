locals {
  is_placeholder_image = var.litserve_image == "PLACEHOLDER"
  placeholder_image    = "hashicorp/http-echo:latest"
}

resource "aws_cloudwatch_log_group" "litserve_logs" {
  name              = "${var.resource_prefix}-litserve-logs"
  retention_in_days = 1
}

resource "aws_iam_role" "ecs_task_execution" {
  name               = "${var.resource_prefix}-poc-deployment-task-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_doc.json
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Role your ECS cluster's instances need during run time (e.g., access to a S3 bucket)
resource "aws_iam_role" "ecs_task" {
  name               = "${var.resource_prefix}-poc-deployment-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_doc.json
}

resource "aws_iam_role_policy" "ecs_task_s3" {
  name = "${var.resource_prefix}-poc-deployment-task-execution-s3"
  role = aws_iam_role.ecs_task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListBucket"
        Effect   = "Allow"
        Action   = "s3:ListBucket"
        Resource = "arn:aws:s3:::${var.s3_bucket}"
      },
      {
        Sid    = "ReadObjects"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:GetObjectTagging"
        ]
        Resource = "arn:aws:s3:::${var.s3_bucket}/${var.s3_prefix}/*"
      }
    ]
  })
}

resource "aws_security_group" "ecs_security_group" {
  name        = "${var.resource_prefix}-ecs-traffic"
  description = "Allow inbound traffic to ECS containers from ALB"
  vpc_id      = var.vpc_id
  ingress {
    description     = "HTTP from ALB"
    from_port       = var.app_port
    to_port         = var.app_port
    protocol        = "TCP"
    security_groups = [var.alb_security_group_id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "Poc deployment ECS container instance SG"
  }
}

resource "aws_lb_target_group" "alb_target_group" {
  name            = "${var.resource_prefix}-poc-deployment-tg"
  port            = var.app_port
  protocol        = "HTTP"
  target_type     = "ip"
  ip_address_type = "ipv4"
  vpc_id          = var.vpc_id

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

resource "aws_alb_listener_rule" "route_litserve" {
  listener_arn = var.lb_listener_arn
  priority     = var.listener_rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.alb_target_group.arn
  }
  condition {
    path_pattern {
      values = ["/${var.resource_prefix}/*"]
    }
  }

  transform {
    type = "url-rewrite"
    url_rewrite_config {
      rewrite {
        regex   = "^/${var.resource_prefix}(/.*)$"
        replace = "$1"
      }
    }
  }
}

resource "aws_ecs_task_definition" "ecs_task_definition" {
  family                   = "${var.resource_prefix}-poc-deployment-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  task_role_arn            = aws_iam_role.ecs_task.arn
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  cpu                      = 256
  memory                   = 512
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
  container_definitions = jsonencode([
    {
      name      = "litserve-container"
      image     = local.is_placeholder_image ? local.placeholder_image : "${var.litserve_image}"
      essential = true
      portMappings = [
        {
          containerPort = var.app_port # Litserve port
          protocol      = "tcp"
          appProtocol   = "http"
        }
      ]
      command = local.is_placeholder_image ? ["-listen=:${var.app_port}"] : null
      healthCheck = local.is_placeholder_image ? null : {
        command = [
          "CMD-SHELL",
          "curl -f http://localhost:${var.app_port}/health || exit 1"
        ]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60 # Wait for 60 seconds before checking health
      }

      environment = [
        {
          name  = "S3_BUCKET"
          value = "${var.s3_bucket}"
        },
        {
          name  = "S3_PREFIX"
          value = "${var.s3_prefix}"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = "${aws_cloudwatch_log_group.litserve_logs.name}"
          awslogs-region        = "${var.aws_region}"
          mode                  = "non-blocking",
          max-buffer-size       = "25m",
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "ecs_service" {
  name                 = "${var.resource_prefix}-poc-deployment-service"
  cluster              = var.ecs_cluster_id
  task_definition      = aws_ecs_task_definition.ecs_task_definition.arn
  desired_count        = 1
  force_new_deployment = true

  network_configuration {
    subnets          = var.public_subnet_list
    assign_public_ip = true
    security_groups  = [aws_security_group.ecs_security_group.id]
  }

  launch_type = "FARGATE"

  load_balancer {
    target_group_arn = aws_lb_target_group.alb_target_group.arn
    container_name   = "litserve-container"
    container_port   = var.app_port
  }
}
