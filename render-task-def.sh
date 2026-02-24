#!/bin/bash
set -euo pipefail

# Usage:
#   ./render-task-def.sh path/to/config.yaml path/to/taskdef.template.json path/to/taskdef.rendered.json
CONFIG_PATH="${1:?First argument must be the path to config.yaml}"
TEMPLATE_PATH="${2:?Second argument must be the path to the task definition template JSON}"
OUTPUT_PATH="${3:?Third argument must be the output path for the rendered task definition JSON}"

# --- Required environment variables provided by CI step ---
: "${FAMILY:?Environment variable FAMILY is required}"
: "${TASK_ROLE_ARN:?Environment variable TASK_ROLE_ARN is required}"
: "${EXEC_ROLE_ARN:?Environment variable EXEC_ROLE_ARN is required}"
: "${IMAGE:?Environment variable IMAGE is required}"
: "${LOG_GROUP:?Environment variable LOG_GROUP is required}"

echo "Using config:     ${CONFIG_PATH}"
echo "Using template:   ${TEMPLATE_PATH}"
echo "Output will be:   ${OUTPUT_PATH}"
echo "FAMILY:           ${FAMILY}"
echo "TASK_ROLE_ARN:    ${TASK_ROLE_ARN}"
echo "EXEC_ROLE_ARN:    ${EXEC_ROLE_ARN}"
echo "IMAGE:            ${IMAGE}"
echo "LOG_GROUP:        ${LOG_GROUP}"

# --- Extract runtime env + secrets from config.yaml ---

# If run_time.env does not exist, default to []
RUNTIME_ENV_JSON=$(yq -o=json '.app.container.run_time.env // []' "${CONFIG_PATH}")

# If run_time.secrets does not exist, default to []
RUNTIME_SECRETS_JSON=$(yq -o=json '.app.container.run_time.secrets // []' "${CONFIG_PATH}")

# --- Render task definition with jq ---

jq \
  --arg family "${FAMILY}" \
  --arg task_role_arn "${TASK_ROLE_ARN}" \
  --arg exec_role_arn "${EXEC_ROLE_ARN}" \
  --arg image "${IMAGE}" \
  --arg log_group "${LOG_GROUP}" \
  --argjson runtime_env "${RUNTIME_ENV_JSON}" \
  --argjson runtime_secrets "${RUNTIME_SECRETS_JSON}" \
  '
  # Fill top-level placeholders
  .family          = $family
  | .taskRoleArn   = $task_role_arn
  | .executionRoleArn = $exec_role_arn

  # Fill container image
  | .containerDefinitions[0].image = $image

  # Inject environment variables from config.run_time.env
  | .containerDefinitions[0].environment = $runtime_env

  # Inject secrets: map { name, value } -> { name, valueFrom }
  | .containerDefinitions[0].secrets =
      (($runtime_secrets // [])
       | map({name: .name, valueFrom: .value}))
  
  # Fill log group
  | .containerDefinitions[0].logConfiguration.options["awslogs-group"] = $log_group
  ' "${TEMPLATE_PATH}" > "${OUTPUT_PATH}"

echo "Rendered task definition written to ${OUTPUT_PATH}"
cat "${OUTPUT_PATH}"