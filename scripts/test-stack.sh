#!/usr/bin/env bash
# Aplica o template numa conta de teste, valida o comportamento da role
# read-only (com e sem External ID) e destrói o stack ao final.
#
# Uso:
#   AWS_PROFILE=<profile-de-teste> ./scripts/test-stack.sh
#
# Requer credenciais AWS de coletor (nuvemcash-collector) exportadas via
# COLLECTOR_ACCESS_KEY_ID / COLLECTOR_SECRET_ACCESS_KEY para o passo de
# assume-role — sem elas, o script só aplica/valida outputs e destrói.

set -euo pipefail

STACK_NAME="${STACK_NAME:-nuvemcash-collector-test}"
REGION="${AWS_REGION:-us-east-1}"
TEMPLATE_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/template.yaml"
EXTERNAL_ID="${EXTERNAL_ID:-$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)}"

echo "==> Deploy do stack ${STACK_NAME} (região ${REGION})"
aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE_FILE" \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides "ExternalId=${EXTERNAL_ID}" \
  --region "$REGION"

echo "==> Outputs"
aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --region "$REGION" \
  --query 'Stacks[0].Outputs' \
  --output table

ROLE_ARN=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='RoleArn'].OutputValue" --output text)
BUCKET_NAME=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='BucketName'].OutputValue" --output text)
EXPORT_ARN=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
  --query "Stacks[0].Outputs[?OutputKey=='ExportArn'].OutputValue" --output text)

echo "==> Export criado"
aws bcm-data-exports get-export --export-arn "$EXPORT_ARN" --region "$REGION" \
  --query 'Export.{Name:Name,Status:ExportStatus}' --output table 2>/dev/null || \
  aws bcm-data-exports get-export --export-arn "$EXPORT_ARN" --region "$REGION"

if [[ -n "${COLLECTOR_ACCESS_KEY_ID:-}" && -n "${COLLECTOR_SECRET_ACCESS_KEY:-}" ]]; then
  echo "==> Assume-role SEM External ID (deve falhar com AccessDenied)"
  if env -u AWS_PROFILE \
      AWS_ACCESS_KEY_ID="$COLLECTOR_ACCESS_KEY_ID" \
      AWS_SECRET_ACCESS_KEY="$COLLECTOR_SECRET_ACCESS_KEY" \
      aws sts assume-role --role-arn "$ROLE_ARN" --role-session-name test-no-eid \
      --region "$REGION" >/dev/null 2>&1; then
    echo "FALHA: assume-role sem External ID foi aceito (esperado AccessDenied)"
    exit 1
  fi
  echo "OK: rejeitado como esperado"

  echo "==> Assume-role COM External ID (deve passar)"
  env -u AWS_PROFILE \
    AWS_ACCESS_KEY_ID="$COLLECTOR_ACCESS_KEY_ID" \
    AWS_SECRET_ACCESS_KEY="$COLLECTOR_SECRET_ACCESS_KEY" \
    aws sts assume-role --role-arn "$ROLE_ARN" --role-session-name test-with-eid \
    --external-id "$EXTERNAL_ID" --region "$REGION" >/dev/null
  echo "OK: aceito como esperado"
else
  echo "==> COLLECTOR_ACCESS_KEY_ID/SECRET não definidos — pulando teste de assume-role"
fi

echo "==> Esvaziando o bucket antes de destruir"
aws s3 rm "s3://${BUCKET_NAME}" --recursive --region "$REGION" || true

echo "==> Destruindo o stack"
aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"
aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION"
echo "==> Stack destruído"
