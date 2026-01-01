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
: "${RG_NAME:?RG_NAME is required}"
: "${VBMA_MARKETPLACE_FILE:?VBMA_MARKETPLACE_FILE is required}"

LOCATION="${LOCATION:-westeurope}"
VBMA_APP_NAME="${VBMA_APP_NAME:-veeam-vbma-lab}"
VBMA_MRG_NAME_BASE="${VBMA_MRG_NAME:-veeam-vbma-mrg}"

# Resolve marketplace file path
if [[ "${VBMA_MARKETPLACE_FILE}" != /* ]]; then
  VBMA_MARKETPLACE_FILE="${REPO_ROOT}/${VBMA_MARKETPLACE_FILE}"
fi

# -----------------------------
# Azure context
# -----------------------------
az account set --subscription "${SUBSCRIPTION_ID}"
SUBSCRIPTION_ID="$(az account show --query id -o tsv)"

# -----------------------------
# Read marketplace metadata
# -----------------------------
command -v jq >/dev/null 2>&1 || {
  echo "ERROR: jq is required" >&2
  exit 1
}

[[ -f "${VBMA_MARKETPLACE_FILE}" ]] || {
  echo "ERROR: Missing ${VBMA_MARKETPLACE_FILE}" >&2
  exit 1
}

PUBLISHER="$(jq -r '.publisher' "${VBMA_MARKETPLACE_FILE}")"
OFFER="$(jq -r '.offer' "${VBMA_MARKETPLACE_FILE}")"
PLAN="$(jq -r '.plan' "${VBMA_MARKETPLACE_FILE}")"
PLAN_VERSION="$(jq -r '.planVersion' "${VBMA_MARKETPLACE_FILE}")"
APP_PARAMS_JSON="$(jq -c '.appParameters // {}' "${VBMA_MARKETPLACE_FILE}")"

# -----------------------------
# Managed RG (unique, Azure-owned)
# -----------------------------
TS="$(date +%Y%m%d%H%M%S)"
VBMA_MRG_NAME="${VBMA_MRG_NAME_BASE}-${TS}"
MRG_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${VBMA_MRG_NAME}"

echo "==> Using managed resource group:"
echo "${MRG_ID}" | cat -v

# -----------------------------
# Accept Marketplace terms
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
