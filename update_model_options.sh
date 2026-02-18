#!/bin/bash
set -euo pipefail

WORKFLOW_FILE=".github/workflows/deploy-model.yaml"
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
' "$WORKFLOW_FILE" > tmp.yml

mv tmp.yml "$WORKFLOW_FILE"

echo "Workflow updated with ${#dirs[@]} models."