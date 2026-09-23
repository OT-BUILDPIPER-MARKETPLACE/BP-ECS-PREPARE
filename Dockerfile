FROM alpine
RUN apk add --no-cache --upgrade bash
RUN apk add jq
COPY build.sh .

ADD BP-BASE-SHELL-STEPS /opt/buildpiper/shell-functions/


ENV SLEEP_DURATION 5s
ENV ACTIVITY_SUB_TASK_CODE REPLACE_IT
ENV VALIDATION_FAILURE_ACTION WARNING

ENTRYPOINT [ "./build.sh" ]
