#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Deploys the baseline lab (infra/main.bicep).
# Optionally deploys the "Veeam Backup for Microsoft Azure" marketplace Managed App.

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

# Marketplace values can come from ENV first; if empty, fall back to parameters file.
VBMA_PARAM_FILE_DEFAULT="${REPO_ROOT}/marketplace/vbazure.parameters.json"

VBMA_PUBLISHER="${VBMA_PUBLISHER:-}"
VBMA_OFFER="${VBMA_OFFER:-}"
VBMA_PLAN="${VBMA_PLAN:-}"
VBMA_PLAN_VERSION="${VBMA_PLAN_VERSION:-}"
VBMA_APP_NAME="${VBMA_APP_NAME:-}"
VBMA_MRG_NAME="${VBMA_MRG_NAME:-}"
# Optional: app parameters JSON (object). If not set, will use appParameters.value from file or {}.
VBMA_APP_PARAMS_JSON="${VBMA_APP_PARAMS_JSON:-}"

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

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required for marketplace deployment. Install jq or set DEPLOY_VBMA=false."
  exit 1
fi

# If any marketplace vars are missing, try loading them from the parameters file
PARAM_FILE="${VBMA_PARAM_FILE_DEFAULT}"
SANITIZED_PARAM_FILE=""
APP_PARAMS_FILE=""

cleanup() {
  rm -f "${SANITIZED_PARAM_FILE}" 2>/dev/null || true
  rm -f "${APP_PARAMS_FILE}" 2>/dev/null || true
}
trap cleanup EXIT

need_from_file=false
for v in VBMA_PUBLISHER VBMA_OFFER VBMA_PLAN VBMA_PLAN_VERSION VBMA_APP_NAME VBMA_MRG_NAME; do
  if [[ -z "${!v}" ]]; then
    need_from_file=true
    break
  fi
done

if [[ "${need_from_file}" == "true" ]]; then
  if [[ ! -f "${PARAM_FILE}" ]]; then
    echo "ERROR: Marketplace env vars not fully set and missing parameters file:"
    echo "       ${PARAM_FILE}"
    echo "       Set VBMA_* env vars or provide ${PARAM_FILE}."
    exit 1
  fi

  # jq can fail with "Invalid numeric literal" if the file has a UTF-8 BOM.
  SANITIZED_PARAM_FILE="$(mktemp -t vbazure-params-XXXXXX.json)"
  sed '1s/^\xEF\xBB\xBF//' "${PARAM_FILE}" > "${SANITIZED_PARAM_FILE}"

  echo "==> Reading marketplace parameters from ${PARAM_FILE}"

  # Only fill missing values from file; ENV stays authoritative.
  [[ -z "${VBMA_PUBLISHER}"     ]] && VBMA_PUBLISHER="$(jq -r '.parameters.publisher.value // empty' "${SANITIZED_PARAM_FILE}")"
  [[ -z "${VBMA_OFFER}"         ]] && VBMA_OFFER="$(jq -r '.parameters.offer.value // empty' "${SANITIZED_PARAM_FILE}")"
  [[ -z "${VBMA_PLAN}"          ]] && VBMA_PLAN="$(jq -r '.parameters.plan.value // empty' "${SANITIZED_PARAM_FILE}")"
  [[ -z "${VBMA_PLAN_VERSION}"  ]] && VBMA_PLAN_VERSION="$(jq -r '.parameters.planVersion.value // empty' "${SANITIZED_PARAM_FILE}")"
  [[ -z "${VBMA_APP_NAME}"      ]] && VBMA_APP_NAME="$(jq -r '.parameters.managedApplicationName.value // empty' "${SANITIZED_PARAM_FILE}")"
  [[ -z "${VBMA_MRG_NAME}"      ]] && VBMA_MRG_NAME="$(jq -r '.parameters.managedResourceGroupName.value // empty' "${SANITIZED_PARAM_FILE}")"

  # app params fallback from file only if env not set
  if [[ -z "${VBMA_APP_PARAMS_JSON}" ]]; then
    VBMA_APP_PARAMS_JSON="$(jq -c '.parameters.appParameters.value // {}' "${SANITIZED_PARAM_FILE}")"
  fi
fi

# Validate required marketplace values
if [[ -z "${VBMA_PUBLISHER}" || -z "${VBMA_OFFER}" || -z "${VBMA_PLAN}" || -z "${VBMA_PLAN_VERSION}" || -z "${VBMA_APP_NAME}" || -z "${VBMA_MRG_NAME}" ]]; then
  echo "ERROR: Missing required marketplace values."
  echo "       Need: VBMA_PUBLISHER, VBMA_OFFER, VBMA_PLAN, VBMA_PLAN_VERSION, VBMA_APP_NAME, VBMA_MRG_NAME"
  echo "       (Either set env vars, or provide them in marketplace/vbazure.parameters.json)"
  exit 1
fi

# Managed resource group must NOT exist; Azure will create it during managedapp create.
if az group exists -n "${VBMA_MRG_NAME}" >/dev/null 2>&1; then
  if [[ "$(az group exists -n "${VBMA_MRG_NAME}" -o tsv)" == "true" ]]; then
    echo "ERROR: Managed resource group '${VBMA_MRG_NAME}' already exists."
    echo "       For a Managed Application, Azure must create this RG."
    echo "       Delete it (or choose a new VBMA_MRG_NAME / parameters value) and re-run."
    exit 1
  fi
fi

MRG_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${VBMA_MRG_NAME}"

echo "==> App RG: ${RG_NAME}"
echo "==> Managed RG: ${VBMA_MRG_NAME}"
echo "==> Managed RG id: ${MRG_ID}"

echo "==> Accepting marketplace terms (publisher=${VBMA_PUBLISHER}, offer=${VBMA_OFFER}, plan=${VBMA_PLAN})"
# Best-effort accept (some CLI builds differ)
az term accept --publisher "${VBMA_PUBLISHER}" --product "${VBMA_OFFER}" --plan "${VBMA_PLAN}" 1>/dev/null 2>/dev/null || \
  az vm image terms accept --publisher "${VBMA_PUBLISHER}" --offer "${VBMA_OFFER}" --plan "${VBMA_PLAN}" 1>/dev/null 2>/dev/null || \
  true

# Validate/normalize VBMA_APP_PARAMS_JSON (must be a JSON object)
if [[ -z "${VBMA_APP_PARAMS_JSON}" ]]; then
  VBMA_APP_PARAMS_JSON="{}"
fi

# This ensures we don't pass broken JSON like "{}}
# If it's not valid JSON, fail fast.
if ! echo "${VBMA_APP_PARAMS_JSON}" | jq -e '.' >/dev/null 2>&1; then
  echo "ERROR: VBMA_APP_PARAMS_JSON is not valid JSON."
  echo "       Value was: ${VBMA_APP_PARAMS_JSON}"
  exit 1
fi

# If non-empty object, write to a temp file for --parameters @file
if [[ "$(echo "${VBMA_APP_PARAMS_JSON}" | jq -c 'if type=="object" and length>0 then "nonempty" else "empty" end')" == "\"nonempty\"" ]]; then
  APP_PARAMS_FILE="$(mktemp -t vbma-appparams-XXXXXX.json)"
  printf '%s\n' "${VBMA_APP_PARAMS_JSON}" > "${APP_PARAMS_FILE}"
fi

echo "==> Deploying Veeam Backup for Microsoft Azure managed app: ${VBMA_APP_NAME}"

# IMPORTANT: Use long option --managed-rg-id to avoid weird parsing issues in some shells.
# Also: DO NOT pre-create the managed RG; Azure will create it.
if [[ -n "${APP_PARAMS_FILE}" ]]; then
  az managedapp create \
    -g "${RG_NAME}" \
    -n "${VBMA_APP_NAME}" \
    -l "${LOCATION}" \
    --kind MarketPlace \
    --managed-rg-id "${MRG_ID}" \
    --plan-name "${VBMA_PLAN}" \
    --plan-product "${VBMA_OFFER}" \
    --plan-publisher "${VBMA_PUBLISHER}" \
    --plan-version "${VBMA_PLAN_VERSION}" \
    --parameters @"${APP_PARAMS_FILE}" \
    1>/dev/null
else
  az managedapp create \
    -g "${RG_NAME}" \
    -n "${VBMA_APP_NAME}" \
    -l "${LOCATION}" \
    --kind MarketPlace \
    --managed-rg-id "${MRG_ID}" \
    --plan-name "${VBMA_PLAN}" \
    --plan-product "${VBMA_OFFER}" \
    --plan-publisher "${VBMA_PUBLISHER}" \
    --plan-version "${VBMA_PLAN_VERSION}" \
    1>/dev/null
fi

echo "==> Marketplace managed app deployment submitted."
echo "    Managed app: ${VBMA_APP_NAME}"
echo "    Managed resource group (will be created by Azure): ${VBMA_MRG_NAME}"
echo "    Managed RG id: ${MRG_ID}"
