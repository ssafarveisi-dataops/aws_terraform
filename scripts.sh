#!/usr/bin/env bash
set -euo pipefail

##############################################
# Function: Check if a service is ACTIVE in ECS
##############################################
function check_service_status {
    local cluster_name="$1"
    local service_name="$2"

    SERVICE_STATUS=$(
      aws ecs describe-services \
        --cluster "$cluster_name" \
        --services "$service_name" \
        | jq --raw-output 'select(.services[].status != null ) | .services[].status'
    )

    if [ "$SERVICE_STATUS" = "ACTIVE" ]; then
        echo "Service '$service_name' in cluster '$cluster_name' is ACTIVE"
        return 0
    else
        echo "Service '$service_name' does not exist or is not ACTIVE"
        return 1
    fi
}

##############################################
# Function: Concatenate all model YAMLs
##############################################
function concatenate_model_yamls {
    local output_file="models.yaml"

    # Remove the file first if it exists
    if [ -f "$output_file" ]; then
        rm "$output_file"
    fi

    # Concatenate all model config files
    for f in models/**/config.yaml; do
        cat "$f" >> "$output_file"
        echo "" >> "$output_file"
    done

    echo "Generated $output_file"
}


function help {
    echo "$0 <task> [args]"
    echo "Tasks:"
    compgen -A function | cat -n
}

TIMEFORMAT="Task completed in %3lR"
time ${@:-help}