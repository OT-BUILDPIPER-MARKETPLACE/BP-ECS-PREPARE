#!/bin/bash

source /opt/buildpiper/shell-functions/functions.sh
source /opt/buildpiper/shell-functions/log-functions.sh
source /opt/buildpiper/shell-functions/str-functions.sh
source /opt/buildpiper/shell-functions/file-functions.sh
source /opt/buildpiper/shell-functions/aws-functions.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$DEBUG" = true ]; then
  set -x
fi


CODEBASE_LOCATION="${WORKSPACE}"/"${CODEBASE_DIR}"
logInfoMessage "I'll do processing at [$CODEBASE_LOCATION]"

cd  "${CODEBASE_LOCATION}"



sleep  $SLEEP_DURATION


LATEST_IMAGE_NAME=${IMAGE_NAME}:${DEPLOY_TAG}
export LATEST_IMAGE_NAME="${IMAGE_NAME}:${DEPLOY_TAG}"
DEPLOY_STARTED_AT="$(date +%s)"
logInfoMessage "latest image name: $LATEST_IMAGE_NAME"
logInfoMessage "image name: $IMAGE_NAME"

setupAwsCredentials() {

    echo "=== Setting up AWS credentials ==="

    if [ "${ASSUME_ROLE:-false}" == "true" ]; then

        if [ -z "${ACCOUNT_ID:-}" ] || [ -z "${ROLE_NAME:-}" ]; then
            logErrorMessage "ACCOUNT_ID and ROLE_NAME must be set when ASSUME_ROLE=true"
            exit 1
        fi

        ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

        logInfoMessage "Assuming AWS IAM role: ${ROLE_ARN}"

        getAssumeRole "$ROLE_ARN"

    else

        logInfoMessage "ASSUME_ROLE is not set to 'true', using AWS profile"

        if [ -z "${AWS_PROFILE:-}" ]; then
            logErrorMessage "AWS_PROFILE must be set when ASSUME_ROLE=false"
            exit 1
        fi
        export AWS_PROFILE="${AWS_PROFILE}"
        # Get credentials from AWS profile
        export AWS_ACCESS_KEY_ID="$(aws configure get aws_access_key_id --profile "$AWS_PROFILE")"
        export AWS_SECRET_ACCESS_KEY="$(aws configure get aws_secret_access_key --profile "$AWS_PROFILE")"
        export AWS_SESSION_TOKEN="$(aws configure get aws_session_token --profile "$AWS_PROFILE" 2>/dev/null || true)"

        # Get region from AWS profile
        export AWS_REGION="$(aws configure get region --profile "$AWS_PROFILE")"
        export AWS_DEFAULT_REGION="$AWS_REGION"

        logInfoMessage "AWS credentials loaded from profile: ${AWS_PROFILE}"
    fi

    if [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
        logErrorMessage "AWS_ACCESS_KEY_ID is not set"
        exit 1
    fi

    if [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
        logErrorMessage "AWS_SECRET_ACCESS_KEY is not set"
        exit 1
    fi

    if [ -z "${AWS_REGION:-}" ]; then
        logErrorMessage "AWS_REGION is not set"
        exit 1
    fi

    if ! AWS_IDENTITY=$(aws sts get-caller-identity 2>/tmp/aws_error.log); then
        logErrorMessage "AWS authentication failed"
        cat /tmp/aws_error.log
        exit 1
    fi

    AWS_ACCOUNT_ID=$(echo "$AWS_IDENTITY" | jq -r '.Account')
    AWS_ARN=$(echo "$AWS_IDENTITY" | jq -r '.Arn')

    logInfoMessage "AWS authentication successful"
    logInfoMessage "AWS Account ID: ${AWS_ACCOUNT_ID}"
    logInfoMessage "AWS Region: ${AWS_REGION}"
    logInfoMessage "AWS ARN: ${AWS_ARN}"

    logInfoMessage "=== AWS credentials setup completed ==="
}

  if [[ "${ASSUME_ROLE:-false}" == "true" || -n "${AWS_PROFILE:-}" ]]; then
      setupAwsCredentials
  else
      logInfoMessage "Neither ASSUME_ROLE=true nor AWS_PROFILE is set, skipping AWS credential setup"
  fi


IFS=',' read -ra SERVICE_LIST <<< "${SERVICES}"

for SERVICE in "${SERVICE_LIST[@]}"; do

  SERVICE="$(echo "${SERVICE}" | xargs)"

  if [[ -z "${SERVICE}" ]]; then
    logErrorMessage "Empty service name found in SERVICES='${SERVICES}'"
    exit 1
  fi

  SERVICE_UPPER="$(echo "${SERVICE}" | tr '[:lower:]-' '[:upper:]_')"

  LOG_GROUP="/ecs/${SERVICE}"

  declare "${SERVICE_UPPER}_LOG_GROUP=${LOG_GROUP}"

  echo "${SERVICE_UPPER}_LOG_GROUP=${LOG_GROUP}"
  export "${SERVICE_UPPER}_LOG_GROUP=${LOG_GROUP}"

done

logInfoMessage "=== Prepare: capture live ECS Task Definitions ==="

IFS=',' read -ra SERVICE_LIST <<< "${SERVICES}"

for SERVICE in "${SERVICE_LIST[@]}"; do

  # Remove accidental spaces
  SERVICE="$(echo "${SERVICE}" | xargs)"

  if [[ -z "${SERVICE}" ]]; then
    logErrorMessage "Empty service name found in SERVICES='${SERVICES}'"
    exit 1
  fi

  SERVICE_UPPER="$(echo "${SERVICE}" | tr '[:lower:]' '[:upper:]')"

  logInfoMessage "================================================"
  logInfoMessage "Fetching task definition for service: ${SERVICE}"
  logInfoMessage "================================================"

  if ! TASK_DEF_ARN="$(aws ecs describe-services \
      --cluster "${ECS_CLUSTER}" \
      --services "${SERVICE}" \
      --query 'services[0].taskDefinition' \
      --output text)"; then

    logErrorMessage "Failed to get task definition for service: ${SERVICE}"
    exit 1
  fi

  # Validate AWS returned a usable task definition
  if [[ -z "${TASK_DEF_ARN}" || "${TASK_DEF_ARN}" == "None" ]]; then
    logErrorMessage "No task definition found for service: ${SERVICE}"
    exit 1
  fi
  

SERVICE_UPPER="$(echo "${SERVICE}" | tr '[:lower:]-' '[:upper:]_')"

  declare "PREVIOUS_${SERVICE_UPPER}_TASK_DEF=${TASK_DEF_ARN}"

  logInfoMessage "PREVIOUS_${SERVICE_UPPER}_TASK_DEF=${TASK_DEF_ARN}"
  export "PREVIOUS_${SERVICE_UPPER}_TASK_DEF=${TASK_DEF_ARN}"

done

logInfoMessage "======================================================="
logInfoMessage "All ECS service task definitions fetched successfully"
logInfoMessage "======================================================="

if [[ "${SCHEDULER}" == "true" ]]; then

    if [[ -z "${SCHEDULER_RULES}" ]]; then
    logErrorMessage "Scheduler rules are required"
    exit 1
    fi

  IFS=',' read -ra SCHEDULER_LIST <<< "${SCHEDULER_RULES}"

  for RULE in "${SCHEDULER_LIST[@]}"; do

    RULE="$(echo "${RULE}" | xargs)"

    if [[ -z "${RULE}" ]]; then
      logErrorMessage "Empty scheduler rule found"
      exit 1
    fi

    logInfoMessage "=========================================="
    logInfoMessage "Processing scheduler rule: ${RULE}"
    logInfoMessage "=========================================="

    # Get scheduler targets
    if ! aws events list-targets-by-rule \
        --rule "${RULE}" \
        --output json > "current-targets-${RULE}.json"; then

      logErrorMessage "Failed to get targets for scheduler rule: ${RULE}"
      saveTaskStatus 1 ${ACTIVITY_SUB_TASK_CODE}
      exit 1
    fi

    # Validate Targets
    if ! jq -e '.Targets' "current-targets-${RULE}.json" >/dev/null; then
      logErrorMessage "Targets not found for scheduler rule: ${RULE}"
      saveTaskStatus 1 ${ACTIVITY_SUB_TASK_CODE}
      exit 1
    fi

    # ecs-rollback.sh expects a JSON array of Targets
    jq '.Targets' \
      "current-targets-${RULE}.json" \
      > "current-targets-array-${RULE}.json"

    # Get previous ECS task definition
    if ! TASK_DEF_ARN="$(jq -er \
        '.Targets[0].EcsParameters.TaskDefinitionArn' \
        "current-targets-${RULE}.json")"; then

      logErrorMessage "TaskDefinitionArn not found for scheduler rule: ${RULE}"
      saveTaskStatus 1 ${ACTIVITY_SUB_TASK_CODE}
      exit 1
    fi

    SCHEDULER_NAME="${SCHEDULER_RULES}"
    SCHEDULER_UPPER="$(echo "${SCHEDULER_NAME}" | tr '[:lower:]-' '[:upper:]_')"

    declare "PREVIOUS_${SCHEDULER_UPPER}_TASK_DEF=${TASK_DEF_ARN}"

    logInfoMessage "PREVIOUS_${SCHEDULER_UPPER}_TASK_DEF=${TASK_DEF_ARN}"
    export "PREVIOUS_${SCHEDULER_UPPER}_TASK_DEF=${TASK_DEF_ARN}"

  done

else
  logInfoMessage "SCHEDULER=false — skipping scheduler processing"
fi


if [[ "${TARGET_GROUP}" == "true" ]]; then

  IFS=',' read -ra SERVICE_LIST <<< "${TARGET_GROUP_SERVICES}"

  for SERVICE in "${SERVICE_LIST[@]}"; do

    SERVICE="$(echo "${SERVICE}" | xargs)"
    SERVICE_UPPER="$(echo "${SERVICE}" | tr '[:lower:]-' '[:upper:]_')"

    logInfoMessage "=========================================="
    logInfoMessage "Processing target group for service: ${SERVICE}"
    logInfoMessage "=========================================="

    if ! TARGET_GROUP_ARN="$(aws ecs describe-services \
        --cluster "${ECS_CLUSTER}" \
        --services "${SERVICE}" \
        --query 'services[0].loadBalancers[0].targetGroupArn' \
        --output text)"; then

      logErrorMessage "Failed to get target group ARN for ${SERVICE}"
      saveTaskStatus 1 ${ACTIVITY_SUB_TASK_CODE}
      exit 1
    fi

    if [[ -z "${TARGET_GROUP_ARN}" || "${TARGET_GROUP_ARN}" == "None" ]]; then
      logErrorMessage "Target group ARN not found for ${SERVICE}"
      saveTaskStatus 1 ${ACTIVITY_SUB_TASK_CODE}
      exit 1
    fi

    declare "${SERVICE_UPPER}_TARGET_GROUP_ARN=${TARGET_GROUP_ARN}"

    logInfoMessage "${SERVICE_UPPER}_TARGET_GROUP_ARN=${TARGET_GROUP_ARN}"
    export "${SERVICE_UPPER}_TARGET_GROUP_ARN=${TARGET_GROUP_ARN}"

  done

fi


if [[ "${APP_URL}" == "true" ]]; then

  IFS=',' read -ra SERVICE_LIST <<< "${APP_URL_SERVICES}"

  for SERVICE in "${SERVICE_LIST[@]}"; do

    SERVICE="$(echo "${SERVICE}" | xargs)"

    if [[ -z "${SERVICE}" ]]; then
      logErrorMessage "Empty service name found"
      exit 1
    fi

    SERVICE_UPPER="$(echo "${SERVICE}" | tr '[:lower:]-' '[:upper:]_')"

    # Get corresponding task definition variable
    TASK_DEF_VAR="PREVIOUS_${SERVICE_UPPER}_TASK_DEF"

    if [[ -z "${!TASK_DEF_VAR:-}" ]]; then
      logErrorMessage "${TASK_DEF_VAR} is not set"
      exit 1
    fi

    TASK_DEF="${!TASK_DEF_VAR}"

    logInfoMessage "=========================================="
    logInfoMessage "Getting APP_URL for service: ${SERVICE}"
    logInfoMessage "Task Definition: ${TASK_DEF}"
    logInfoMessage "=========================================="

    if ! SERVICE_APP_URL="$(aws ecs describe-task-definition \
        --task-definition "${TASK_DEF}" \
        --query "taskDefinition.containerDefinitions[0].environment[?name=='APP_URL'].value" \
        --output text)"; then

      logErrorMessage "Failed to get APP_URL for service: ${SERVICE}"
      saveTaskStatus 1 ${ACTIVITY_SUB_TASK_CODE}
      exit 1
    fi

    if [[ -z "${SERVICE_APP_URL}" || "${SERVICE_APP_URL}" == "None" ]]; then
      logErrorMessage "APP_URL not found for service: ${SERVICE}"
      saveTaskStatus 1 ${ACTIVITY_SUB_TASK_CODE}
      exit 1
    fi

    declare "${SERVICE_UPPER}_APP_URL=${SERVICE_APP_URL}"

    logInfoMessage "${SERVICE_UPPER}_APP_URL=${SERVICE_APP_URL}"

  done

else
  logInfoMessage "APP_URL=false — skipping APP_URL processing"
fi

if [[ "${SQS_QUEUE}" == "true" ]]; then


  IFS=',' read -ra SERVICE_LIST <<< "${QUEUE_SERVICES}"

  for SERVICE in "${SERVICE_LIST[@]}"; do

    SERVICE="$(echo "${SERVICE}" | xargs)"

    if [[ -z "${SERVICE}" ]]; then
      logErrorMessage "ERROR: Empty service name found"
      exit 1
    fi

    SERVICE_UPPER="$(echo "${SERVICE}" | tr '[:lower:]-' '[:upper:]_')"

    TASK_DEF_VAR="PREVIOUS_${SERVICE_UPPER}_TASK_DEF"

    if [[ -z "${!TASK_DEF_VAR:-}" ]]; then
      logErrorMessage "${TASK_DEF_VAR} is not set"
      exit 1
    fi

    TASK_DEF="${!TASK_DEF_VAR}"

    logInfoMessage "=========================================="
    logInfoMessage "Getting SQS_QUEUE for service: ${SERVICE}"
    logInfoMessage "Task Definition: ${TASK_DEF}"
    logInfoMessage "=========================================="
    
    if ! SERVICE_QUEUE_NAME="$(aws ecs describe-task-definition \
        --task-definition "${TASK_DEF}" \
        --query "taskDefinition.containerDefinitions[0].environment[?name=='SQS_QUEUE'].value" \
        --output text)"; then

      logErrorMessage "Failed to get SQS_QUEUE for service: ${SERVICE}"
      saveTaskStatus 1 ${ACTIVITY_SUB_TASK_CODE}
      exit 1
    fi

    if [[ -z "${SERVICE_QUEUE_NAME}" || "${SERVICE_QUEUE_NAME}" == "None" ]]; then
      logErrorMessage "SQS_QUEUE not found for service: ${SERVICE}"
      saveTaskStatus 1 ${ACTIVITY_SUB_TASK_CODE}
      exit 1
    fi

    declare "${SERVICE_UPPER}_QUEUE_NAME=${SERVICE_QUEUE_NAME}"

    logInfoMessage "${SERVICE_UPPER}_QUEUE_NAME=${SERVICE_QUEUE_NAME}"
    export "${SERVICE_UPPER}_QUEUE_NAME=${SERVICE_QUEUE_NAME}"

  done

else
  logInfoMessage "QUEUE_NAME=false — skipping SQS_QUEUE processing"
fi



if [[ "${REGISTER_NEW_TD}" == "true" ]]; then

  logInfoMessage "=== prepare: register new task definitions ==="
  logInfoMessage "Services for new task definition: ${REGISTER_NEW_TD_SERVICES}"

  IFS=',' read -ra SERVICE_LIST <<< "${REGISTER_NEW_TD_SERVICES}"

  for SERVICE in "${SERVICE_LIST[@]}"; do

    SERVICE="$(echo "${SERVICE}" | xargs)"

    if [[ -z "${SERVICE}" ]]; then
      logErrorMessage "Empty service name found in REGISTER_NEW_TD_SERVICES='${REGISTER_NEW_TD_SERVICES}'"
      saveTaskStatus 1 ${ACTIVITY_SUB_TASK_CODE}
      exit 1
    fi

    SERVICE_UPPER="$(echo "${SERVICE}" | tr '[:lower:]-' '[:upper:]_')"


    # --------------------------------------------------
    # Previous task definition
    # PREVIOUS_EXPERTSCLUB_UAT_WEB_TASK_DEF
    # --------------------------------------------------

    PREVIOUS_TASK_DEF_VAR="PREVIOUS_${SERVICE_UPPER}_TASK_DEF"

    logInfoMessage "Fetching previous task definition for service: ${SERVICE}"

    if [[ -z "${!PREVIOUS_TASK_DEF_VAR:-}" ]]; then
      logErrorMessage "=========================================="
      logErrorMessage "${PREVIOUS_TASK_DEF_VAR} task definition is not set for service: ${SERVICE}"
      exit 1
    fi

    PREVIOUS_TASK_DEF="${!PREVIOUS_TASK_DEF_VAR}"

    logInfoMessage "Previous task definition for service ${SERVICE}: ${PREVIOUS_TASK_DEF}"
    logInfoMessage "Latest image name for service ${SERVICE}: ${LATEST_IMAGE_NAME}"

    OUTPUT_FILE="${SERVICE}-taskdef-new.json"

    logInfoMessage "=========================================="
    logInfoMessage "Registering new task definition"
    logInfoMessage "Service        : ${SERVICE}"
    logInfoMessage "Previous TD    : ${PREVIOUS_TASK_DEF}"
    logInfoMessage "Latest Image   : ${LATEST_IMAGE_NAME}"
    logInfoMessage "Output File    : ${OUTPUT_FILE}"
    logInfoMessage "=========================================="

    if ! NEW_TASK_DEF_ARN="$("${SCRIPT_DIR}/ecs-task-definition.sh" \
        "${PREVIOUS_TASK_DEF}" \
        "${LATEST_IMAGE_NAME}" \
        "${OUTPUT_FILE}")"; then

      logErrorMessage "Failed to register new task definition for service: ${SERVICE}"
      saveTaskStatus 1 ${ACTIVITY_SUB_TASK_CODE}
      exit 1
    fi

    if [[ -z "${NEW_TASK_DEF_ARN}" || "${NEW_TASK_DEF_ARN}" == "None" ]]; then
      logErrorMessage "Empty task definition ARN returned for service: ${SERVICE}"
      saveTaskStatus 1 ${ACTIVITY_SUB_TASK_CODE}
      exit 1
    fi

    declare "${SERVICE_UPPER}_TASK_DEF_ARN=${NEW_TASK_DEF_ARN}"

    logInfoMessage "${SERVICE_UPPER}_TASK_DEF_ARN=${NEW_TASK_DEF_ARN}"

  done

  logInfoMessage "======================================================="
  logInfoMessage "All ECS task definitions registered successfully"
  logInfoMessage "======================================================="

else

  logInfoMessage "REGISTER_NEW_TD=false — skipping new task definition registration"

fi
logInfoMessage "=== prepare: generating deploy.env ==="

# Start with common variables
{
  printf '%s\n' \
    "LATEST_IMAGE_NAME=${LATEST_IMAGE_NAME}" \
    "DEPLOY_STARTED_AT=${DEPLOY_STARTED_AT}" \
    "DEPLOY_MUTATED=false"
} > deploy.env


# ============================================================
# ECS service variables
# ============================================================

IFS=',' read -ra SERVICE_LIST <<< "${SERVICES}"

for SERVICE in "${SERVICE_LIST[@]}"; do

  SERVICE="$(echo "${SERVICE}" | xargs)"

  if [[ -z "${SERVICE}" ]]; then
    logErrorMessage "Empty service name found while generating deploy.env"
    saveTaskStatus 1 ${ACTIVITY_SUB_TASK_CODE}
    exit 1
  fi

  SERVICE_UPPER="$(echo "${SERVICE}" | tr '[:lower:]-' '[:upper:]_')"

  # Previous task definition
  VAR_NAME="PREVIOUS_${SERVICE_UPPER}_TASK_DEF"

  if [[ -n "${!VAR_NAME:-}" ]]; then
    printf '%s\n' "${VAR_NAME}=${!VAR_NAME}" >> deploy.env
  fi

  # New task definition
  VAR_NAME="${SERVICE_UPPER}_TASK_DEF_ARN"

  if [[ -n "${!VAR_NAME:-}" ]]; then
    printf '%s\n' "${VAR_NAME}=${!VAR_NAME}" >> deploy.env
  fi

  # Image
  VAR_NAME="${SERVICE_UPPER}_IMAGE"

  if [[ -n "${!VAR_NAME:-}" ]]; then
    printf '%s\n' "${VAR_NAME}=${!VAR_NAME}" >> deploy.env
  fi

  # Target Group
  VAR_NAME="${SERVICE_UPPER}_TARGET_GROUP_ARN"

  if [[ -n "${!VAR_NAME:-}" ]]; then
    printf '%s\n' "${VAR_NAME}=${!VAR_NAME}" >> deploy.env
  fi

  # APP_URL
  VAR_NAME="${SERVICE_UPPER}_APP_URL"

  if [[ -n "${!VAR_NAME:-}" ]]; then
    printf '%s\n' "${VAR_NAME}=${!VAR_NAME}" >> deploy.env
  fi

  # Queue
  VAR_NAME="${SERVICE_UPPER}_QUEUE_NAME"

  if [[ -n "${!VAR_NAME:-}" ]]; then
    printf '%s\n' "${VAR_NAME}=${!VAR_NAME}" >> deploy.env
  fi

done


# ============================================================
# Scheduler variables
# ============================================================

if [[ "${SCHEDULER}" == "true" ]]; then

  IFS=',' read -ra SCHEDULER_LIST <<< "${SCHEDULER_RULES}"

  for RULE in "${SCHEDULER_LIST[@]}"; do

    RULE="$(echo "${RULE}" | xargs)"

    [[ -z "${RULE}" ]] && continue

    SCHEDULER_UPPER="$(echo "${SCHEDULER_NAME}" | tr '[:lower:]-' '[:upper:]_')"

    # Previous scheduler task definition
    VAR_NAME="PREVIOUS_${SCHEDULER_UPPER}_TASK_DEF"

    if [[ -n "${!VAR_NAME:-}" ]]; then
      printf '%s\n' "${VAR_NAME}=${!VAR_NAME}" >> deploy.env
    fi
    VAR_NAME="${SCHEDULER_UPPER}_TASK_DEF_ARN"

    if [[ -n "${!VAR_NAME:-}" ]]; then
        printf '%s\n' "${VAR_NAME}=${!VAR_NAME}" >> deploy.env
    fi

    # Scheduler target files
    printf '%s\n' \
      "SCHEDULER_RULE_${SCHEDULER_UPPER}=${RULE}" \
      "CURRENT_TARGETS_FILE_${SCHEDULER_UPPER}=current-targets-${RULE}.json" \
      "CURRENT_TARGETS_ARRAY_FILE_${SCHEDULER_UPPER}=current-targets-array-${RULE}.json" \
      >> deploy.env

  done

fi


# ============================================================
# Optional common paths / names
# ============================================================

[[ -n "${CRON_FAMILY:-}" ]] && \
  printf '%s\n' "CRON_FAMILY=${CRON_FAMILY}" >> deploy.env

[[ -n "${WEB_LOG_GROUP:-}" ]] && \
  printf '%s\n' "WEB_LOG_GROUP=${WEB_LOG_GROUP}" >> deploy.env

[[ -n "${WORKER_LOG_GROUP:-}" ]] && \
  printf '%s\n' "WORKER_LOG_GROUP=${WORKER_LOG_GROUP}" >> deploy.env


# ============================================================
# Display generated variables
# ============================================================

logInfoMessage "=== Generated deploy.env ==="
cat deploy.env
logInfoMessage "============================"

printf '%s\n' "DEPLOY_MUTATED=false" > mutation.env

logInfoMessage "prepare PASSED"
logInfoMessage "IMAGE_TAG=${LATEST_IMAGE_NAME}"
logInfoMessage "DEPLOY_MUTATED=false"


TASK_STATUS=$?
saveTaskStatus ${TASK_STATUS} ${ACTIVITY_SUB_TASK_CODE}
