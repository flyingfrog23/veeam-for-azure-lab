#!/usr/bin/env bash
set -euo pipefail

# Deploy baseline lab (infra/main.bicep) and optionally the VBMA Marketplace Managed App.
#
# Usage:
#   export SUBSCRIPTION_ID=...
#   export ADMIN_PASSWORD=...
#   ./deploy.sh
#
# Optional:
#   DEPLOY_VBMA=true
#   VBMA_MARKETPLACE_FILE=marketplace/vbazure.marketplace.json
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${REPO_ROOT}/.env"

# ---- Baseline lab ----
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:?SUBSCRIPTION_ID is required}"
LOCATION="${LOCATION:-westeurope}"
RG_NAME="${RG_NAME:-veeam-lab-rg}"
PREFIX="${PREFIX:-veeam-lab}"

ADMIN_USERNAME="${ADMIN_USERNAME:-veeamadmin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:?ADMIN_PASSWORD is required}"
ALLOWED_RDP_SOURCE="${ALLOWED_RDP_SOURCE:-0.0.0.0/0}"

# ---- Marketplace (optional) ----
DEPLOY_VBMA="${DEPLOY_VBMA:-false}"
VBMA_APP_NAME="${VBMA_APP_NAME:-veeam-vbma-lab}"
VBMA_MRG_NAME="${VBMA_MRG_NAME:-veeam-vbma-mrg}"
VBMA_MARKETPLACE_FILE="${VBMA_MARKETPLACE_FILE:-${REPO_ROOT}/marketplace/vbazure.marketplace.json}"

az account set --subscription "${SUBSCRIPTION_ID}"

echo "==> Creating resource group: ${RG_NAME} (${LOCATION})"
az group create -n "${RG_NAME}" -l "${LOCATION}" 1>/dev/null

echo "==> Deploying baseline lab (Bicep)"
az deployment group create \
  -g "${RG_NAME}" \
  -n "baseline-$(date +%Y%m%d%H%M%S)" \
  -f "${REPO_ROOT}/infra/main.bicep" \
  -p prefix="${PREFIX}" \
     location="${LOCATION}" \
     adminUsername="${ADMIN_USERNAME}" \
     adminPassword="${ADMIN_PASSWORD}" \
     allowedRdpSource="${ALLOWED_RDP_SOURCE}" \
  1>/dev/null

echo "==> Baseline deployed."

if [[ "${DEPLOY_VBMA}" != "true" ]]; then
  echo "==> Skipping VBMA Marketplace deployment (set DEPLOY_VBMA=true to enable)."
  exit 0
fi

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required when DEPLOY_VBMA=true" >&2; exit 1; }
[[ -f "${VBMA_MARKETPLACE_FILE}" ]] || { echo "ERROR: Missing ${VBMA_MARKETPLACE_FILE}" >&2; exit 1; }

PUBLISHER="$(jq -r '.publisher' "${VBMA_MARKETPLACE_FILE}")"
OFFER="$(jq -r '.offer' "${VBMA_MARKETPLACE_FILE}")"
PLAN="$(jq -r '.plan' "${VBMA_MARKETPLACE_FILE}")"
PLAN_VERSION="$(jq -r '.planVersion' "${VBMA_MARKETPLACE_FILE}")"
APP_PARAMS_JSON="$(jq -c '.appParameters // {}' "${VBMA_MARKETPLACE_FILE}")"

# Managed resource group must NOT already exist (Azure will create/own it)
if [[ "$(az group exists -n "${VBMA_MRG_NAME}")" == "true" ]]; then
  echo "ERROR: Managed resource group '${VBMA_MRG_NAME}' already exists." >&2
  echo "Delete it or set VBMA_MRG_NAME to a new name, then re-run." >&2
  exit 1
fi

MRG_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${VBMA_MRG_NAME}"

echo "==> Accepting Marketplace terms (best-effort)"
az term accept --publisher "${PUBLISHER}" --product "${OFFER}" --plan "${PLAN}" 1>/dev/null 2>/dev/null || \
  az vm image terms accept --publisher "${PUBLISHER}" --offer "${OFFER}" --plan "${PLAN}" 1>/dev/null 2>/dev/null || true

APP_PARAMS_FILE=""
trap 'rm -f "${APP_PARAMS_FILE}" 2>/dev/null || true' EXIT

if [[ "${APP_PARAMS_JSON}" != "{}" ]]; then
  APP_PARAMS_FILE="$(mktemp -t vbma-appparams-XXXXXX.json)"
  echo "${APP_PARAMS_JSON}" > "${APP_PARAMS_FILE}"
fi

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
