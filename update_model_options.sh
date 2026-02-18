#!/bin/bash
set -euo pipefail

MODELS_DIR="models"
WORKFLOW_FILES=(
  ".github/workflows/deploy-task-definition.yaml"
  ".github/workflows/manage-resources.yaml"
)

if [[ ! -d "$MODELS_DIR" ]]; then
  echo "No models directory found."
  exit 0
fi

# Collect first-level directories under models/
mapfile -t dirs < <(find "$MODELS_DIR" -mindepth 1 -maxdepth 1 -type d -printf "%f\n" | sort)

if [[ ${#dirs[@]} -eq 0 ]]; then
  echo "No model directories found."
  exit 0
fi

# Build YAML options block (same indentation as your original script)
OPTIONS=""
for d in "${dirs[@]}"; do
  OPTIONS+="          - ${d}"$'\n'
done

update_workflow_file() {
  local workflow_file="$1"

  if [[ ! -f "$workflow_file" ]]; then
    echo "Skipping missing workflow file: ${workflow_file}"
    return 0
  fi

  local tmp
  tmp="$(mktemp)"

  awk -v options="$OPTIONS" '
    BEGIN { in_model=0; in_model_options=0; replaced=0 }

    # Enter the "model:" input block
    /^[[:space:]]*model:[[:space:]]*$/ {
      print
      in_model=1
      next
    }

    # When inside model: block, find options:
    in_model && /^[[:space:]]*options:[[:space:]]*$/ {
      print
      printf "%s", options
      in_model_options=1
      replaced=1
      next
    }

    # Skip existing list items under model.options
    in_model_options {
      if ($0 ~ /^[[:space:]]+-[[:space:]]+/) {
        next
      }
      # First non-list line ends the options list (and model block for our purposes)
      in_model_options=0
      in_model=0
      print
      next
    }

    { print }

    END {
      if (replaced == 0) {
        # exit code 0, but caller can detect via message if needed
      }
    }
  ' "$workflow_file" > "$tmp"

  mv "$tmp" "$workflow_file"
  echo "Updated: ${workflow_file}"
}

for wf in "${WORKFLOW_FILES[@]}"; do
  update_workflow_file "$wf"
done

echo "Done. Updated model options with ${#dirs[@]} entries."