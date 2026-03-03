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
  rm -f ecs-container-definitions.json 
  log "Cleaned up temporary ECS JSON files"
}

# improve errexit behavior in modern bash (safe no-op if unsupported)
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
# PART A) CloudWatch Log Group
# =============================================================

create_log_group() {
  local prefix="$1"
  local lg_name="poc-model-deployment-${prefix}-logs"

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

# =============================================================
# PART B) ALB Target Group + Listener Rule
# =============================================================

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

create_listener_rule_route() {
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
    --conditions "Field=path-pattern,Values=/poc-model-deployment/${prefix}/*" \
    --actions "Type=forward,TargetGroupArn=${tg_arn}" \
    --transforms "[
      {
        \"Type\": \"url-rewrite\",
        \"UrlRewriteConfig\": {
          \"Rewrites\": [
            { \"Regex\": \"^/poc-model-deployment/${prefix}(/.*)$\", \"Replace\": \"\$1\" }
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
  local image="$5"     # or "PLACEHOLDER"
  local log_group_name="$6"
  local aws_region="$7"

  local family="${prefix}-poc-model-deployment-task"
  local container_name="poc-model-deployment-container"

  if [[ "${image}" == "PLACEHOLDER" ]]; then
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
    "image": "${image}",
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

  local service_name="${prefix}-poc-model-deployment-service"
  local container_name="poc-model-deployment-container"
  local netcfg="awsvpcConfiguration={subnets=[${subnets_csv}],securityGroups=[${ecs_security_group_id}],assignPublicIp=DISABLED}"

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

  local service_name="${prefix}-poc-model-deployment-service"

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
  local family="${prefix}-poc-model-deployment-task"

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
  local vpc_id="$2"
  local app_port="$3"
  local listener_arn="$4"
  local execution_role_arn="$5"
  local task_role_arn="$6"
  local ecs_sg_id="$7"
  local priority="$8"
  local ecs_cluster_id="$9"
  local subnets_csv="${10}"
  local aws_region="${11}"
  local image="${12}"

  require_nonempty "prefix" "${prefix}"
  require_nonempty "vpc_id" "${vpc_id}"
  require_nonempty "app_port" "${app_port}"
  require_nonempty "listener_arn" "${listener_arn}"
  require_nonempty "execution_role_arn" "${execution_role_arn}"
  require_nonempty "task_role_arn" "${task_role_arn}"
  require_nonempty "ecs_sg_id" "${ecs_sg_id}"
  require_nonempty "priority" "${priority}"
  require_nonempty "ecs_cluster_id" "${ecs_cluster_id}"
  require_nonempty "subnets_csv" "${subnets_csv}"
  require_nonempty "aws_region" "${aws_region}"
  require_nonempty "image" "${image}"

  # Base resources
  local log_group_name
  local tg_arn rule_arn
  local taskdef_arn service_arn

  log_group_name="$(create_log_group "$prefix")"

  tg_arn="$(create_alb_target_group "$prefix" "$vpc_id" "$app_port")"
  rule_arn="$(create_listener_rule_route "$prefix" "$listener_arn" "$priority" "$tg_arn")"

  # ECS task + service
  taskdef_arn="$(create_ecs_task_definition \
    "$prefix" \
    "$task_role_arn" \
    "$execution_role_arn" \
    "$app_port" \
    "$image" \
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
  local listener_arn="$2"
  local priority="$3"
  local ecs_cluster_id="$4"

  log "Removing resources for prefix: ${prefix}"

  # ECS first
  delete_ecs_service "${prefix}" "${ecs_cluster_id}"
  deregister_task_definitions_for_family "${prefix}"

  # ALB/network resources
  delete_listener_rule_by_priority "${listener_arn}" "${priority}"
  delete_alb_target_group "${prefix}"

  # CloudWatch log group
  aws logs delete-log-group --log-group-name "poc-model-deployment-${prefix}-logs" >/dev/null

  log "All resources removed for prefix: ${prefix}"
}

usage() {
  echo "" >&2
  echo "Usage:" >&2
  echo "  Create:" >&2
  echo "    ./create_resources.sh create <prefix> <vpc_id> <app_port> <listener_arn> <execution_role_arn> <task_role_arn> <ecs_sg_id> <priority> <ecs_cluster_id> <subnets_csv> <aws_region> <image|PLACEHOLDER>" >&2
  echo "" >&2
  echo "  Destroy:" >&2
  echo "    ./create_resources.sh destroy <prefix> <listener_arn> <priority> <ecs_cluster_id>" >&2
  echo "" >&2
  exit 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ $# -lt 2 ]]; then usage; fi

  case "$1" in
    create)
      if [[ $# -ne 13 ]]; then usage; fi
      create_all_resources \
        "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}" "${11}" "${12}" "${13}"
      ;;
    destroy)
      if [[ $# -ne 5 ]]; then usage; fi
      destroy_all_resources "$2" "$3" "$4" "$5"
      ;;
    *)
      usage
      ;;
  esac
fi