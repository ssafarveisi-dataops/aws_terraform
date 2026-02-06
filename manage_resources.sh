#!/bin/bash
set -euo pipefail

# Prevent AWS CLI from opening output in a pager (less)
export AWS_PAGER=""

# -------------------------------------------------------------
# Logging helper
# - stdout: reserved for machine-readable return values
# - stderr: for human-readable logs
# -------------------------------------------------------------
log() { echo "INFO: $*" >&2; }

aws_capture() {
  # Usage: out="$(aws_capture ecs list-clusters ...)"
  # - prints stdout on success
  # - exits the whole script on failure (even inside $(...))
  local out
  if ! out="$(aws "$@" 2>&1)"; then
    echo "ERROR: aws $* failed:" >&2
    echo "$out" >&2
    exit 1
  fi
  printf "%s" "$out"
}

cleanup_temp_files() {
  rm -f ecs-container-definitions.json \
        ecs-task-s3-policy.json \
        ecs-task-trust.json

  log "Cleaned up temporary ECS JSON files"
}

wait_for_sg_detach() {
  local sg_id="$1"
  local timeout_seconds="${2:-180}"   # default: 3 minutes
  local sleep_seconds="${3:-10}"      # default: 10s

  log "Waiting for security group ${sg_id} to be released (timeout=${timeout_seconds}s)..."

  local start now
  start="$(date +%s)"

  while true; do
    # count ENIs still referencing the SG
    local count
    count="$(aws ec2 describe-network-interfaces \
      --filters "Name=group-id,Values=${sg_id}" \
      --query "length(NetworkInterfaces)" \
      --output text)"

    if [[ "${count}" == "0" ]]; then
      log "Security group ${sg_id} is no longer referenced by any ENIs."
      return 0
    fi

    now="$(date +%s)"
    if (( now - start >= timeout_seconds )); then
      echo "ERROR: Timed out waiting for SG ${sg_id} to detach. Still referenced by ${count} ENI(s)." >&2
      aws ec2 describe-network-interfaces \
        --filters "Name=group-id,Values=${sg_id}" \
        --query "NetworkInterfaces[].{ENI:NetworkInterfaceId,Status:Status,Desc:Description,Attachment:Attachment.InstanceId,PrivateIP:PrivateIpAddress,Subnet:SubnetId}" \
        --output table >&2
      exit 1
    fi

    sleep "${sleep_seconds}"
  done
}

# Optional: improve errexit behavior in modern bash (safe no-op if unsupported)
shopt -s inherit_errexit 2>/dev/null || true

# -------------------------------------------------------------
# Small helpers (strict mode friendly)
# -------------------------------------------------------------
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

require_nonempty() {
  local name="$1"
  local value="$2"
  value="$(trim "$value")"
  if [[ -z "$value" ]]; then
    echo "ERROR: missing required argument: ${name}" >&2
    exit 1
  fi
}

# =============================================================
# PART A) CloudWatch Log Group + IAM Roles
# =============================================================

create_log_group() {
  local prefix="$1"
  local lg_name="${prefix}-litserve-logs"

  local existing
  existing="$(aws logs describe-log-groups \
    --log-group-name-prefix "${lg_name}" \
    --query "logGroups[?logGroupName=='${lg_name}'].logGroupName | [0]" \
    --output text)"

  if [[ -z "${existing}" || "${existing}" == "None" ]]; then
    aws logs create-log-group --log-group-name "${lg_name}" >/dev/null
    log "Created log group: ${lg_name}"
  else
    log "Log group already exists: ${lg_name}"
  fi

  aws logs put-retention-policy --log-group-name "${lg_name}" --retention-in-days 1 >/dev/null
  echo "${lg_name}"
}

create_trust_policy() {
  cat <<EOF > ecs-task-trust.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ecs-tasks.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

create_ecs_task_execution_role() {
  local prefix="$1"
  local role_name="${prefix}-poc-deployment-task-execution-role"

  create_trust_policy

  if ! aws iam get-role --role-name "${role_name}" >/dev/null 2>&1; then
    aws iam create-role --role-name "${role_name}" --assume-role-policy-document file://ecs-task-trust.json >/dev/null
    log "Created execution role: ${role_name}"
  else
    log "Execution role already exists: ${role_name}"
  fi

  local attached
  attached="$(aws iam list-attached-role-policies \
    --role-name "${role_name}" \
    --query "AttachedPolicies[?PolicyArn=='arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy'].PolicyArn | [0]" \
    --output text)"

  if [[ "${attached}" != "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy" ]]; then
    aws iam attach-role-policy --role-name "${role_name}" \
      --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy" >/dev/null
    log "Attached AmazonECSTaskExecutionRolePolicy to: ${role_name}"
  else
    log "Managed policy already attached to: ${role_name}"
  fi

  aws iam get-role --role-name "${role_name}" --query "Role.Arn" --output text
}

create_ecs_task_role() {
  local prefix="$1"
  local role_name="${prefix}-poc-deployment-task-role"

  create_trust_policy

  if ! aws iam get-role --role-name "${role_name}" >/dev/null 2>&1; then
    aws iam create-role --role-name "${role_name}" --assume-role-policy-document file://ecs-task-trust.json >/dev/null
    log "Created task role: ${role_name}"
  else
    log "Task role already exists: ${role_name}"
  fi

  aws iam get-role --role-name "${role_name}" --query "Role.Arn" --output text
}

attach_ecs_task_s3_policy() {
  local prefix="$1"
  local s3_bucket="$2"
  local s3_prefix="$3"

  local role_name="${prefix}-poc-deployment-task-role"
  local policy_name="${prefix}-poc-deployment-task-execution-s3"

  cat <<EOF > ecs-task-s3-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ListBucket",
      "Effect": "Allow",
      "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::${s3_bucket}"
    },
    {
      "Sid": "ReadObjects",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:GetObjectTagging"
      ],
      "Resource": "arn:aws:s3:::${s3_bucket}/${s3_prefix}/*"
    }
  ]
}
EOF

  aws iam put-role-policy --role-name "${role_name}" --policy-name "${policy_name}" \
    --policy-document file://ecs-task-s3-policy.json >/dev/null

  log "Inline S3 policy attached/updated: ${policy_name} -> ${role_name}"
}

# =============================================================
# PART B) Security Group + ALB Target Group + Listener Rule
# =============================================================

create_ecs_security_group() {
  local prefix="$1" vpc_id="$2" app_port="$3" alb_sg_id="$4"
  local sg_name="${prefix}-ecs-traffic"

  local sg_id
  sg_id="$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=${vpc_id}" "Name=group-name,Values=${sg_name}" \
    --query "SecurityGroups[0].GroupId" --output text)"

  if [[ -z "${sg_id}" || "${sg_id}" == "None" ]]; then
    sg_id="$(aws ec2 create-security-group \
      --group-name "${sg_name}" \
      --description "Allow inbound traffic to ECS containers from ALB" \
      --vpc-id "${vpc_id}" \
      --query "GroupId" --output text)"
    log "Created security group: ${sg_id}"
  else
    log "Security group already exists: ${sg_id}"
  fi

  aws ec2 create-tags --resources "${sg_id}" --tags Key=Name,Value="Poc deployment ECS container instance SG" >/dev/null

  aws ec2 authorize-security-group-ingress \
    --group-id "${sg_id}" \
    --ip-permissions "IpProtocol=tcp,FromPort=${app_port},ToPort=${app_port},UserIdGroupPairs=[{GroupId=${alb_sg_id},Description='HTTP from ALB'}]" \
    >/dev/null 2>&1 || true

  aws ec2 authorize-security-group-egress \
    --group-id "${sg_id}" \
    --ip-permissions "IpProtocol=-1,IpRanges=[{CidrIp=0.0.0.0/0}]" \
    >/dev/null 2>&1 || true

  echo "${sg_id}"
}

delete_ecs_security_group() {
  local prefix="$1"
  local vpc_id="$2"

  local sg_name="${prefix}-ecs-traffic"

  local sg_id
  sg_id="$(aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=${vpc_id}" "Name=group-name,Values=${sg_name}" \
    --query "SecurityGroups[0].GroupId" --output text)"

  if [[ -z "${sg_id}" || "${sg_id}" == "None" ]]; then
    log "Security group not found: ${sg_name}"
    return 0
  fi

  # First attempt
  if aws ec2 delete-security-group --group-id "${sg_id}" >/dev/null 2>&1; then
    log "Deleted security group: ${sg_id}"
    return 0
  fi

  # If it failed, wait for detach and try once more (still strict: exits on timeout or second failure)
  log "Security group ${sg_id} still has dependencies. Waiting and retrying..."
  wait_for_sg_detach "${sg_id}" 180 10

  # Second attempt (if this fails, script will crash because set -e)
  aws ec2 delete-security-group --group-id "${sg_id}" >/dev/null
  log "Deleted security group after wait: ${sg_id}"
}

create_alb_target_group() {
  local prefix="$1" vpc_id="$2" app_port="$3"
  local tg_name="${prefix}-poc-deployment-tg"

  local tg_arn
  tg_arn="$(aws elbv2 describe-target-groups --names "${tg_name}" \
    --query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null || true)"

  if [[ -z "${tg_arn}" || "${tg_arn}" == "None" ]]; then
    tg_arn="$(aws elbv2 create-target-group \
      --name "${tg_name}" \
      --protocol HTTP \
      --port "${app_port}" \
      --target-type ip \
      --ip-address-type ipv4 \
      --vpc-id "${vpc_id}" \
      --health-check-enabled \
      --health-check-protocol HTTP \
      --health-check-path "/health" \
      --health-check-interval-seconds 20 \
      --tags Key=Name,Value="Poc deployment ALB Target Group" \
      --query "TargetGroups[0].TargetGroupArn" --output text)"
    log "Created target group: ${tg_arn}"
  else
    log "Target group already exists: ${tg_arn}"
  fi

  echo "${tg_arn}"
}

delete_alb_target_group() {
  local prefix="$1"
  local tg_name="${prefix}-poc-deployment-tg"

  local tg_arn
  tg_arn="$(aws elbv2 describe-target-groups --names "${tg_name}" \
    --query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null || true)"

  if [[ -z "${tg_arn}" || "${tg_arn}" == "None" ]]; then
    log "Target group not found: ${tg_name}"
    return 0
  fi

  aws elbv2 delete-target-group --target-group-arn "${tg_arn}" >/dev/null
  log "Deleted target group: ${tg_arn}"
}

create_listener_rule_route_litserve() {
  local prefix="$1" listener_arn="$2" priority="$3" tg_arn="$4"

  local existing_rule_arn
  existing_rule_arn="$(aws elbv2 describe-rules --listener-arn "${listener_arn}" \
    --query "Rules[?Priority=='${priority}'].RuleArn | [0]" --output text 2>/dev/null || true)"

  if [[ -n "${existing_rule_arn}" && "${existing_rule_arn}" != "None" ]]; then
    log "Listener rule already exists at priority ${priority}: ${existing_rule_arn}"
    echo "${existing_rule_arn}"
    return 0
  fi

  local rule_arn
  rule_arn="$(aws elbv2 create-rule \
    --listener-arn "${listener_arn}" \
    --priority "${priority}" \
    --conditions "Field=path-pattern,Values=/${prefix}/*" \
    --actions "Type=forward,TargetGroupArn=${tg_arn}" \
    --transforms "[
      {
        \"Type\": \"url-rewrite\",
        \"UrlRewriteConfig\": {
          \"Rewrites\": [
            { \"Regex\": \"^/${prefix}(/.*)$\", \"Replace\": \"\$1\" }
          ]
        }
      }
    ]" \
    --query "Rules[0].RuleArn" --output text)"

  log "Created listener rule: ${rule_arn}"
  echo "${rule_arn}"
}

delete_listener_rule_by_priority() {
  local listener_arn="$1" priority="$2"

  local rule_arn
  rule_arn="$(aws elbv2 describe-rules --listener-arn "${listener_arn}" \
    --query "Rules[?Priority=='${priority}'].RuleArn | [0]" --output text 2>/dev/null || true)"

  if [[ -z "${rule_arn}" || "${rule_arn}" == "None" ]]; then
    log "Listener rule not found for priority: ${priority}"
    return 0
  fi

  aws elbv2 delete-rule --rule-arn "${rule_arn}" >/dev/null
  log "Deleted listener rule: ${rule_arn}"
}

# =============================================================
# PART C) ECS Task Definition + ECS Service (create + delete)
# =============================================================

create_ecs_task_definition() {
  local prefix="$1"
  local task_role_arn="$2"
  local execution_role_arn="$3"
  local app_port="$4"
  local litserve_image="$5"     # or "PLACEHOLDER"
  local s3_bucket="$6"
  local s3_prefix="$7"
  local fastapi_root_path="$8"
  local log_group_name="$9"
  local aws_region="${10}"

  local family="${prefix}-poc-deployment-task"
  local container_name="litserve-container"

  if [[ "${litserve_image}" == "PLACEHOLDER" ]]; then
    # No healthCheck key at all (omit), include command
    cat > ecs-container-definitions.json <<EOF
[
  {
    "name": "${container_name}",
    "image": "hashicorp/http-echo:latest",
    "essential": true,
    "portMappings": [
      { "containerPort": ${app_port}, "protocol": "tcp", "appProtocol": "http" }
    ],
    "command": ["-listen=:${app_port}"],
    "environment": [
      { "name": "S3_BUCKET", "value": "${s3_bucket}" },
      { "name": "S3_PREFIX", "value": "${s3_prefix}" },
      { "name": "ROOT_PATH", "value": "${fastapi_root_path}" }
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "${log_group_name}",
        "awslogs-region": "${aws_region}",
        "mode": "non-blocking",
        "max-buffer-size": "25m",
        "awslogs-stream-prefix": "ecs"
      }
    }
  }
]
EOF
  else
    # Include healthCheck dict, omit command entirely
    cat > ecs-container-definitions.json <<EOF
[
  {
    "name": "${container_name}",
    "image": "${litserve_image}",
    "essential": true,
    "portMappings": [
      { "containerPort": ${app_port}, "protocol": "tcp", "appProtocol": "http" }
    ],
    "healthCheck": {
      "command": ["CMD-SHELL", "curl -f http://localhost:${app_port}/health || exit 1"],
      "interval": 30,
      "timeout": 5,
      "retries": 3,
      "startPeriod": 60
    },
    "environment": [
      { "name": "S3_BUCKET", "value": "${s3_bucket}" },
      { "name": "S3_PREFIX", "value": "${s3_prefix}" },
      { "name": "ROOT_PATH", "value": "${fastapi_root_path}" }
    ],
    "logConfiguration": {
      "logDriver": "awslogs",
      "options": {
        "awslogs-group": "${log_group_name}",
        "awslogs-region": "${aws_region}",
        "mode": "non-blocking",
        "max-buffer-size": "25m",
        "awslogs-stream-prefix": "ecs"
      }
    }
  }
]
EOF
  fi

  local taskdef_arn
  taskdef_arn="$(
    aws_capture ecs register-task-definition \
      --family "${family}" \
      --network-mode awsvpc \
      --requires-compatibilities FARGATE \
      --task-role-arn "${task_role_arn}" \
      --execution-role-arn "${execution_role_arn}" \
      --cpu "256" \
      --memory "512" \
      --runtime-platform "operatingSystemFamily=LINUX,cpuArchitecture=X86_64" \
      --container-definitions file://ecs-container-definitions.json \
      --query "taskDefinition.taskDefinitionArn" \
      --output text
  )"

  log "Registered task definition: ${taskdef_arn}"
  echo "${taskdef_arn}"
}

create_or_update_ecs_service() {
  local prefix="$1"
  local ecs_cluster_id="$2"
  local task_definition_arn="$3"
  local app_port="$4"
  local ecs_security_group_id="$5"
  local target_group_arn="$6"
  local subnets_csv="$7"
  local health_grace="$8"

  local service_name="${prefix}-poc-deployment-service"
  local container_name="litserve-container"
  local netcfg="awsvpcConfiguration={subnets=[${subnets_csv}],securityGroups=[${ecs_security_group_id}],assignPublicIp=ENABLED}"

  local existing_status
  existing_status="$(aws ecs describe-services \
    --cluster "${ecs_cluster_id}" \
    --services "${service_name}" \
    --query "services[0].status" \
    --output text 2>/dev/null || true)"

  if [[ -z "${existing_status}" || "${existing_status}" == "None" || "${existing_status}" == "INACTIVE" ]]; then
    local service_arn
    service_arn="$(aws ecs create-service \
      --cluster "${ecs_cluster_id}" \
      --service-name "${service_name}" \
      --task-definition "${task_definition_arn}" \
      --desired-count 1 \
      --launch-type FARGATE \
      --health-check-grace-period-seconds "${health_grace}" \
      --deployment-configuration "minimumHealthyPercent=100,maximumPercent=200" \
      --network-configuration "${netcfg}" \
      --load-balancers "targetGroupArn=${target_group_arn},containerName=${container_name},containerPort=${app_port}" \
      --query "service.serviceArn" \
      --output text)"
    log "Created ECS service: ${service_arn}"
    echo "${service_arn}"
    return 0
  fi

  local updated_arn
  updated_arn="$(aws ecs update-service \
    --cluster "${ecs_cluster_id}" \
    --service "${service_name}" \
    --task-definition "${task_definition_arn}" \
    --health-check-grace-period-seconds "${health_grace}" \
    --force-new-deployment \
    --query "service.serviceArn" \
    --output text)"

  log "Updated ECS service (forced deployment): ${updated_arn}"
  echo "${updated_arn}"
}

delete_ecs_service() {
  local prefix="$1"
  local ecs_cluster_id="$2"

  local service_name="${prefix}-poc-deployment-service"

  local status
  status="$(aws ecs describe-services \
    --cluster "${ecs_cluster_id}" \
    --services "${service_name}" \
    --query "services[0].status" \
    --output text 2>/dev/null || true)"

  if [[ -z "${status}" || "${status}" == "None" || "${status}" == "INACTIVE" ]]; then
    log "ECS service not found or already inactive: ${service_name}"
    return 0
  fi

  # Scale down first (avoids some dependency issues)
  aws ecs update-service \
    --cluster "${ecs_cluster_id}" \
    --service "${service_name}" \
    --desired-count 0 \
    >/dev/null

  # Delete service
  aws ecs delete-service \
    --cluster "${ecs_cluster_id}" \
    --service "${service_name}" \
    --force \
    >/dev/null

  log "Deleted ECS service (forced): ${service_name}"
}

deregister_task_definitions_for_family() {
  local prefix="$1"
  local family="${prefix}-poc-deployment-task"

  # Deregister ALL revisions for this family
  local arns
  arns="$(aws ecs list-task-definitions \
    --family-prefix "${family}" \
    --status ACTIVE \
    --sort DESC \
    --query "taskDefinitionArns[]" \
    --output text 2>/dev/null || true)"

  if [[ -z "${arns}" || "${arns}" == "None" ]]; then
    log "No ACTIVE task definitions found for family: ${family}"
    return 0
  fi

  # list-task-definitions returns space-separated ARNs in --output text
  for arn in ${arns}; do
    aws ecs deregister-task-definition --task-definition "${arn}" >/dev/null
    log "Deregistered task definition: ${arn}"
  done
}

# =============================================================
# Orchestrators (create/destroy all)
# =============================================================

create_all_resources() {
  local prefix="$1"
  local s3_bucket="$2"
  local s3_prefix="$3"
  local vpc_id="$4"
  local app_port="$5"
  local alb_sg_id="$6"
  local listener_arn="$7"
  local priority="$8"
  local ecs_cluster_id="$9"
  local subnets_csv="${10}"
  local aws_region="${11}"
  local litserve_image="${12}"
  local fastapi_root_path="${13}"

  require_nonempty "prefix" "${prefix}"
  require_nonempty "s3_bucket" "${s3_bucket}"
  require_nonempty "s3_prefix" "${s3_prefix}"
  require_nonempty "vpc_id" "${vpc_id}"
  require_nonempty "app_port" "${app_port}"
  require_nonempty "alb_sg_id" "${alb_sg_id}"
  require_nonempty "listener_arn" "${listener_arn}"
  require_nonempty "priority" "${priority}"
  require_nonempty "ecs_cluster_id" "${ecs_cluster_id}"
  require_nonempty "subnets_csv" "${subnets_csv}"
  require_nonempty "aws_region" "${aws_region}"
  require_nonempty "litserve_image" "${litserve_image}"
  require_nonempty "fastapi_root_path" "${fastapi_root_path}"

  # Base resources
  local log_group_name execution_role_arn task_role_arn
  local ecs_sg_id tg_arn rule_arn
  local taskdef_arn service_arn

  log_group_name="$(create_log_group "$prefix")"
  execution_role_arn="$(create_ecs_task_execution_role "$prefix")"
  task_role_arn="$(create_ecs_task_role "$prefix")"
  # Attach a S3 policy to the ECS task role
  attach_ecs_task_s3_policy "$prefix" "$s3_bucket" "$s3_prefix"

  ecs_sg_id="$(create_ecs_security_group "$prefix" "$vpc_id" "$app_port" "$alb_sg_id")"
  tg_arn="$(create_alb_target_group "$prefix" "$vpc_id" "$app_port")"
  rule_arn="$(create_listener_rule_route_litserve "$prefix" "$listener_arn" "$priority" "$tg_arn")"

  # ECS task + service
  taskdef_arn="$(create_ecs_task_definition \
    "$prefix" \
    "$task_role_arn" \
    "$execution_role_arn" \
    "$app_port" \
    "$litserve_image" \
    "$s3_bucket" \
    "$s3_prefix" \
    "$fastapi_root_path" \
    "$log_group_name" \
    "$aws_region")"
  
  require_nonempty "TASK_DEFINITION_ARN" "${taskdef_arn}"
  
  service_arn="$(create_or_update_ecs_service \
    "$prefix" \
    "$ecs_cluster_id" \
    "$taskdef_arn" \
    "$app_port" \
    "$ecs_sg_id" \
    "$tg_arn" \
    "$subnets_csv" \
    "120")"

  log "All resources created successfully"

  cleanup_temp_files
}

destroy_all_resources() {
  local prefix="$1"
  local vpc_id="$2"
  local listener_arn="$3"
  local priority="$4"
  local ecs_cluster_id="$5"

  log "Removing resources for prefix: ${prefix}"

  # ECS first (so network + IAM can be deleted cleanly)
  delete_ecs_service "${prefix}" "${ecs_cluster_id}"
  deregister_task_definitions_for_family "${prefix}"

  # ALB/network resources
  delete_listener_rule_by_priority "${listener_arn}" "${priority}"
  delete_alb_target_group "${prefix}"
  delete_ecs_security_group "${prefix}" "${vpc_id}"

  # IAM cleanup (reverse-safe order)
  aws iam delete-role-policy \
    --role-name "${prefix}-poc-deployment-task-role" \
    --policy-name "${prefix}-poc-deployment-task-execution-s3" >/dev/null

  aws iam detach-role-policy \
    --role-name "${prefix}-poc-deployment-task-execution-role" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy" >/dev/null

  aws iam delete-role --role-name "${prefix}-poc-deployment-task-role" >/dev/null
  aws iam delete-role --role-name "${prefix}-poc-deployment-task-execution-role" >/dev/null

  # CloudWatch log group
  aws logs delete-log-group --log-group-name "${prefix}-litserve-logs" >/dev/null

  log "All resources removed for prefix: ${prefix}"
}

usage() {
  echo "" >&2
  echo "Usage:" >&2
  echo "  Create:" >&2
  echo "    ./create_resources.sh create <prefix> <s3_bucket> <s3_prefix> <vpc_id> <app_port> <alb_sg_id> <listener_arn> <priority> <ecs_cluster_id> <subnets_csv> <aws_region> <litserve_image|PLACEHOLDER> <fastapi_root_path>" >&2
  echo "" >&2
  echo "  Destroy:" >&2
  echo "    ./create_resources.sh destroy <prefix> <vpc_id> <listener_arn> <priority> <ecs_cluster_id>" >&2
  echo "" >&2
  exit 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ $# -lt 2 ]]; then usage; fi

  case "$1" in
    create)
      if [[ $# -ne 14 ]]; then usage; fi
      create_all_resources \
        "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "${12}" "${13}" "${14}"
      ;;
    destroy)
      if [[ $# -ne 6 ]]; then usage; fi
      destroy_all_resources "$2" "$3" "$4" "$5" "$6"
      ;;
    *)
      usage
      ;;
  esac
fi