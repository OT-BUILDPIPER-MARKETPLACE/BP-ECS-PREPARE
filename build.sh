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

cd "${CODEBASE_LOCATION}"

sleep "$SLEEP_DURATION"

LATEST_IMAGE_NAME="${IMAGE_NAME}:${DEPLOY_TAG}"
export LATEST_IMAGE_NAME="${IMAGE_NAME}:${DEPLOY_TAG}"

DEPLOY_STARTED_AT="$(date +%s)"

logInfoMessage "latest image name: $LATEST_IMAGE_NAME"
logInfoMessage "image name: $IMAGE_NAME"

add_event "DEPLOYMENT_PREPARE" "STARTED" "DEPLOYMENT_PREPARE_STARTED" "Deployment preparation started for image: ${LATEST_IMAGE_NAME}"

setupAwsCredentials() {

    logInfoMessage "=== Setting up AWS credentials ==="

    add_event "AWS_CREDENTIAL_SETUP" "STARTED" "AWS_CREDENTIAL_SETUP_STARTED" "Starting AWS credentials setup"

    if [ "${ASSUME_ROLE:-false}" == "true" ]; then

        add_event "AWS_CREDENTIAL_SETUP" "STARTED" "AWS_ROLE_ASSUMPTION_STARTED" "Starting AWS IAM role assumption"

        if [ -z "${ACCOUNT_ID:-}" ] || [ -z "${ROLE_NAME:-}" ]; then

            logErrorMessage "ACCOUNT_ID and ROLE_NAME must be set when ASSUME_ROLE=true"
            add_event "AWS_CREDENTIAL_SETUP" "FAILED" "AWS_ROLE_CONFIGURATION_INVALID" "ACCOUNT_ID and ROLE_NAME must be set when ASSUME_ROLE=true"
            exit 1
        fi

        ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

        logInfoMessage "Assuming AWS IAM role: ${ROLE_ARN}"

        if ! getAssumeRole "$ROLE_ARN"; then

            logErrorMessage "Failed to assume AWS IAM role: ${ROLE_ARN}"
            add_event "AWS_CREDENTIAL_SETUP" "FAILED" "AWS_ROLE_ASSUMPTION_FAILED" "Failed to assume AWS IAM role"
            exit 1
        fi

        add_event "AWS_CREDENTIAL_SETUP" "SUCCESS" "AWS_ROLE_ASSUMPTION_SUCCESS" "AWS IAM role assumed successfully"

    else

        logInfoMessage "ASSUME_ROLE is not set to 'true', using AWS profile"

        add_event "AWS_CREDENTIAL_SETUP" "STARTED" "AWS_PROFILE_AUTHENTICATION_STARTED" "Starting AWS profile based authentication"

        if [ -z "${AWS_PROFILE:-}" ]; then

            logErrorMessage "AWS_PROFILE must be set when ASSUME_ROLE=false"
            add_event "AWS_CREDENTIAL_SETUP" "FAILED" "AWS_PROFILE_MISSING" "AWS_PROFILE must be set when ASSUME_ROLE=false"
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

        add_event "AWS_CREDENTIAL_SETUP" "SUCCESS" "AWS_PROFILE_CREDENTIALS_LOADED" "AWS credentials loaded successfully from configured AWS profile"

    fi

    if [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then

        logErrorMessage "AWS_ACCESS_KEY_ID is not set"
        add_event "AWS_CREDENTIAL_SETUP" "FAILED" "AWS_ACCESS_KEY_ID_MISSING" "AWS_ACCESS_KEY_ID is not set"
        exit 1
    fi

    if [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then

        logErrorMessage "AWS_SECRET_ACCESS_KEY is not set"
        add_event "AWS_CREDENTIAL_SETUP" "FAILED" "AWS_SECRET_ACCESS_KEY_MISSING" "AWS_SECRET_ACCESS_KEY is not set"
        exit 1
    fi

    if [ -z "${AWS_REGION:-}" ]; then

        logErrorMessage "AWS_REGION is not set"
        add_event "AWS_CREDENTIAL_SETUP" "FAILED" "AWS_REGION_MISSING" "AWS_REGION is not set"
        exit 1
    fi

    add_event "AWS_AUTHENTICATION" "STARTED" "AWS_AUTHENTICATION_STARTED" "Validating AWS authentication using STS"

    if ! AWS_IDENTITY=$(aws sts get-caller-identity 2>/tmp/aws_error.log); then

        logErrorMessage "AWS authentication failed"
        cat /tmp/aws_error.log
        add_event "AWS_AUTHENTICATION" "FAILED" "AWS_AUTHENTICATION_FAILED" "AWS authentication failed during STS get-caller-identity validation"
        exit 1
    fi


    AWS_ACCOUNT_ID=$(echo "$AWS_IDENTITY" | jq -r '.Account')
    AWS_ARN=$(echo "$AWS_IDENTITY" | jq -r '.Arn')

    logInfoMessage "AWS authentication successful"
    logInfoMessage "AWS Account ID: ${AWS_ACCOUNT_ID}"
    logInfoMessage "AWS Region: ${AWS_REGION}"
    logInfoMessage "AWS ARN: ${AWS_ARN}"

    add_event "AWS_AUTHENTICATION" "SUCCESS" "AWS_AUTHENTICATION_SUCCESS" "AWS credentials configured and authentication successful"
    logInfoMessage "=== AWS credentials setup completed ==="
}


# ============================================================
# RUN AWS CREDENTIAL SETUP
# ============================================================

if [[ "${ASSUME_ROLE:-false}" == "true" || -n "${AWS_PROFILE:-}" ]]; then

    add_event "AWS_CREDENTIAL_SETUP_FUNCTION" "STARTED" "AWS_CREDENTIAL_SETUP_FUNCTION_STARTED" "AWS credentials setup function execution started"

    if setupAwsCredentials; then
        add_event "AWS_CREDENTIAL_SETUP_FUNCTION" "SUCCESS" "AWS_CREDENTIAL_SETUP_FUNCTION_COMPLETED" "AWS credentials setup function completed successfully"

    else
        add_event "AWS_CREDENTIAL_SETUP_FUNCTION" "FAILED" "AWS_CREDENTIAL_SETUP_FUNCTION_FAILED" "AWS credentials setup function failed"
        exit 1
    fi

else

    logInfoMessage "Neither ASSUME_ROLE=true nor AWS_PROFILE is set, skipping AWS credential setup"
    add_event "AWS_CREDENTIAL_SETUP_FUNCTION" "SKIPPED" "AWS_CREDENTIAL_SETUP_SKIPPED" "AWS credential setup skipped because neither ASSUME_ROLE=true nor AWS_PROFILE is set"
fi


IFS=',' read -ra SERVICE_LIST <<< "${SERVICES}"

for SERVICE in "${SERVICE_LIST[@]}"; do

  SERVICE="$(echo "${SERVICE}" | xargs)"

  add_event "LOG_GROUP_SETUP for ${SERVICE}" "STARTED" "LOG_GROUP_SETUP_STARTED" "Starting log group setup for service: ${SERVICE}"

  if [[ -z "${SERVICE}" ]]; then

    logErrorMessage "Empty service name found in SERVICES='${SERVICES}'"

    add_event "SERVICE_NAME_VALIDATION for ${SERVICE}" "FAILED" "SERVICE_NAME_EMPTY" "Empty service name found in SERVICES"

    add_event "LOG_GROUP_SETUP for ${SERVICE}" "FAILED" "LOG_GROUP_SETUP_FAILED" "Failed to set up log group because service name is empty"

    exit 1
  fi

  add_event "SERVICE_NAME_VALIDATION for ${SERVICE}" "SUCCESS" "SERVICE_NAME_VALID" "Service name validation passed for log group setup: ${SERVICE}"

  SERVICE_UPPER="$(echo "${SERVICE}" | tr '[:lower:]-' '[:upper:]_')"

  LOG_GROUP="/ecs/${SERVICE}"

  declare "${SERVICE_UPPER}_LOG_GROUP=${LOG_GROUP}"

  logInfoMessage "${SERVICE_UPPER}_LOG_GROUP=${LOG_GROUP}"

  export "${SERVICE_UPPER}_LOG_GROUP=${LOG_GROUP}"

  add_event "LOG_GROUP_SETUP for ${SERVICE}" "SUCCESS" "LOG_GROUP_SETUP_COMPLETED" "Log group setup completed for service: ${SERVICE}"

done


logInfoMessage "=== Prepare: capture live ECS Task Definitions ==="

IFS=',' read -ra SERVICE_LIST <<< "${SERVICES}"

for SERVICE in "${SERVICE_LIST[@]}"; do

  SERVICE="$(echo "${SERVICE}" | xargs)"

  add_event "TASK_DEFINITION_FETCH for ${SERVICE}" "STARTED" "SERVICE_TASK_DEFINITION_FETCH_STARTED" "Fetching task definition for service: ${SERVICE}"

  if [[ -z "${SERVICE}" ]]; then

    logErrorMessage "Empty service name found in SERVICES='${SERVICES}'"
    add_event "SERVICE_NAME_VALIDATION for ${SERVICE}" "FAILED" "SERVICE_NAME_EMPTY" "Empty service name found in SERVICES for task definition setup"
    add_event "TASK_DEFINITION_FETCH for ${SERVICE}" "FAILED" "TASK_DEFINITION_FETCH_FAILED" "Failed to fetch task definition because service name is empty"
    exit 1
  fi

  add_event "SERVICE_NAME_VALIDATION for ${SERVICE}" "SUCCESS" "SERVICE_NAME_VALID" "Service name validation passed for task definition fetch: ${SERVICE}"

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

    add_event "TASK_DEFINITION_FETCH for ${SERVICE}" "FAILED" "TASK_DEFINITION_FETCH_FAILED" "Failed to fetch task definition for service: ${SERVICE}"

    exit 1
  fi

  if [[ -z "${TASK_DEF_ARN}" || "${TASK_DEF_ARN}" == "None" ]]; then

    logErrorMessage "No task definition found for service: ${SERVICE}"
    add_event "TASK_DEFINITION_FETCH for ${SERVICE}" "FAILED" "TASK_DEFINITION_NOT_FOUND" "No task definition found for service: ${SERVICE}"
    exit 1
  fi

  SERVICE_UPPER="$(echo "${SERVICE}" | tr '[:lower:]-' '[:upper:]_')"

  declare "PREVIOUS_${SERVICE_UPPER}_TASK_DEF=${TASK_DEF_ARN}"

  logInfoMessage "PREVIOUS_${SERVICE_UPPER}_TASK_DEF=${TASK_DEF_ARN}"
  export "PREVIOUS_${SERVICE_UPPER}_TASK_DEF=${TASK_DEF_ARN}"
  add_event "TASK_DEFINITION_FETCH for ${SERVICE}" "SUCCESS" "TASK_DEFINITION_FETCH_SUCCESS" "Task definition fetched successfully for service: ${SERVICE}"

done

logInfoMessage "======================================================="
logInfoMessage "All ECS service task definitions fetched successfully"
logInfoMessage "======================================================="


if [[ "${SCHEDULER}" == "true" ]]; then

  add_event "SCHEDULER_PROCESSING" "STARTED" "SCHEDULER_PROCESSING_STARTED" "Scheduler processing started"

  if [[ -z "${SCHEDULER_RULES}" ]]; then

    logErrorMessage "Scheduler rules are required"
    add_event "SCHEDULER_PROCESSING" "FAILED" "SCHEDULER_RULES_MISSING" "Scheduler rules are required when SCHEDULER=true"
    exit 1
  fi

  IFS=',' read -ra SCHEDULER_LIST <<< "${SCHEDULER_RULES}"

  for RULE in "${SCHEDULER_LIST[@]}"; do

    RULE="$(echo "${RULE}" | xargs)"

    add_event "SCHEDULER_TARGETS_FETCH for ${RULE}" "STARTED" "SCHEDULER_TARGETS_FETCH_STARTED" "Scheduler targets fetch started for rule: ${RULE}"

    if [[ -z "${RULE}" ]]; then

      logErrorMessage "Empty scheduler rule found"
      add_event "SCHEDULER_RULE_VALIDATION for ${RULE}" "FAILED" "SCHEDULER_RULE_EMPTY" "Empty scheduler rule found in SCHEDULER_RULES"
      add_event "SCHEDULER_TARGETS_FETCH for ${RULE}" "FAILED" "SCHEDULER_TARGETS_FETCH_FAILED" "Scheduler targets fetch failed because scheduler rule is empty"
      add_event "SCHEDULER_PROCESSING" "FAILED" "SCHEDULER_PROCESSING_FAILED" "Scheduler processing failed"
      exit 1
    fi

    add_event "SCHEDULER_RULE_VALIDATION for ${RULE}" "SUCCESS" "SCHEDULER_RULE_VALID" "Scheduler rule validation passed for rule: ${RULE}"

    logInfoMessage "=========================================="
    logInfoMessage "Processing scheduler rule: ${RULE}"
    logInfoMessage "=========================================="

    if ! aws events list-targets-by-rule \
        --rule "${RULE}" \
        --output json > "current-targets-${RULE}.json"; then

      logErrorMessage "Failed to get targets for scheduler rule: ${RULE}"
      saveTaskStatus 1 ${ACTIVITY_SUB_TASK_CODE}
      add_event "SCHEDULER_TARGETS_FETCH for ${RULE}" "FAILED" "SCHEDULER_TARGETS_FETCH_FAILED" "Failed to fetch scheduler targets for rule: ${RULE}"
      add_event "SCHEDULER_PROCESSING" "FAILED" "SCHEDULER_PROCESSING_FAILED" "Scheduler processing failed"
      exit 1
    fi

    add_event "SCHEDULER_TARGETS_FETCH for ${RULE}" "SUCCESS" "SCHEDULER_TARGETS_FETCH_SUCCESS" "Scheduler targets fetched successfully for rule: ${RULE}"

    if ! jq -e '.Targets' "current-targets-${RULE}.json" >/dev/null; then

      logErrorMessage "Targets not found for scheduler rule: ${RULE}"

      saveTaskStatus 1 ${ACTIVITY_SUB_TASK_CODE}

      add_event "SCHEDULER_TARGETS_VALIDATION for ${RULE}" "FAILED" "SCHEDULER_TARGETS_NOT_FOUND" "Targets not found for scheduler rule: ${RULE}"
      add_event "SCHEDULER_PROCESSING" "FAILED" "SCHEDULER_PROCESSING_FAILED" "Scheduler processing failed"
      exit 1
    fi

     add_event "SCHEDULER_TARGETS_VALIDATION for ${RULE}" "SUCCESS" "SCHEDULER_TARGETS_FOUND" "Targets found for scheduler rule: ${RULE} and stored in current-targets-${RULE}.json"


    if ! jq '.Targets' \
      "current-targets-${RULE}.json" \
      > "current-targets-array-${RULE}.json"; then

      logErrorMessage "Failed to create scheduler target array for rule: ${RULE}"

      add_event "SCHEDULER_TARGET_ARRAY for ${RULE}" "FAILED" "SCHEDULER_TARGET_ARRAY_CREATION_FAILED" "Failed to create scheduler target array for rule: ${RULE}"
      add_event "SCHEDULER_PROCESSING" "FAILED" "SCHEDULER_PROCESSING_FAILED" "Scheduler processing failed"
      exit 1
    fi

    add_event "SCHEDULER_TARGET_ARRAY for ${RULE}" "SUCCESS" "SCHEDULER_TARGET_ARRAY_CREATED" "Scheduler target array created for rule: ${RULE}"


    # --------------------------------------------------------
    # Get Previous ECS Task Definition
    # --------------------------------------------------------

    if ! TASK_DEF_ARN="$(jq -er \
        '.Targets[0].EcsParameters.TaskDefinitionArn' \
        "current-targets-${RULE}.json")"; then

      logErrorMessage "TaskDefinitionArn not found for scheduler rule: ${RULE}"

      saveTaskStatus 1 ${ACTIVITY_SUB_TASK_CODE}

      add_event "SCHEDULER_TASK_DEFINITION_FETCH for ${RULE}" "FAILED" "SCHEDULER_TASK_DEFINITION_NOT_FOUND" "TaskDefinitionArn not found for scheduler rule: ${RULE}"
      add_event "SCHEDULER_PROCESSING" "FAILED" "SCHEDULER_PROCESSING_FAILED" "Scheduler processing failed"
      exit 1
    fi

    SCHEDULER_NAME="${RULE}"

    SCHEDULER_UPPER="$(echo "${SCHEDULER_NAME}" | tr '[:lower:]-' '[:upper:]_')"

    declare "PREVIOUS_${SCHEDULER_UPPER}_TASK_DEF=${TASK_DEF_ARN}"

    logInfoMessage "PREVIOUS_${SCHEDULER_UPPER}_TASK_DEF=${TASK_DEF_ARN}"

    export "PREVIOUS_${SCHEDULER_UPPER}_TASK_DEF=${TASK_DEF_ARN}"

    add_event "SCHEDULER_TASK_DEFINITION_FETCH for ${RULE}" "SUCCESS" "SCHEDULER_TASK_DEFINITION_FETCH_SUCCESS" "Previous task definition fetched successfully for scheduler rule: ${RULE}"

  done

  add_event "SCHEDULER_PROCESSING" "SUCCESS" "SCHEDULER_PROCESSING_COMPLETED" "Scheduler processing completed successfully"

else

  logInfoMessage "SCHEDULER=false — skipping scheduler processing"

  add_event "SCHEDULER_PROCESSING" "SKIPPED" "SCHEDULER_PROCESSING_SKIPPED" "Scheduler processing skipped because SCHEDULER=false"
fi


if [[ "${TARGET_GROUP}" == "true" ]]; then

  add_event "TARGET_GROUP_PROCESSING" "STARTED" "TARGET_GROUP_PROCESSING_STARTED" "Target group processing started"

  IFS=',' read -ra SERVICE_LIST <<< "${TARGET_GROUP_SERVICES}"

  for SERVICE in "${SERVICE_LIST[@]}"; do

    SERVICE="$(echo "${SERVICE}" | xargs)"

    if [[ -z "${SERVICE}" ]]; then

      logErrorMessage "Empty target group service name found"

      add_event "TARGET_GROUP_PROCESSING" "FAILED" "TARGET_GROUP_SERVICE_EMPTY" "Empty service name found in TARGET_GROUP_SERVICES"
      exit 1
    fi

    SERVICE_UPPER="$(echo "${SERVICE}" | tr '[:lower:]-' '[:upper:]_')"

    add_event "TARGET_GROUP_FETCH for ${SERVICE}" "STARTED" "TARGET_GROUP_FETCH_STARTED" "Fetching target group ARN for service: ${SERVICE}"

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

      add_event "TARGET_GROUP_FETCH for ${SERVICE}" "FAILED" "TARGET_GROUP_FETCH_FAILED" "Failed to get target group ARN for service: ${SERVICE}"
      add_event "TARGET_GROUP_PROCESSING" "FAILED" "TARGET_GROUP_PROCESSING_FAILED" "Target group processing Failed"
      exit 1
    fi

    if [[ -z "${TARGET_GROUP_ARN}" || "${TARGET_GROUP_ARN}" == "None" ]]; then

      logErrorMessage "Target group ARN not found for ${SERVICE}"

      saveTaskStatus 1 ${ACTIVITY_SUB_TASK_CODE}

      add_event "TARGET_GROUP_FETCH for ${SERVICE}" "FAILED" "TARGET_GROUP_NOT_FOUND" "Target group ARN not found for service: ${SERVICE}"
      add_event "TARGET_GROUP_PROCESSING" "FAILED" "TARGET_GROUP_PROCESSING_FAILED" "Target group processing Failed"
      exit 1
    fi

    declare "${SERVICE_UPPER}_TARGET_GROUP_ARN=${TARGET_GROUP_ARN}"

    logInfoMessage "${SERVICE_UPPER}_TARGET_GROUP_ARN=${TARGET_GROUP_ARN}"

    export "${SERVICE_UPPER}_TARGET_GROUP_ARN=${TARGET_GROUP_ARN}"

    add_event "TARGET_GROUP_FETCH for ${SERVICE}" "SUCCESS" "TARGET_GROUP_FETCH_SUCCESS" "Target group ARN fetched successfully for service: ${SERVICE}"

  done

  add_event "TARGET_GROUP_PROCESSING" "SUCCESS" "TARGET_GROUP_PROCESSING_COMPLETED" "Target group processing completed successfully"

else

  logInfoMessage "TARGET_GROUP=false — skipping target group processing"

  add_event "TARGET_GROUP_PROCESSING" "SKIPPED" "TARGET_GROUP_PROCESSING_SKIPPED" "Target group processing skipped because TARGET_GROUP=false"
fi


# ============================================================
# APP URL PROCESSING
# ============================================================

if [[ "${APP_URL}" == "true" ]]; then

  add_event "APP_URL_PROCESSING" "STARTED" "APP_URL_PROCESSING_STARTED" "APP_URL processing started"

  IFS=',' read -ra SERVICE_LIST <<< "${APP_URL_SERVICES}"

  for SERVICE in "${SERVICE_LIST[@]}"; do

    SERVICE="$(echo "${SERVICE}" | xargs)"

    if [[ -z "${SERVICE}" ]]; then

      logErrorMessage "Empty service name found"

      add_event "APP_URL_PROCESSING" "FAILED" "APP_URL_SERVICE_EMPTY" "Empty service name found in APP_URL_SERVICES"

      exit 1
    fi

    SERVICE_UPPER="$(echo "${SERVICE}" | tr '[:lower:]-' '[:upper:]_')"

    TASK_DEF_VAR="PREVIOUS_${SERVICE_UPPER}_TASK_DEF"

    if [[ -z "${!TASK_DEF_VAR:-}" ]]; then

      logErrorMessage "${TASK_DEF_VAR} is not set"
      add_event "APP_URL_PROCESSING" "FAILED" "APP_URL_TASK_DEFINITION_MISSING" "${TASK_DEF_VAR} is not set for service: ${SERVICE}"
      exit 1
    fi

    TASK_DEF="${!TASK_DEF_VAR}"

    add_event "APP_URL_FETCH" "STARTED" "APP_URL_FETCH_STARTED" "Fetching APP_URL for service: ${SERVICE}"

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
      add_event "APP_URL_FETCH" "FAILED" "APP_URL_FETCH_FAILED" "Failed to get APP_URL for service: ${SERVICE}"
      exit 1
    fi

    if [[ -z "${SERVICE_APP_URL}" || "${SERVICE_APP_URL}" == "None" ]]; then

      logErrorMessage "APP_URL not found for service: ${SERVICE}"
      saveTaskStatus 1 ${ACTIVITY_SUB_TASK_CODE}
      add_event "APP_URL_FETCH" "FAILED" "APP_URL_NOT_FOUND" "APP_URL not found for service: ${SERVICE}"

      exit 1
    fi

    declare "${SERVICE_UPPER}_APP_URL=${SERVICE_APP_URL}"
    logInfoMessage "${SERVICE_UPPER}_APP_URL=${SERVICE_APP_URL}"
    add_event "APP_URL_FETCH" "SUCCESS" "APP_URL_FETCH_SUCCESS" "APP_URL fetched successfully for service: ${SERVICE}"

  done

  add_event "APP_URL_PROCESSING" "SUCCESS" "APP_URL_PROCESSING_COMPLETED" "APP_URL processing completed successfully"
else

  logInfoMessage "APP_URL=false — skipping APP_URL processing"
  add_event "APP_URL_PROCESSING" "SKIPPED" "APP_URL_PROCESSING_SKIPPED" "APP_URL processing skipped because APP_URL=false"
fi


# ============================================================
# SQS QUEUE PROCESSING
# ============================================================

if [[ "${SQS_QUEUE}" == "true" ]]; then

  add_event "SQS_QUEUE_PROCESSING" "STARTED" "SQS_QUEUE_PROCESSING_STARTED" "SQS queue processing started"

  IFS=',' read -ra SERVICE_LIST <<< "${QUEUE_SERVICES}"

  for SERVICE in "${SERVICE_LIST[@]}"; do

    SERVICE="$(echo "${SERVICE}" | xargs)"

    if [[ -z "${SERVICE}" ]]; then

      logErrorMessage "Empty service name found"
      add_event "SQS_QUEUE_PROCESSING" "FAILED" "SQS_QUEUE_SERVICE_EMPTY" "Empty service name found in QUEUE_SERVICES"
      exit 1
    fi

    SERVICE_UPPER="$(echo "${SERVICE}" | tr '[:lower:]-' '[:upper:]_')"

    TASK_DEF_VAR="PREVIOUS_${SERVICE_UPPER}_TASK_DEF"

    if [[ -z "${!TASK_DEF_VAR:-}" ]]; then

      logErrorMessage "${TASK_DEF_VAR} is not set"
      add_event "SQS_QUEUE_PROCESSING" "FAILED" "SQS_QUEUE_TASK_DEFINITION_MISSING" "${TASK_DEF_VAR} is not set for service: ${SERVICE}"
      exit 1
    fi

    TASK_DEF="${!TASK_DEF_VAR}"

    add_event \
      "SQS_QUEUE_FETCH" \
      "STARTED" \
      "SQS_QUEUE_FETCH_STARTED" \
      "Fetching SQS queue for service: ${SERVICE}"

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
      add_event "SQS_QUEUE_FETCH" "FAILED" "SQS_QUEUE_FETCH_FAILED" "Failed to get SQS_QUEUE for service: ${SERVICE}"
      exit 1
    fi

    if [[ -z "${SERVICE_QUEUE_NAME}" || "${SERVICE_QUEUE_NAME}" == "None" ]]; then

      logErrorMessage "SQS_QUEUE not found for service: ${SERVICE}"
      saveTaskStatus 1 ${ACTIVITY_SUB_TASK_CODE}
      add_event "SQS_QUEUE_FETCH" "FAILED" "SQS_QUEUE_NOT_FOUND" "SQS_QUEUE not found for service: ${SERVICE}"

      exit 1
    fi

    declare "${SERVICE_UPPER}_QUEUE_NAME=${SERVICE_QUEUE_NAME}"
    logInfoMessage "${SERVICE_UPPER}_QUEUE_NAME=${SERVICE_QUEUE_NAME}"
    export "${SERVICE_UPPER}_QUEUE_NAME=${SERVICE_QUEUE_NAME}"
    add_event "SQS_QUEUE_FETCH" "SUCCESS" "SQS_QUEUE_FETCH_SUCCESS" "SQS queue fetched successfully for service: ${SERVICE}"

  done

  add_event "SQS_QUEUE_PROCESSING" "SUCCESS" "SQS_QUEUE_PROCESSING_COMPLETED" "SQS queue processing completed successfully"

else

  logInfoMessage "QUEUE_NAME=false — skipping SQS_QUEUE processing"
  add_event "SQS_QUEUE_PROCESSING" "SKIPPED" "SQS_QUEUE_PROCESSING_SKIPPED" "SQS queue processing skipped because SQS_QUEUE=false"

fi


if [[ "${REGISTER_NEW_TD}" == "true" ]]; then

  logInfoMessage "=== prepare: register new task definitions ==="
  logInfoMessage "Services for new task definition: ${REGISTER_NEW_TD_SERVICES}"

  add_event "TASK_DEFINITION_REGISTRATION" "STARTED" "TASK_DEFINITION_REGISTRATION_STARTED" "New ECS task definition registration started"

  IFS=',' read -ra SERVICE_LIST <<< "${REGISTER_NEW_TD_SERVICES}"

  for SERVICE in "${SERVICE_LIST[@]}"; do

    SERVICE="$(echo "${SERVICE}" | xargs)"

    if [[ -z "${SERVICE}" ]]; then

      logErrorMessage "Empty service name found in REGISTER_NEW_TD_SERVICES='${REGISTER_NEW_TD_SERVICES}'"

      saveTaskStatus 1 ${ACTIVITY_SUB_TASK_CODE}

      add_event "TASK_DEFINITION_REGISTRATION for ${SERVICE}" "FAILED" "TASK_DEFINITION_SERVICE_EMPTY" "Empty service name found in REGISTER_NEW_TD_SERVICES"
      add_event "TASK_DEFINITION_REGISTRATION" "FAILED" "ALL_TASK_DEFINITIONS_REGISTERED_FAILED" "ECS task definitions registered Failed"

      exit 1
    fi

    SERVICE_UPPER="$(echo "${SERVICE}" | tr '[:lower:]-' '[:upper:]_')"

    PREVIOUS_TASK_DEF_VAR="PREVIOUS_${SERVICE_UPPER}_TASK_DEF"

    logInfoMessage "Fetching previous task definition for service: ${SERVICE}"

    if [[ -z "${!PREVIOUS_TASK_DEF_VAR:-}" ]]; then

      logErrorMessage "=========================================="
      logErrorMessage "${PREVIOUS_TASK_DEF_VAR} task definition is not set for service: ${SERVICE}"

      add_event "TASK_DEFINITION_REGISTRATION for ${SERVICE}" "FAILED" "PREVIOUS_TASK_DEFINITION_MISSING" "${PREVIOUS_TASK_DEF_VAR} is not set for service: ${SERVICE}"
      add_event "TASK_DEFINITION_REGISTRATION" "FAILED" "ALL_TASK_DEFINITIONS_REGISTERED_FAILED" "ECS task definitions registered Failed"

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

    add_event "TASK_DEFINITION_REGISTRATION for ${SERVICE}" "STARTED" "SERVICE_TASK_DEFINITION_REGISTRATION_STARTED" "Registering new task definition for service: ${SERVICE}"

    if ! NEW_TASK_DEF_ARN="$("${SCRIPT_DIR}/ecs-task-definition.sh" \
        "${PREVIOUS_TASK_DEF}" \
        "${LATEST_IMAGE_NAME}" \
        "${OUTPUT_FILE}")"; then

      logErrorMessage "Failed to register new task definition for service: ${SERVICE}"

      saveTaskStatus 1 ${ACTIVITY_SUB_TASK_CODE}

      add_event "TASK_DEFINITION_REGISTRATION for ${SERVICE}" "FAILED" "SERVICE_TASK_DEFINITION_REGISTRATION_FAILED" "Failed to register new task definition for service: ${SERVICE}"
      add_event "TASK_DEFINITION_REGISTRATION" "FAILED" "ALL_TASK_DEFINITIONS_REGISTERED_FAILED" "ECS task definitions registered Failed"

      exit 1
    fi

    if [[ -z "${NEW_TASK_DEF_ARN}" || "${NEW_TASK_DEF_ARN}" == "None" ]]; then

      logErrorMessage "Empty task definition ARN returned for service: ${SERVICE}"

      saveTaskStatus 1 ${ACTIVITY_SUB_TASK_CODE}

      add_event "TASK_DEFINITION_REGISTRATION for ${SERVICE}" "FAILED" "TASK_DEFINITION_ARN_EMPTY" "Empty task definition ARN returned for service: ${SERVICE}"
      add_event "TASK_DEFINITION_REGISTRATION" "FAILED" "ALL_TASK_DEFINITIONS_REGISTERED_FAILED" "ECS task definitions registered Failed"
      exit 1
    fi

    declare "${SERVICE_UPPER}_TASK_DEF_ARN=${NEW_TASK_DEF_ARN}"

    logInfoMessage "${SERVICE_UPPER}_TASK_DEF_ARN=${NEW_TASK_DEF_ARN}"
    add_event "TASK_DEFINITION_REGISTRATION for ${SERVICE}" "SUCCESS" "SERVICE_TASK_DEFINITION_REGISTRATION_SUCCESS" "New task definition registered successfully for service: ${SERVICE}"

  done

  logInfoMessage "======================================================="
  logInfoMessage "All ECS task definitions registered successfully"
  logInfoMessage "======================================================="

  add_event "TASK_DEFINITION_REGISTRATION" "SUCCESS" "ALL_TASK_DEFINITIONS_REGISTERED" "All ECS task definitions registered successfully"

else

  logInfoMessage "REGISTER_NEW_TD=false — skipping new task definition registration"
  add_event "TASK_DEFINITION_REGISTRATION" "SKIPPED" "TASK_DEFINITION_REGISTRATION_SKIPPED" "New task definition registration skipped because REGISTER_NEW_TD=false"
fi


logInfoMessage "=== prepare: generating deploy.env ==="

add_event "DEPLOY_ENV_GENERATION" "STARTED" "DEPLOY_ENV_GENERATION_STARTED" "Generating deployment environment file"


{
  printf '%s\n' \
    "LATEST_IMAGE_NAME=${LATEST_IMAGE_NAME}" \
    "DEPLOY_STARTED_AT=${DEPLOY_STARTED_AT}" \
    "DEPLOY_MUTATED=false"
} > deploy.env


IFS=',' read -ra SERVICE_LIST <<< "${SERVICES}"

for SERVICE in "${SERVICE_LIST[@]}"; do

  SERVICE="$(echo "${SERVICE}" | xargs)"

  if [[ -z "${SERVICE}" ]]; then

    logErrorMessage "Empty service name found while generating deploy.env"

    saveTaskStatus 1 ${ACTIVITY_SUB_TASK_CODE}
    add_event "DEPLOY_ENV_GENERATION" "FAILED" "DEPLOY_ENV_SERVICE_EMPTY" "Empty service name found while generating deploy.env"
    exit 1
  fi

  SERVICE_UPPER="$(echo "${SERVICE}" | tr '[:lower:]-' '[:upper:]_')"

  VAR_NAME="PREVIOUS_${SERVICE_UPPER}_TASK_DEF"

  if [[ -n "${!VAR_NAME:-}" ]]; then
    printf '%s\n' "${VAR_NAME}=${!VAR_NAME}" >> deploy.env
  fi

  VAR_NAME="${SERVICE_UPPER}_TASK_DEF_ARN"

  if [[ -n "${!VAR_NAME:-}" ]]; then
    printf '%s\n' "${VAR_NAME}=${!VAR_NAME}" >> deploy.env
  fi
  VAR_NAME="${SERVICE_UPPER}_IMAGE"

  if [[ -n "${!VAR_NAME:-}" ]]; then
    printf '%s\n' "${VAR_NAME}=${!VAR_NAME}" >> deploy.env
  fi

  VAR_NAME="${SERVICE_UPPER}_TARGET_GROUP_ARN"

  if [[ -n "${!VAR_NAME:-}" ]]; then
    printf '%s\n' "${VAR_NAME}=${!VAR_NAME}" >> deploy.env
  fi

  VAR_NAME="${SERVICE_UPPER}_APP_URL"

  if [[ -n "${!VAR_NAME:-}" ]]; then
    printf '%s\n' "${VAR_NAME}=${!VAR_NAME}" >> deploy.env
  fi

  VAR_NAME="${SERVICE_UPPER}_QUEUE_NAME"

  if [[ -n "${!VAR_NAME:-}" ]]; then
    printf '%s\n' "${VAR_NAME}=${!VAR_NAME}" >> deploy.env
  fi

done

if [[ "${SCHEDULER}" == "true" ]]; then

  IFS=',' read -ra SCHEDULER_LIST <<< "${SCHEDULER_RULES}"

  for RULE in "${SCHEDULER_LIST[@]}"; do

    RULE="$(echo "${RULE}" | xargs)"

    [[ -z "${RULE}" ]] && continue

    SCHEDULER_UPPER="$(echo "${RULE}" | tr '[:lower:]-' '[:upper:]_')"

    VAR_NAME="PREVIOUS_${SCHEDULER_UPPER}_TASK_DEF"

    if [[ -n "${!VAR_NAME:-}" ]]; then
      printf '%s\n' "${VAR_NAME}=${!VAR_NAME}" >> deploy.env
    fi

    VAR_NAME="${SCHEDULER_UPPER}_TASK_DEF_ARN"

    if [[ -n "${!VAR_NAME:-}" ]]; then
      printf '%s\n' "${VAR_NAME}=${!VAR_NAME}" >> deploy.env
    fi

    printf '%s\n' \
      "SCHEDULER_RULE_${SCHEDULER_UPPER}=${RULE}" \
      "CURRENT_TARGETS_FILE_${SCHEDULER_UPPER}=current-targets-${RULE}.json" \
      "CURRENT_TARGETS_ARRAY_FILE_${SCHEDULER_UPPER}=current-targets-array-${RULE}.json" \
      >> deploy.env

  done

fi


[[ -n "${CRON_FAMILY:-}" ]] && \
  printf '%s\n' "CRON_FAMILY=${CRON_FAMILY}" >> deploy.env

[[ -n "${WEB_LOG_GROUP:-}" ]] && \
  printf '%s\n' "WEB_LOG_GROUP=${WEB_LOG_GROUP}" >> deploy.env

[[ -n "${WORKER_LOG_GROUP:-}" ]] && \
  printf '%s\n' "WORKER_LOG_GROUP=${WORKER_LOG_GROUP}" >> deploy.env


logInfoMessage "=== Generated deploy.env ==="

cat deploy.env

logInfoMessage "============================"

add_event "DEPLOY_ENV_GENERATION" "SUCCESS" "DEPLOY_ENV_GENERATION_COMPLETED" "deploy.env generated successfully"

if printf '%s\n' "DEPLOY_MUTATED=false" > mutation.env; then
  add_event "MUTATION_ENV_GENERATION" "SUCCESS" "MUTATION_ENV_GENERATION_COMPLETED" "mutation.env generated successfully"

else
  add_event "MUTATION_ENV_GENERATION" "FAILED" "MUTATION_ENV_GENERATION_FAILED" "Failed to generate mutation.env"
  exit 1
fi

logInfoMessage "prepare PASSED"
logInfoMessage "IMAGE_TAG=${LATEST_IMAGE_NAME}"
logInfoMessage "DEPLOY_MUTATED=false"

add_event "DEPLOYMENT_PREPARE" "SUCCESS" "DEPLOYMENT_PREPARE_COMPLETED" "Deployment preparation completed successfully"


TASK_STATUS=$?

saveTaskStatus ${TASK_STATUS} ${ACTIVITY_SUB_TASK_CODE}
