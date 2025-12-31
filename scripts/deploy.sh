#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

die() { echo "ERROR: $*" >&2; exit 1; }

# ---- Baseline (infra) env vars ----
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-}"
LOCATION="${LOCATION:-switzerlandnorth}"
RG_NAME="${RG_NAME:-veeam-lab-rg}"
PREFIX="${PREFIX:-veeam-lab}"

ADMIN_USERNAME="${ADMIN_USERNAME:-veeamadmin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
ALLOWED_RDP_SOURCE="${ALLOWED_RDP_SOURCE:-0.0.0.0/0}"

# ---- Marketplace toggle ----
DEPLOY_VBMA="${DEPLOY_VBMA:-false}" # true/false

# ---- Marketplace env vars (preferred) ----
VBMA_PUBLISHER="${VBMA_PUBLISHER:-}"
VBMA_OFFER="${VBMA_OFFER:-}"
VBMA_PLAN="${VBMA_PLAN:-}"
VBMA_PLAN_VERSION="${VBMA_PLAN_VERSION:-}"
VBMA_APP_NAME="${VBMA_APP_NAME:-}"
VBMA_MRG_NAME="${VBMA_MRG_NAME:-}"

# If true, delete the managed RG if it already exists (DANGEROUS).
FORCE_RECREATE_MRG="${FORCE_RECREATE_MRG:-false}"

# Parameters file fallback
PARAM_FILE="${REPO_ROOT}/marketplace/vbazure.parameters.json"

if [[ -z "${SUBSCRIPTION_ID}" ]]; then
  die "SUBSCRIPTION_ID is required."
fi
if [[ -z "${ADMIN_PASSWORD}" ]]; then
  die "ADMIN_PASSWORD is required (set env var)."
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
if ! command -v jq >/dev/null 2>&1; then
  die "jq is required for marketplace deployment. Install jq or set DEPLOY_VBMA=false."
fi

# Temp files (sanitize BOM + app params file)
SANITIZED_PARAM_FILE="$(mktemp -t vbazure-params-XXXXXX.json)"
APP_PARAMS_FILE=""
cleanup() {
  rm -f "${SANITIZED_PARAM_FILE}" 2>/dev/null || true
  rm -f "${APP_PARAMS_FILE}" 2>/dev/null || true
}
trap cleanup EXIT

# If we might need the file, ensure it exists and sanitize it (strip UTF-8 BOM).
if [[ -f "${PARAM_FILE}" ]]; then
  sed '1s/^\xEF\xBB\xBF//' "${PARAM_FILE}" > "${SANITIZED_PARAM_FILE}"
fi

# Helper: load missing vars from parameters file
load_from_file_if_missing() {
  [[ -f "${SANITIZED_PARAM_FILE}" ]] || return 0

  # Only fill blanks; do not overwrite env-provided values.
  [[ -z "${VBMA_PUBLISHER}"     ]] && VBMA_PUBLISHER="$(jq -r '.parameters.publisher.value // empty' "${SANITIZED_PARAM_FILE}")"
  [[ -z "${VBMA_OFFER}"         ]] && VBMA_OFFER="$(jq -r '.parameters.offer.value // empty' "${SANITIZED_PARAM_FILE}")"
  [[ -z "${VBMA_PLAN}"          ]] && VBMA_PLAN="$(jq -r '.parameters.plan.value // empty' "${SANITIZED_PARAM_FILE}")"
  [[ -z "${VBMA_PLAN_VERSION}"  ]] && VBMA_PLAN_VERSION="$(jq -r '.parameters.planVersion.value // empty' "${SANITIZED_PARAM_FILE}")"
  [[ -z "${VBMA_APP_NAME}"      ]] && VBMA_APP_NAME="$(jq -r '.parameters.managedApplicationName.value // empty' "${SANITIZED_PARAM_FILE}")"
  [[ -z "${VBMA_MRG_NAME}"      ]] && VBMA_MRG_NAME="$(jq -r '.parameters.managedResourceGroupName.value // empty' "${SANITIZED_PARAM_FILE}")"
}

echo "==> Loading marketplace parameters (env first; file fallback: ${PARAM_FILE})"
load_from_file_if_missing

# Validate required marketplace params
[[ -n "${VBMA_PUBLISHER}"    ]] || die "Missing VBMA_PUBLISHER (or publisher in ${PARAM_FILE})."
[[ -n "${VBMA_OFFER}"        ]] || die "Missing VBMA_OFFER (or offer in ${PARAM_FILE})."
[[ -n "${VBMA_PLAN}"         ]] || die "Missing VBMA_PLAN (or plan in ${PARAM_FILE})."
[[ -n "${VBMA_PLAN_VERSION}" ]] || die "Missing VBMA_PLAN_VERSION (or planVersion in ${PARAM_FILE})."
[[ -n "${VBMA_APP_NAME}"     ]] || die "Missing VBMA_APP_NAME (or managedApplicationName in ${PARAM_FILE})."
[[ -n "${VBMA_MRG_NAME}"     ]] || die "Missing VBMA_MRG_NAME (or managedResourceGroupName in ${PARAM_FILE})."

MRG_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${VBMA_MRG_NAME}"

echo "==> App RG: ${RG_NAME}"
echo "==> Managed RG: ${VBMA_MRG_NAME}"
echo "==> Managed RG id: ${MRG_ID}"

# Managed RG must NOT exist. Azure creates it for Managed Applications.
if az group exists -n "${VBMA_MRG_NAME}" | grep -qi true; then
  if [[ "${FORCE_RECREATE_MRG}" == "true" ]]; then
    echo "==> Managed resource group '${VBMA_MRG_NAME}' already exists; FORCE_RECREATE_MRG=true so deleting it..."
    az group delete -n "${VBMA_MRG_NAME}" --yes --no-wait
    echo "==> Waiting for managed RG deletion to complete..."
    # Wait until it stops existing
    for _ in {1..60}; do
      if az group exists -n "${VBMA_MRG_NAME}" | grep -qi false; then
        break
      fi
      sleep 5
    done
    if az group exists -n "${VBMA_MRG_NAME}" | grep -qi true; then
      die "Managed RG '${VBMA_MRG_NAME}' still exists. Wait for deletion, then rerun."
    fi
  else
    die "Managed resource group '${VBMA_MRG_NAME}' already exists.
For a Managed Application, Azure must create this RG.
Delete it (or set FORCE_RECREATE_MRG=true), or choose a new VBMA_MRG_NAME/parameters value."
  fi
fi

echo "==> Accepting marketplace terms (publisher=${VBMA_PUBLISHER}, offer=${VBMA_OFFER}, plan=${VBMA_PLAN})"
# az term accept does NOT take --version (you already saw that error); accept is best-effort.
az term accept --publisher "${VBMA_PUBLISHER}" --product "${VBMA_OFFER}" --plan "${VBMA_PLAN}" 1>/dev/null 2>/dev/null || \
  az vm image terms accept --publisher "${VBMA_PUBLISHER}" --offer "${VBMA_OFFER}" --plan "${VBMA_PLAN}" 1>/dev/null 2>/dev/null || \
  true

# appParameters handling:
# - If env var VBMA_APP_PARAMETERS_JSON is provided, use it (must be valid JSON).
# - Else if parameters file contains .parameters.appParameters.value, use it (can be {}).
VBMA_APP_PARAMETERS_JSON="${VBMA_APP_PARAMETERS_JSON:-}"

if [[ -n "${VBMA_APP_PARAMETERS_JSON}" ]]; then
  # Validate JSON
  echo "${VBMA_APP_PARAMETERS_JSON}" | jq -e . >/dev/null || die "VBMA_APP_PARAMETERS_JSON is not valid JSON."
  APP_PARAMS_FILE="$(mktemp -t vbma-appparams-XXXXXX.json)"
  printf '%s\n' "${VBMA_APP_PARAMETERS_JSON}" > "${APP_PARAMS_FILE}"
elif [[ -f "${SANITIZED_PARAM_FILE}" ]]; then
  APP_PARAMS_JSON="$(jq -c '.parameters.appParameters.value // {}' "${SANITIZED_PARAM_FILE}")"
  echo "${APP_PARAMS_JSON}" | jq -e . >/dev/null || die "appParameters.value in ${PARAM_FILE} is not valid JSON."
  if [[ "${APP_PARAMS_JSON}" != "{}" ]]; then
    APP_PARAMS_FILE="$(mktemp -t vbma-appparams-XXXXXX.json)"
    printf '%s\n' "${APP_PARAMS_JSON}" > "${APP_PARAMS_FILE}"
  fi
fi

echo "==> Deploying Veeam Backup for Microsoft Azure managed app: ${VBMA_APP_NAME}"
if [[ -n "${APP_PARAMS_FILE}" ]]; then
  az managedapp create \
    -g "${RG_NAME}" \
    -n "${VBMA_APP_NAME}" \
    -l "${LOCATION}" \
    --kind MarketPlace \
    -m "${MRG_ID}" \
    --plan-name "${VBMA_PLAN}" \
    --plan-product "${VBMA_OFFER}" \
    --plan-publisher "${VBMA_PUBLISHER}" \
    --plan-version "${VBMA_PLAN_VERSION}" \
    --parameters @"${APP_PARAMS_FILE}"
else
  az managedapp create \
    -g "${RG_NAME}" \
    -n "${VBMA_APP_NAME}" \
    -l "${LOCATION}" \
    --kind MarketPlace \
    -m "${MRG_ID}" \
    --plan-name "${VBMA_PLAN}" \
    --plan-product "${VBMA_OFFER}" \
    --plan-publisher "${VBMA_PUBLISHER}" \
    --plan-version "${VBMA_PLAN_VERSION}"
fi

echo "==> Marketplace managed app deployment submitted."
echo "    Managed app: ${VBMA_APP_NAME}"
echo "    Managed resource group (Azure will create): ${VBMA_MRG_NAME}"
echo "    Managed RG id: ${MRG_ID}"
