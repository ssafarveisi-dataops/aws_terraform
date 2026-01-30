#!/usr/bin/env bash
set -euo pipefail

############################################
# EXAMPLE INPUTS (modify as needed)
############################################
export FAMILY="my-litserve-task"
export TASK_ROLE_ARN="arn:aws:iam::123456789012:role/MyTaskRole"
export EXEC_ROLE_ARN="arn:aws:iam::123456789012:role/MyExecutionRole"
export IMAGE="123456789012.dkr.ecr.eu-central-1.amazonaws.com/my-litserve:1.0.0"
export S3_BUCKET="dataops-poc-deployment"
export S3_PREFIX="triton_repository"
export LOG_GROUP="/ecs/my-litserve"
export AWS_REGION="eu-central-1"

############################################
# Optional command override
############################################
# For placeholder image, you might want:
# COMMAND_JSON='["-listen=:8080","-text=placeholder ok"]'
COMMAND_JSON='[]'

############################################
# Template paths
############################################
TEMPLATE="task-definition.template.json"
OUT="task-definition.json"

echo "Rendering ECS task definition…"

############################################
# Run jq transformation
############################################
jq \
  --arg family "$FAMILY" \
  --arg taskRoleArn "$TASK_ROLE_ARN" \
  --arg executionRoleArn "$EXEC_ROLE_ARN" \
  --arg image "$IMAGE" \
  --arg s3_bucket "$S3_BUCKET" \
  --arg s3_prefix "$S3_PREFIX" \
  --arg log_group "$LOG_GROUP" \
  --arg region "$AWS_REGION" \
  --argjson command "$COMMAND_JSON" \
  '
  .family = $family
  | .taskRoleArn = $taskRoleArn
  | .executionRoleArn = $executionRoleArn
  | .containerDefinitions[0].image = $image
  | .containerDefinitions[0].command = $command
  | (.containerDefinitions[0].environment |=
      map(
        if .name == "S3_BUCKET" then .value = $s3_bucket
        elif .name == "S3_PREFIX" then .value = $s3_prefix
        else .
        end
      )
    )
  | .containerDefinitions[0].logConfiguration.options["awslogs-group"] = $log_group
  | .containerDefinitions[0].logConfiguration.options["awslogs-region"] = $region
  ' "$TEMPLATE" > "$OUT"

############################################
# Output result
############################################
echo ""
echo "--------------------------------------"
echo "Rendered task definition: ${OUT}"
echo "--------------------------------------"
cat "$OUT"
echo ""
