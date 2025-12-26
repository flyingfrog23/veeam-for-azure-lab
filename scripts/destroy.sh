#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# scripts/destroy.sh
# Destroys the whole lab by deleting the resource group.

SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-}"
RG_NAME="${RG_NAME:-veeam-lab-rg}"

# Best-effort cleanup of Marketplace managed app managed resource group (if you deployed it)
PARAM_FILE="${REPO_ROOT}/marketplace/vbazure.parameters.json"
if command -v jq >/dev/null 2>&1 && [[ -f "${PARAM_FILE}" ]]; then
  MRG_NAME="$(jq -r '.parameters.managedResourceGroupName.value // empty' "${PARAM_FILE}")"
else
  MRG_NAME=""
fi

if [[ -z "${SUBSCRIPTION_ID}" ]]; then
  echo "ERROR: SUBSCRIPTION_ID is required."
  exit 1
fi

echo "==> Setting subscription"
az account set --subscription "${SUBSCRIPTION_ID}"

echo "==> Deleting resource group ${RG_NAME}"
az group delete -n "${RG_NAME}" --yes --no-wait

echo "==> Delete initiated: ${RG_NAME}"

if [[ -n "${MRG_NAME}" ]]; then
  echo "==> Deleting managed resource group (best-effort): ${MRG_NAME}"
  az group delete -n "${MRG_NAME}" --yes --no-wait || true
  echo "==> Delete initiated: ${MRG_NAME}"
fi
