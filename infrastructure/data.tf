data "terraform_remote_state" "alb" {
  backend = "s3"

  config = {
    region     = "eu-west-1"
    bucket     = "data-tf-backend"
    key        = "cognism/aws/environments/data-dev/science/shared/load_balancers/infrastructure/terraform.tfstate"
    encrypt    = true
    kms_key_id = "arn:aws:kms:eu-west-1:514595551765:key/78f573d5-804c-4c04-9a30-810f853e62c7"
    profile    = "cognism-data-mlops-dev"
  }
}

data "aws_iam_policy_document" "ecs_task_trust" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

data "aws_iam_policy_document" "ecs_execution_ssm" {
  statement {
    sid    = "SSMAccess"
    effect = "Allow"

    actions = ["ssm:GetParameters"]

    resources = [
      "arn:aws:ssm:eu-west-1:463470983643:parameter/science-dev/poc-deployment/run-rime/*"
    ]
  }
}

data "aws_iam_policy_document" "ecs_task_s3" {
  statement {
    sid    = "ListBucket"
    effect = "Allow"

    actions = ["s3:ListBucket"]

    resources = [
      "arn:aws:s3:::${local.s3_bucket_name}"
    ]
  }

  statement {
    sid    = "ReadObjects"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:GetObjectTagging"
    ]

    resources = [
      "arn:aws:s3:::${local.s3_bucket_name}/*"
    ]
  }
}
