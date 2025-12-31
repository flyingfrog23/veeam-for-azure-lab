#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# scripts/deploy.sh
# Deploys the baseline lab (infra/main.bicep).
# Optionally deploys the "Veeam Backup for Microsoft Azure" marketplace managed app
# using marketplace/vbazure.parameters.json (best-effort, parameterized).

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

# ---- Marketplace (best-effort, parameter-driven) ----
# This section uses a simple managed application resource deployment.
# You must ensure the offer details are correct for your subscription/region.
# The parameters file contains publisher/offer/plan values you can adjust quickly.

PARAM_FILE="${REPO_ROOT}/marketplace/vbazure.parameters.json"
if [[ ! -f "${PARAM_FILE}" ]]; then
  echo "ERROR: Missing ${PARAM_FILE}"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq is required for marketplace deployment. Install jq or set DEPLOY_VBMA=false."
  exit 1
fi

echo "==> Reading marketplace parameters from ${PARAM_FILE}"
PUBLISHER="$(jq -r '.parameters.publisher.value' "${PARAM_FILE}")"
OFFER="$(jq -r '.parameters.offer.value' "${PARAM_FILE}")"
PLAN="$(jq -r '.parameters.plan.value' "${PARAM_FILE}")"
PLAN_VERSION="$(jq -r '.parameters.planVersion.value // empty' "${PARAM_FILE}")"
APP_NAME="$(jq -r '.parameters.managedApplicationName.value' "${PARAM_FILE}")"
MRG_NAME="$(jq -r '.parameters.managedResourceGroupName.value' "${PARAM_FILE}")"

if [[ -z "${PUBLISHER}" || -z "${OFFER}" || -z "${PLAN}" ]]; then
  echo "ERROR: publisher/offer/plan missing in ${PARAM_FILE}"
  exit 1
fi

echo "==> Accepting marketplace terms (publisher=${PUBLISHER}, offer=${OFFER}, plan=${PLAN}, version=${PLAN_VERSION:-<none>})"
# NOTE: Azure CLI does *not* support a --version flag for terms acceptance.
# Different Azure CLI versions/offer types expose different commands; try both (best-effort).
az vm image terms accept --publisher "${PUBLISHER}" --offer "${OFFER}" --plan "${PLAN}" 1>/dev/null 2>/dev/null || \
  az marketplace ordering agreement accept --publisher "${PUBLISHER}" --offer "${OFFER}" --plan "${PLAN}" 1>/dev/null 2>/dev/null || true

# Create managed resource group id
MRG_ID="/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${MRG_NAME}"

echo "==> Deploying Veeam Backup for Microsoft Azure managed app: ${APP_NAME}"
# Deploy via an ARM template for a managed application resource.
# IMPORTANT: Avoid process substitution (<(...)) because it breaks on some shells (e.g., Git Bash on Windows)
# with errors like: [Errno 2] No such file or directory: '/proc/.../fd/...'
TMP_TEMPLATE="$(mktemp -t vbma-template-XXXXXX.json)"
cleanup() {
  rm -f "${TMP_TEMPLATE}" 2>/dev/null || true
}
trap cleanup EXIT

cat >"${TMP_TEMPLATE}" <<'ARM'
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "managedApplicationName": { "type": "string" },
    "managedResourceGroupName": { "type": "string" },
    "managedResourceGroupId": { "type": "string" },
    "location": { "type": "string" },

    "publisher": { "type": "string" },
    "offer": { "type": "string" },
    "plan": { "type": "string" },
    "planVersion": { "type": "string", "defaultValue": "" },

    "appParameters": { "type": "object", "defaultValue": {} }
  },
  "resources": [
    {
      "type": "Microsoft.Solutions/applications",
      "apiVersion": "2019-07-01",
      "name": "[parameters('managedApplicationName')]",
      "location": "[parameters('location')]",
      "kind": "MarketPlace",
      "plan": {
        "name": "[parameters('plan')]",
        "publisher": "[parameters('publisher')]",
        "product": "[parameters('offer')]",
        "version": "[parameters('planVersion')]"
      },
      "properties": {
        "managedResourceGroupId": "[parameters('managedResourceGroupId')]",
        "parameters": "[parameters('appParameters')]"
      }
    }
  ],
  "outputs": {
    "managedApplicationId": {
      "type": "string",
      "value": "[resourceId('Microsoft.Solutions/applications', parameters('managedApplicationName'))]"
    }
  }
}
ARM

az deployment group create \
  -g "${RG_NAME}" \
  -n "vbma-$(date +%Y%m%d%H%M%S)" \
  --parameters @"${PARAM_FILE}" \
  --parameters managedResourceGroupId="${MRG_ID}" \
  --template-file "${TMP_TEMPLATE}" \
  1>/dev/null

echo "==> Marketplace managed app deployment submitted."
echo "    Managed resource group: ${MRG_NAME}"
