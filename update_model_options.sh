#!/bin/bash
set -euo pipefail

WORKFLOW_FILES=(
  ".github/workflows/deploy-task-definition.yaml"
  ".github/workflows/manage-resources.yaml"
)
MODELS_DIR="models"

if [[ ! -d "$MODELS_DIR" ]]; then
  echo "No models directory found."
  exit 0
fi

# Collect first-level directories
mapfile -t dirs < <(find "$MODELS_DIR" -mindepth 1 -maxdepth 1 -type d -printf "%f\n" | sort)

if [[ ${#dirs[@]} -eq 0 ]]; then
  echo "No model directories found."
  exit 0
fi

# Build YAML options block
OPTIONS=""
for d in "${dirs[@]}"; do
  OPTIONS="${OPTIONS}          - ${d}\n"
done

update_workflow_file() {
  local workflow_file="$1"
  # Replace only the model options block
  awk -v options="$OPTIONS" '
    BEGIN { replace=0 }
    /model:/ { print; replace=1; next }
    replace && /options:/ {
        print;
        printf "%s", options;
        getline;
        while ($0 ~ /^[[:space:]]+- /) { getline }
        replace=0;
    }
    { print }
  ' "$workflow_file" > tmp.yml

  mv tmp.yml "$workflow_file"
  echo "Updated: $workflow_file"
}

for wf in "${WORKFLOW_FILES[@]}"; do
  update_workflow_file "$wf"
done