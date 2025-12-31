#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Deploys the baseline lab (infra/main.bicep).
# Optionally deploys the "Veeam Backup for Microsoft Azure" marketplace managed app
# using marketplace/vbazure.parameters.json.

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
cleanup() {
  rm -f "${SANITIZED_PARAM_FILE}" 2>/dev/null || true
  rm -f "${APP_PARAMS_FILE:-}" 2>/dev/null || true
}
trap cleanup EXIT

# Strip UTF-8 BOM if present (EF BB BF)
# (sed is used instead of process substitution to keep Git Bash/Windows happy)
sed '1s/^\xEF\xBB\xBF//' "${PARAM_FILE}" > "${SANITIZED_PARAM_FILE}"

echo "==> Reading marketplace parameters from ${PARAM_FILE}"
PUBLISHER="$(jq -r '.parameters.publisher.value' "${SANITIZED_PARAM_FILE}")"
OFFER="$(jq -r '.parameters.offer.value' "${SANITIZED_PARAM_FILE}")"
PLAN="$(jq -r '.parameters.plan.value' "${SANITIZED_PARAM_FILE}")"
PLAN_VERSION="$(jq -r '.parameters.planVersion.value // empty' "${SANITIZED_PARAM_FILE}")"
APP_NAME="$(jq -r '.parameters.managedApplicationName.value' "${SANITIZED_PARAM_FILE}")"
MRG_NAME="$(jq -r '.parameters.managedResourceGroupName.value' "${SANITIZED_PARAM_FILE}")"

if [[ -z "${PUBLISHER}" || -z "${OFFER}" || -z "${PLAN}" || -z "${APP_NAME}" || -z "${MRG_NAME}" ]]; then
  echo "ERROR: Missing required marketplace values in ${PARAM_FILE}."
  echo "       Need: publisher, offer, plan, managedApplicationName, managedResourceGroupName"
  exit 1
fi

if [[ -z "${PLAN_VERSION}" ]]; then
  echo "ERROR: planVersion is empty in ${PARAM_FILE}."
  echo "       az managedapp create requires --plan-version for MarketPlace kind."
  exit 1
fi

MRG_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${MRG_NAME}"

echo "==> Accepting marketplace terms (publisher=${PUBLISHER}, offer=${OFFER}, plan=${PLAN})"
# az term accept is the CLI command for marketplace terms; it does NOT take --version. :contentReference[oaicite:2]{index=2}
# Some environments may not have it enabled (experimental), so we best-effort several options.
az term accept --publisher "${PUBLISHER}" --product "${OFFER}" --plan "${PLAN}" 1>/dev/null 2>/dev/null || \
  az vm image terms accept --publisher "${PUBLISHER}" --offer "${OFFER}" --plan "${PLAN}" 1>/dev/null 2>/dev/null || \
  true

# Extract appParameters.value to a file if it's not empty.
# az managedapp create expects its own parameters payload (not the ARM deploymentParameters wrapper).
APP_PARAMS_JSON="$(jq -c '.parameters.appParameters.value // {}' "${SANITIZED_PARAM_FILE}")"
APP_PARAMS_FILE=""
if [[ "${APP_PARAMS_JSON}" != "{}" ]]; then
  APP_PARAMS_FILE="$(mktemp -t vbma-appparams-XXXXXX.json)"
  printf '%s\n' "${APP_PARAMS_JSON}" > "${APP_PARAMS_FILE}"
fi

echo "==> Deploying Veeam Backup for Microsoft Azure managed app: ${APP_NAME}"
# Use az managedapp create (supports plan-version, and avoids your ARM template param mismatch). :contentReference[oaicite:3]{index=3}
if [[ -n "${APP_PARAMS_FILE}" ]]; then
  az managedapp create \
    -g "${RG_NAME}" \
    -n "${APP_NAME}" \
    -l "${LOCATION}" \
    --kind MarketPlace \
    -m "${MRG_ID}" \
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
    -m "${MRG_ID}" \
    --plan-name "${PLAN}" \
    --plan-product "${OFFER}" \
    --plan-publisher "${PUBLISHER}" \
    --plan-version "${PLAN_VERSION}" \
    1>/dev/null
fi

echo "==> Marketplace managed app deployment submitted."
echo "    Managed app: ${APP_NAME}"
echo "    Managed resource group: ${MRG_NAME}"
echo "    Managed RG id: ${MRG_ID}"
