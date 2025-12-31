#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Deploys the baseline lab (infra/main.bicep).
# Optionally deploys the "Veeam Backup for Microsoft Azure" marketplace managed app
# using marketplace/vbazure.parameters.json (env vars can override).

# ---- Required env vars (or edit defaults below) ----
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-}"
LOCATION="${LOCATION:-westeurope}"
RG_NAME="${RG_NAME:-veeam-lab-rg}"
PREFIX="${PREFIX:-veeam-lab}"

ADMIN_USERNAME="${ADMIN_USERNAME:-veeamadmin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"   # required unless you edit to prompt securely
ALLOWED_RDP_SOURCE="${ALLOWED_RDP_SOURCE:-0.0.0.0/0}"

# Marketplace toggle
DEPLOY_VBMA="${DEPLOY_VBMA:-false}"  # true/false

# Optional env overrides for marketplace values (if set, they win over JSON)
VBMA_PUBLISHER="${VBMA_PUBLISHER:-}"
VBMA_OFFER="${VBMA_OFFER:-}"
VBMA_PLAN="${VBMA_PLAN:-}"
VBMA_PLAN_VERSION="${VBMA_PLAN_VERSION:-}"
VBMA_APP_NAME="${VBMA_APP_NAME:-}"
VBMA_MRG_NAME="${VBMA_MRG_NAME:-}"   # Managed Resource Group NAME (must NOT already exist)

if [[ -z "${SUBSCRIPTION_ID}" ]]; then
  echo "ERROR: SUBSCRIPTION_ID is required."
  exit 1
fi

if [[ -z "${ADMIN_PASSWORD}" ]]; then
  echo "ERROR: ADMIN_PASSWORD is required (set env var)."
  exit 1
fi

echo "==> Setting subscription"
az account set --subscription "${SUBSCRIPTION_ID}"

echo "==> Creating resource group ${RG_NAME} in ${LOCATION}"
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
  echo "==> Skipping marketplace deployment (set DEPLOY_VBMA=true to enable)."
  exit 0
fi

# ---- Marketplace deployment (Managed App) ----
PARAM_FILE="${REPO_ROOT}/marketplace/vbazure.parameters.json"
if [[ ! -f "${PARAM_FILE}" ]]; then
  echo "ERROR: Missing ${PARAM_FILE}"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required for marketplace deployment. Install jq or set DEPLOY_VBMA=false."
  exit 1
fi

# jq can fail with "Invalid numeric literal" if the file has a UTF-8 BOM.
# Create a sanitized temp copy and always read from that.
SANITIZED_PARAM_FILE="$(mktemp -t vbazure-params-XXXXXX.json)"
APP_PARAMS_FILE=""
cleanup() {
  rm -f "${SANITIZED_PARAM_FILE}" 2>/dev/null || true
  rm -f "${APP_PARAMS_FILE}" 2>/dev/null || true
}
trap cleanup EXIT

# Strip UTF-8 BOM if present (EF BB BF)
sed '1s/^\xEF\xBB\xBF//' "${PARAM_FILE}" > "${SANITIZED_PARAM_FILE}"

echo "==> Reading marketplace parameters from ${PARAM_FILE}"

# Read from JSON (fallbacks), then apply env overrides (if set)
PUBLISHER="$(jq -r '.parameters.publisher.value // empty' "${SANITIZED_PARAM_FILE}")"
OFFER="$(jq -r '.parameters.offer.value // empty' "${SANITIZED_PARAM_FILE}")"
PLAN="$(jq -r '.parameters.plan.value // empty' "${SANITIZED_PARAM_FILE}")"
PLAN_VERSION="$(jq -r '.parameters.planVersion.value // empty' "${SANITIZED_PARAM_FILE}")"
APP_NAME="$(jq -r '.parameters.managedApplicationName.value // empty' "${SANITIZED_PARAM_FILE}")"
MRG_NAME="$(jq -r '.parameters.managedResourceGroupName.value // empty' "${SANITIZED_PARAM_FILE}")"

# Env overrides win if provided
[[ -n "${VBMA_PUBLISHER}" ]]    && PUBLISHER="${VBMA_PUBLISHER}"
[[ -n "${VBMA_OFFER}" ]]        && OFFER="${VBMA_OFFER}"
[[ -n "${VBMA_PLAN}" ]]         && PLAN="${VBMA_PLAN}"
[[ -n "${VBMA_PLAN_VERSION}" ]] && PLAN_VERSION="${VBMA_PLAN_VERSION}"
[[ -n "${VBMA_APP_NAME}" ]]     && APP_NAME="${VBMA_APP_NAME}"
[[ -n "${VBMA_MRG_NAME}" ]]     && MRG_NAME="${VBMA_MRG_NAME}"

if [[ -z "${PUBLISHER}" || -z "${OFFER}" || -z "${PLAN}" || -z "${APP_NAME}" || -z "${MRG_NAME}" ]]; then
  echo "ERROR: Missing required marketplace values."
  echo "       Need: publisher, offer, plan, managedApplicationName, managedResourceGroupName"
  echo "       Provide them in ${PARAM_FILE} or via env overrides (VBMA_*)."
  exit 1
fi

if [[ -z "${PLAN_VERSION}" ]]; then
  echo "ERROR: planVersion is empty."
  echo "       Set parameters.planVersion.value in ${PARAM_FILE} or VBMA_PLAN_VERSION env var."
  exit 1
fi

MRG_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${MRG_NAME}"

echo "==> App RG: ${RG_NAME}"
echo "==> Managed RG: ${MRG_NAME}"
echo "==> Managed RG id: ${MRG_ID}"

# IMPORTANT: For Managed Applications, Azure must create the managed resource group.
# If it already exists, the create will fail or behave unexpectedly.
if az group exists -n "${MRG_NAME}" 2>/dev/null | grep -qiE '^true$'; then
  echo "ERROR: Managed resource group '${MRG_NAME}' already exists."
  echo "       For a Managed Application, Azure must create this RG."
  echo "       Delete it (or choose a new VBMA_MRG_NAME / parameters value) and re-run."
  exit 1
fi

echo "==> Accepting marketplace terms (publisher=${PUBLISHER}, offer=${OFFER}, plan=${PLAN})"
# Best-effort: terms accept commands vary across CLI modules/versions
az term accept --publisher "${PUBLISHER}" --product "${OFFER}" --plan "${PLAN}" 1>/dev/null 2>/dev/null || \
  az vm image terms accept --publisher "${PUBLISHER}" --offer "${OFFER}" --plan "${PLAN}" 1>/dev/null 2>/dev/null || \
  true

# Extract appParameters.value (must be an object) and only pass --parameters if it isn't empty.
APP_PARAMS_JSON="$(jq -c '.parameters.appParameters.value // {}' "${SANITIZED_PARAM_FILE}")"
if [[ "${APP_PARAMS_JSON}" != "{}" ]]; then
  APP_PARAMS_FILE="$(mktemp -t vbma-appparams-XXXXXX.json)"
  printf '%s\n' "${APP_PARAMS_JSON}" > "${APP_PARAMS_FILE}"
fi

echo "==> Deploying Veeam Backup for Microsoft Azure managed app: ${APP_NAME}"

# NOTE: Use --managed-resource-group-id (NOT -m) to avoid InvalidApplicationManagedResourceGroupId
if [[ -n "${APP_PARAMS_FILE}" ]]; then
  az managedapp create \
    -g "${RG_NAME}" \
    -n "${APP_NAME}" \
    -l "${LOCATION}" \
    --kind MarketPlace \
    --managed-resource-group-id "${MRG_ID}" \
    --plan-name "${PLAN}" \
    --plan-product "${OFFER}" \
    --plan-publisher "${PUBLISHER}" \
    --plan-version "${PLAN_VERSION}" \
    --parameters @"${APP_PARAMS_FILE}" \
    1>/dev/null
else
  az managedapp create \
    -g "${RG_NAME}" \
    -n "${APP_NAME}" \
    -l "${LOCATION}" \
    --kind MarketPlace \
    --managed-resource-group-id "${MRG_ID}" \
    --plan-name "${PLAN}" \
    --plan-product "${OFFER}" \
    --plan-publisher "${PUBLISHER}" \
    --plan-version "${PLAN_VERSION}" \
    1>/dev/null
fi

echo "==> Marketplace managed app deployment submitted."
echo "    Managed app: ${APP_NAME}"
echo "    Managed resource group (Azure will create): ${MRG_NAME}"
echo "    Managed RG id: ${MRG_ID}"
