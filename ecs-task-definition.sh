set -euo pipefail

usage() {
  echo "Usage: $0 <current-task-def-arn> <new-image-uri> <output-json>" >&2
  exit 1
}

[[ $# -eq 3 ]] || usage

CURRENT_TASK_DEF="$1"
NEW_IMAGE="$2"
OUTPUT_FILE="$3"

aws ecs describe-task-definition \
  --task-definition "${CURRENT_TASK_DEF}" \
  --query 'taskDefinition' \
  --output json > taskdef-current.json

jq --arg image "${NEW_IMAGE}" '
  del(.taskDefinitionArn,.revision,.status,.requiresAttributes,.compatibilities,.registeredAt,.registeredBy)
  | .containerDefinitions[0].image = $image
' taskdef-current.json > "${OUTPUT_FILE}"

aws ecs register-task-definition \
  --cli-input-json "file://${OUTPUT_FILE}" \
  --query 'taskDefinition.taskDefinitionArn' \
  --output text

