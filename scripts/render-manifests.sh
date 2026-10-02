#!/usr/bin/env bash
set -euo pipefail

: "${ECR_REPOSITORY:?ECR_REPOSITORY is required}"
: "${APP_HOSTNAME:?APP_HOSTNAME is required}"
: "${ACM_CERTIFICATE_ARN:?ACM_CERTIFICATE_ARN is required}"

kubectl kustomize clusters/production | \
  sed \
    -e "s|\${ECR_REPOSITORY}|${ECR_REPOSITORY}|g" \
    -e "s|\${APP_HOSTNAME}|${APP_HOSTNAME}|g" \
    -e "s|\${ACM_CERTIFICATE_ARN}|${ACM_CERTIFICATE_ARN}|g"
