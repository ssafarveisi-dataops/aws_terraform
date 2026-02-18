#!/bin/bash
set -euo pipefail

MODELS_DIR="models"
WORKFLOW_FILES=(
  ".github/workflows/deploy-model.yaml"
  ".github/workflows/manage-resources.yaml"
)

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

# Build YAML options block (expects the same indentation as before)
OPTIONS=""
for d in "${dirs[@]}"; do
  OPTIONS="${OPTIONS}          - ${d}\n"
done

update_workflow_file() {
  local workflow_file="$1"

  if [[ ! -f "$workflow_file" ]]; then
    echo "Skipping missing workflow file: $workflow_file"
    return 0
  fi

  local tmp
  tmp="$(mktemp)"

  # Replace only the `model:` input's `options:` list
  awk -v options="$OPTIONS" '
    BEGIN { in_model=0; replaced=0 }

    /^[[:space:]]*model:[[:space:]]*$/ { print; in_model=1; next }

    in_model && /^[[:space:]]*options:[[:space:]]*$/ {
      print;
      printf "%s", options;

      # Skip existing list items under options (lines beginning with "-")
      while (getline) {
        if ($0 ~ /^[[:space:]]+-[[:space:]]+/) { continue }
        print;
        in_model=0;
        replaced=1;
        nextfile
      }
    }

    { print }
    END {
      # If model/options block wasn't found, we still succeed but emit a warning
      if (replaced == 0) {
        # Note: END prints to stderr is messy in awk; handled outside.
      }
    }
  ' "$workflow_file" > "$tmp"

  mv "$tmp" "$workflow_file"
  echo "Updated: $workflow_file"
}

updated_any=0
for wf in "${WORKFLOW_FILES[@]}"; do
  update_workflow_file "$wf"
  updated_any=1
done

if [[ "$updated_any" -eq 1 ]]; then
  echo "Workflows updated with ${#dirs[@]} models."
fi