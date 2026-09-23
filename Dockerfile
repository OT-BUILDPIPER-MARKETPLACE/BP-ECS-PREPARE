FROM ubuntu:24.04

USER root
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    bash \
    jq \
    python3 \
    python3-pip \
    git && \
    pip3 install --no-cache-dir --break-system-packages awscli && \
    rm -rf /var/lib/apt/lists/*

# Create non-root user
RUN addgroup -g 65522 buildpiper && \
    adduser -D -u 65522 -G buildpiper -h /home/buildpiper buildpiper

# Copy buildpiper shell functions
COPY --chown=buildpiper:buildpiper BP-BASE-SHELL-STEPS /opt/buildpiper/shell-functions/

# Recreate all directories present in the referenced Dockerfile
RUN mkdir -p \
    /src/reports \
    /bp/data \
    /bp/scripts \
    /bp/logs \
    /opt/buildpiper/shell-functions \
    /opt/buildpiper/data \
    /usr/local/bin \
    /etc/timezone \
    /opt/python_versions \
    /opt/jdk \
    /opt/maven \
    /app/venv \
    /tmp && \
    chown -R buildpiper:buildpiper \
    /src /bp /opt /usr/local/bin /tmp /app /home/buildpiper

WORKDIR /app

COPY build.sh .
ADD BP-BASE-SHELL-STEPS /opt/buildpiper/shell-functions

ENV IAM_ROLE_TO_ASSUME=""
ENV VALIDATION_FAILURE_ACTION=WARNING
ENV ACTIVITY_SUB_TASK_CODE=BP-ECS-PREPARE
ENV TASK_FAMILY=""
ENV REGION=""
ENV IMAGE=""
ENV CLUSTER=""
ENV SLEEP_DURATION="0s"

# Switch to non-root user
USER buildpiper
WORKDIR /home/buildpiper

# Copy build script
COPY --chown=buildpiper:buildpiper build.sh .
COPY --chown=buildpiper:buildpiper ecs-task-definition.sh .

# Make script executable
RUN chmod +x /home/buildpiper/build.sh
RUN chmod +x /home/buildpiper/ecs-task-definition.sh

# Entry point
ENTRYPOINT ["./build.sh"]