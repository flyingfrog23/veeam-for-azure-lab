#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Paths
# -----------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# -----------------------------
# Load .env
# -----------------------------
ENV_FILE="${REPO_ROOT}/.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

# -----------------------------
# Required / defaults
# -----------------------------
: "${SUBSCRIPTION_ID:?SUBSCRIPTION_ID is required}"
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD is required}"

LOCATION="${LOCATION:-westeurope}"
RG_NAME="${RG_NAME:-veeam-lab-rg}"
PREFIX="${PREFIX:-veeam-lab}"
ADMIN_USERNAME="${ADMIN_USERNAME:-veeamadmin}"
ALLOWED_RDP_SOURCE="${ALLOWED_RDP_SOURCE:-0.0.0.0/0}"

DEPLOY_VBMA="${DEPLOY_VBMA:-false}"
VBMA_APP_NAME="${VBMA_APP_NAME:-veeam-vbma-lab}"
VBMA_MRG_NAME_BASE="${VBMA_MRG_NAME:-veeam-vbma-mrg}"
VBMA_MARKETPLACE_FILE="${VBMA_MARKETPLACE_FILE:-${REPO_ROOT}/marketplace/vbazure.marketplace.json}"

# Resolve relative path
if [[ "${VBMA_MARKETPLACE_FILE}" != /* ]]; then
  VBMA_MARKETPLACE_FILE="${REPO_ROOT}/${VBMA_MARKETPLACE_FILE}"
fi

# -----------------------------
# Azure context
# -----------------------------
az account set --subscription "${SUBSCRIPTION_ID}"

# Use the *actual* active subscription ID
SUBSCRIPTION_ID="$(az account show --query id -o tsv)"

# -----------------------------
# Baseline RG
# -----------------------------
echo "==> Creating resource group: ${RG_NAME} (${LOCATION})"
az group create \
  --name "${RG_NAME}" \
  --location "${LOCATION}" \
  1>/dev/null

echo "==> Deploying baseline lab (Bicep)"
az deployment group create \
  --resource-group "${RG_NAME}" \
  --name "baseline-$(date +%Y%m%d%H%M%S)" \
  --template-file "${REPO_ROOT}/infra/main.bicep" \
  --parameters \
    prefix="${PREFIX}" \
    location="${LOCATION}" \
    adminUsername="${ADMIN_USERNAME}" \
    adminPassword="${ADMIN_PASSWORD}" \
    allowedRdpSource="${ALLOWED_RDP_SOURCE}" \
  1>/dev/null

echo "==> Baseline deployed."

# -----------------------------
# Marketplace optional
# -----------------------------
if [[ "${DEPLOY_VBMA}" != "true" ]]; then
  echo "==> Skipping VBMA Marketplace deployment."
  exit 0
fi

command -v jq >/dev/null 2>&1 || {
  echo "ERROR: jq is required when DEPLOY_VBMA=true" >&2
  exit 1
}

[[ -f "${VBMA_MARKETPLACE_FILE}" ]] || {
  echo "ERROR: Missing ${VBMA_MARKETPLACE_FILE}" >&2
  exit 1
}

# -----------------------------
# Read marketplace metadata
# -----------------------------
PUBLISHER="$(jq -r '.publisher' "${VBMA_MARKETPLACE_FILE}")"
OFFER="$(jq -r '.offer' "${VBMA_MARKETPLACE_FILE}")"
PLAN="$(jq -r '.plan' "${VBMA_MARKETPLACE_FILE}")"
PLAN_VERSION="$(jq -r '.planVersion' "${VBMA_MARKETPLACE_FILE}")"
APP_PARAMS_JSON="$(jq -c '.appParameters // {}' "${VBMA_MARKETPLACE_FILE}")"

# -----------------------------
# Managed Resource Group (MUST be unique, MUST NOT exist)
# -----------------------------
TS="$(date +%Y%m%d%H%M%S)"
VBMA_MRG_NAME="${VBMA_MRG_NAME_BASE}-${TS}"
MRG_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${VBMA_MRG_NAME}"

# Hard validation (prevents silent bullshit)
[[ -n "${VBMA_MRG_NAME}" ]]
[[ -n "${MRG_ID}" ]]

echo "==> Using managed resource group: ${VBMA_MRG_NAME}"
echo "==> Managed RG ID:"
echo "${MRG_ID}" | cat -v

# -----------------------------
# Accept marketplace terms (best effort)
# -----------------------------
echo "==> Accepting Marketplace terms (best-effort)"
az term accept \
  --publisher "${PUBLISHER}" \
  --product "${OFFER}" \
  --plan "${PLAN}" \
  1>/dev/null 2>/dev/null || true

# -----------------------------
# App parameters (optional)
# -----------------------------
APP_PARAMS_FILE=""
trap 'rm -f "${APP_PARAMS_FILE}" 2>/dev/null || true' EXIT

if [[ "${APP_PARAMS_JSON}" != "{}" ]]; then
  APP_PARAMS_FILE="$(mktemp)"
  echo "${APP_PARAMS_JSON}" > "${APP_PARAMS_FILE}"
fi

# -----------------------------
# Deploy managed app
# -----------------------------
echo "==> Deploying VBMA managed app: ${VBMA_APP_NAME}"

if [[ -n "${APP_PARAMS_FILE}" ]]; then
  az managedapp create \
    --resource-group "${RG_NAME}" \
    --name "${VBMA_APP_NAME}" \
    --location "${LOCATION}" \
    --kind MarketPlace \
    --managed-rg-id "${MRG_ID}" \
    --plan-name "${PLAN}" \
    --plan-product "${OFFER}" \
    --plan-publisher "${PUBLISHER}" \
    --plan-version "${PLAN_VERSION}" \
    --parameters @"${APP_PARAMS_FILE}"
else
  az managedapp create \
    --resource-group "${RG_NAME}" \
    --name "${VBMA_APP_NAME}" \
    --location "${LOCATION}" \
    --kind MarketPlace \
    --managed-rg-id "${MRG_ID}" \
    --plan-name "${PLAN}" \
    --plan-product "${OFFER}" \
    --plan-publisher "${PUBLISHER}" \
    --plan-version "${PLAN_VERSION}"
fi

echo "==> VBMA deployment submitted."
