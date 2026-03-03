resource "aws_iam_role" "ecs_task_execution_role" {
  name               = "poc-deployment-task-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_trust.json
}

resource "aws_iam_role_policy_attachment" "ecs_execution_managed" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "ecs_execution_ssm" {
  name   = "poc-deployment-task-execution-ssm"
  role   = aws_iam_role.ecs_task_execution_role.id
  policy = data.aws_iam_policy_document.ecs_execution_ssm.json
}

resource "aws_iam_role" "ecs_task_role" {
  name               = "poc-deployment-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_trust.json
}

resource "aws_iam_role_policy" "ecs_task_s3" {
  name   = "poc-deployment-task-execution-s3"
  role   = aws_iam_role.ecs_task_role.id
  policy = data.aws_iam_policy_document.ecs_task_s3.json
}
