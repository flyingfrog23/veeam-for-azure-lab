#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Deploys the baseline lab (infra/main.bicep).
# Optionally deploys the "Veeam Backup for Microsoft Azure" marketplace managed app
# (Microsoft.Solutions/applications) and lets Azure create the managed resource group.

# ---- Required / common env vars (typically from .env) ----
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-}"
LOCATION="${LOCATION:-switzerlandnorth}"
RG_NAME="${RG_NAME:-veeam-lab-rg}"
PREFIX="${PREFIX:-veeam-lab}"

ADMIN_USERNAME="${ADMIN_USERNAME:-veeamadmin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"         # required unless you change this script
ALLOWED_RDP_SOURCE="${ALLOWED_RDP_SOURCE:-0.0.0.0/0}"

# Marketplace toggle
DEPLOY_VBMA="${DEPLOY_VBMA:-false}"          # true/false

# Marketplace env overrides (preferred if set)
VBMA_APP_NAME="${VBMA_APP_NAME:-}"
VBMA_MRG_NAME="${VBMA_MRG_NAME:-}"
VBMA_PUBLISHER="${VBMA_PUBLISHER:-}"
VBMA_OFFER="${VBMA_OFFER:-}"
VBMA_PLAN="${VBMA_PLAN:-}"
VBMA_PLAN_VERSION="${VBMA_PLAN_VERSION:-}"
VBMA_APP_PARAMS_JSON="${VBMA_APP_PARAMS_JSON:-}"   # optional, JSON string (e.g. {"key":"value"})

PARAM_FILE="${REPO_ROOT}/marketplace/vbazure.parameters.json"

die() { echo "ERROR: $*" >&2; exit 1; }

if [[ -z "${SUBSCRIPTION_ID}" ]]; then
  die "SUBSCRIPTION_ID is required."
fi

if [[ -z "${ADMIN_PASSWORD}" ]]; then
  die "ADMIN_PASSWORD is required (set env var)."
fi

echo "==> Setting subscription"
az account set --subscription "${SUBSCRIPTION_ID}"

# Helpful visibility (so you can prove you're in the tenant/sub you think you are)
echo "==> Azure context"
az account show --query "{name:name, subscriptionId:id, tenantId:tenantId, user:user.name}" -o table

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
command -v jq >/dev/null 2>&1 || die "jq is required for marketplace deployment."

if [[ -f "${PARAM_FILE}" ]]; then
  # jq can fail with "Invalid numeric literal" if the file has a UTF-8 BOM (common on Windows).
  SANITIZED_PARAM_FILE="$(mktemp -t vbazure-params-XXXXXX.json)"
  trap 'rm -f "${SANITIZED_PARAM_FILE}" "${APP_PARAMS_FILE:-}" 2>/dev/null || true' EXIT
  sed '1s/^\xEF\xBB\xBF//' "${PARAM_FILE}" > "${SANITIZED_PARAM_FILE}"
else
  SANITIZED_PARAM_FILE=""
fi

# Load from env first; fallback to parameter file if missing.
read_from_file() {
  local jq_expr="$1"
  [[ -n "${SANITIZED_PARAM_FILE}" ]] && jq -r "${jq_expr}" "${SANITIZED_PARAM_FILE}" || echo ""
}

PUBLISHER="${VBMA_PUBLISHER:-$(read_from_file '.parameters.publisher.value // empty')}"
OFFER="${VBMA_OFFER:-$(read_from_file '.parameters.offer.value // empty')}"
PLAN="${VBMA_PLAN:-$(read_from_file '.parameters.plan.value // empty')}"
PLAN_VERSION="${VBMA_PLAN_VERSION:-$(read_from_file '.parameters.planVersion.value // empty')}"
APP_NAME="${VBMA_APP_NAME:-$(read_from_file '.parameters.managedApplicationName.value // empty')}"
MRG_NAME="${VBMA_MRG_NAME:-$(read_from_file '.parameters.managedResourceGroupName.value // empty')}"

# appParameters:
# - if VBMA_APP_PARAMS_JSON is set, use it
# - else read from file's parameters.appParameters.value (expected to be an object)
APP_PARAMS_JSON="${VBMA_APP_PARAMS_JSON:-}"
if [[ -z "${APP_PARAMS_JSON}" ]]; then
  APP_PARAMS_JSON="$(read_from_file '.parameters.appParameters.value // {}')"
fi

# Validate required values
[[ -n "${PUBLISHER}" ]]    || die "Missing VBMA publisher (VBMA_PUBLISHER or parameters.json)."
[[ -n "${OFFER}" ]]        || die "Missing VBMA offer (VBMA_OFFER or parameters.json)."
[[ -n "${PLAN}" ]]         || die "Missing VBMA plan (VBMA_PLAN or parameters.json)."
[[ -n "${PLAN_VERSION}" ]] || die "Missing VBMA planVersion (VBMA_PLAN_VERSION or parameters.json)."
[[ -n "${APP_NAME}" ]]     || die "Missing VBMA app name (VBMA_APP_NAME or parameters.json)."
[[ -n "${MRG_NAME}" ]]     || die "Missing VBMA managed resource group name (VBMA_MRG_NAME or parameters.json)."

# IMPORTANT: The managed resource group must NOT already exist.
if az group exists -n "${MRG_NAME}" >/dev/null 2>&1 && [[ "$(az group exists -n "${MRG_NAME}")" == "true" ]]; then
  die "Managed resource group '${MRG_NAME}' already exists.
For a Marketplace Managed Application, Azure must create/own this RG.
Delete it (az group delete -n ${MRG_NAME}) or choose a new VBMA_MRG_NAME, then re-run."
fi

# Build managed RG ID (what az managedapp create expects)
MRG_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${MRG_NAME}"

echo "==> Marketplace parameters"
echo "    App RG: ${RG_NAME}"
echo "    Managed RG: ${MRG_NAME}"
echo "    Managed RG id: ${MRG_ID}"
echo "    Publisher/Offer/Plan/Version: ${PUBLISHER}/${OFFER}/${PLAN}/${PLAN_VERSION}"
echo "    App name: ${APP_NAME}"

echo "==> Accepting marketplace terms (publisher=${PUBLISHER}, offer=${OFFER}, plan=${PLAN})"
# NOTE: 'az term accept' does not take --version; 'az vm image terms accept' is an alternative.
az term accept --publisher "${PUBLISHER}" --product "${OFFER}" --plan "${PLAN}" 1>/dev/null 2>/dev/null || \
  az vm image terms accept --publisher "${PUBLISHER}" --offer "${OFFER}" --plan "${PLAN}" 1>/dev/null 2>/dev/null || \
  true

# Ensure appParameters is valid JSON object; only pass --parameters if it's non-empty.
# This avoids the "Failed to parse string as JSON" problem.
if ! echo "${APP_PARAMS_JSON}" | jq -e '.' >/dev/null 2>&1; then
  die "VBMA appParameters is not valid JSON. Got: ${APP_PARAMS_JSON}"
fi

APP_PARAMS_FILE=""
if [[ "$(echo "${APP_PARAMS_JSON}" | jq -c '.')" != "{}" ]]; then
  APP_PARAMS_FILE="$(mktemp -t vbma-appparams-XXXXXX.json)"
  echo "${APP_PARAMS_JSON}" | jq -c '.' > "${APP_PARAMS_FILE}"
fi

echo "==> Deploying Veeam Backup for Microsoft Azure managed app: ${APP_NAME}"
if [[ -n "${APP_PARAMS_FILE}" ]]; then
  az managedapp create \
    --resource-group "${RG_NAME}" \
    --name "${APP_NAME}" \
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
    --name "${APP_NAME}" \
    --location "${LOCATION}" \
    --kind MarketPlace \
    --managed-rg-id "${MRG_ID}" \
    --plan-name "${PLAN}" \
    --plan-product "${OFFER}" \
    --plan-publisher "${PUBLISHER}" \
    --plan-version "${PLAN_VERSION}"
fi

echo "==> Marketplace managed app deployment submitted."
