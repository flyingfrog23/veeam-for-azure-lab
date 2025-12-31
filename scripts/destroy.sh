#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Destroys the whole lab by deleting the resource group.
# Best-effort also deletes the Marketplace managed app managed RG.

SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-}"
RG_NAME="${RG_NAME:-veeam-lab-rg}"

PARAM_FILE="${REPO_ROOT}/marketplace/vbazure.parameters.json"
STATE_FILE="${REPO_ROOT}/.vbma.state"

MRG_NAME=""

# Prefer state file produced by deploy.sh (most reliable)
if [[ -f "${STATE_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${STATE_FILE}" || true
  # If sourced, it may set MRG_NAME and SUBSCRIPTION_ID
fi

# Fallback to parameter file (older behavior)
if [[ -z "${MRG_NAME}" ]] && command -v jq >/dev/null 2>&1 && [[ -f "${PARAM_FILE}" ]]; then
  # strip BOM defensively before jq
  TMPP="$(mktemp -t vbazure-params-XXXXXX.json)"
  sed '1s/^\xEF\xBB\xBF//' "${PARAM_FILE}" > "${TMPP}"
  MRG_NAME="$(jq -r '.parameters.managedResourceGroupName.value // empty' "${TMPP}")"
  rm -f "${TMPP}" || true
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
