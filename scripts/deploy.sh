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

# Optional overrides via env (if set, they win over the JSON file)
VBMA_PUBLISHER="${VBMA_PUBLISHER:-}"
VBMA_OFFER="${VBMA_OFFER:-}"
VBMA_PLAN="${VBMA_PLAN:-}"
VBMA_PLAN_VERSION="${VBMA_PLAN_VERSION:-}"
VBMA_APP_NAME="${VBMA_APP_NAME:-}"
VBMA_MRG_NAME="${VBMA_MRG_NAME:-}"

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
sed '1s/^\xEF\xBB\xBF//' "${PARAM_FILE}" > "${SANITIZED_PARAM_FILE}"

# Helper to strip CRLF junk from jq output (Windows/Git Bash friendly)
strip_cr() { printf '%s' "$1" | tr -d '\r'; }

echo "==> Reading marketplace parameters from ${PARAM_FILE}"

# Read from JSON (then allow env overrides to win)
PUBLISHER="$(strip_cr "$(jq -r '.parameters.publisher.value // empty' "${SANITIZED_PARAM_FILE}")")"
OFFER="$(strip_cr "$(jq -r '.parameters.offer.value // empty' "${SANITIZED_PARAM_FILE}")")"
PLAN="$(strip_cr "$(jq -r '.parameters.plan.value // empty' "${SANITIZED_PARAM_FILE}")")"
PLAN_VERSION="$(strip_cr "$(jq -r '.parameters.planVersion.value // empty' "${SANITIZED_PARAM_FILE}")")"
APP_NAME="$(strip_cr "$(jq -r '.parameters.managedApplicationName.value // empty' "${SANITIZED_PARAM_FILE}")")"
MRG_NAME="$(strip_cr "$(jq -r '.parameters.managedResourceGroupName.value // empty' "${SANITIZED_PARAM_FILE}")")"

# Env overrides (if set)
[[ -n "${VBMA_PUBLISHER}" ]] && PUBLISHER="${VBMA_PUBLISHER}"
[[ -n "${VBMA_OFFER}" ]] && OFFER="${VBMA_OFFER}"
[[ -n "${VBMA_PLAN}" ]] && PLAN="${VBMA_PLAN}"
[[ -n "${VBMA_PLAN_VERSION}" ]] && PLAN_VERSION="${VBMA_PLAN_VERSION}"
[[ -n "${VBMA_APP_NAME}" ]] && APP_NAME="${VBMA_APP_NAME}"
[[ -n "${VBMA_MRG_NAME}" ]] && MRG_NAME="${VBMA_MRG_NAME}"

if [[ -z "${PUBLISHER}" || -z "${OFFER}" || -z "${PLAN}" || -z "${APP_NAME}" || -z "${MRG_NAME}" ]]; then
  echo "ERROR: Missing required marketplace values."
  echo "       Need: publisher, offer, plan, managedApplicationName, managedResourceGroupName"
  echo "       Provide them in ${PARAM_FILE} or via env (VBMA_PUBLISHER/VBMA_OFFER/VBMA_PLAN/VBMA_APP_NAME/VBMA_MRG_NAME)."
  exit 1
fi

if [[ -z "${PLAN_VERSION}" ]]; then
  echo "ERROR: planVersion is empty."
  echo "       Provide it in ${PARAM_FILE} (parameters.planVersion.value) or via env VBMA_PLAN_VERSION."
  exit 1
fi

# Ensure the managed resource group exists, then fetch its *real* ARM id.
# This avoids hidden CR/LF issues and satisfies the "fully qualified identifier" requirement.
echo "==> Ensuring managed resource group exists: ${MRG_NAME} in ${LOCATION}"
az group create -n "${MRG_NAME}" -l "${LOCATION}" 1>/dev/null

MRG_ID="$(az group show -n "${MRG_NAME}" --query id -o tsv | tr -d '\r')"
if [[ -z "${MRG_ID}" ]]; then
  echo "ERROR: Could not resolve managed RG id for ${MRG_NAME}."
  exit 1
fi

echo "    App RG: ${RG_NAME}"
echo "    Managed RG: ${MRG_NAME}"
echo "    Managed RG id: ${MRG_ID}"

echo "==> Accepting marketplace terms (publisher=${PUBLISHER}, offer=${OFFER}, plan=${PLAN})"
# Best-effort: not all Azure CLI installs have the same command availability.
az term accept --publisher "${PUBLISHER}" --product "${OFFER}" --plan "${PLAN}" 1>/dev/null 2>/dev/null || \
  az vm image terms accept --publisher "${PUBLISHER}" --offer "${OFFER}" --plan "${PLAN}" 1>/dev/null 2>/dev/null || \
  true

# Extract appParameters.value to a file if it's not empty.
# az managedapp create expects ONLY the app's parameters object (not the ARM deploymentParameters wrapper).
APP_PARAMS_JSON="$(jq -c '.parameters.appParameters.value // {}' "${SANITIZED_PARAM_FILE}" | tr -d '\r')"
APP_PARAMS_FILE=""

# If it's not exactly {}, write it to a temp file.
if [[ "${APP_PARAMS_JSON}" != "{}" ]]; then
  APP_PARAMS_FILE="$(mktemp -t vbma-appparams-XXXXXX.json)"
  printf '%s\n' "${APP_PARAMS_JSON}" > "${APP_PARAMS_FILE}"
fi

echo "==> Deploying Veeam Backup for Microsoft Azure managed app: ${APP_NAME}"
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
