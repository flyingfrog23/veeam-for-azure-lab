#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$ROOT/.env" ]] && set -a && source "$ROOT/.env" && set +a

: "${SUBSCRIPTION_ID:?SUBSCRIPTION_ID is required}"
: "${ADMIN_PASSWORD:?ADMIN_PASSWORD is required}"

LOCATION="${LOCATION:-westeurope}"
RG_NAME="${RG_NAME:-veeam-lab-rg}"
PREFIX="${PREFIX:-veeam-lab}"
ADMIN_USERNAME="${ADMIN_USERNAME:-veeamadmin}"
ALLOWED_RDP_SOURCE="${ALLOWED_RDP_SOURCE:-0.0.0.0/0}"

az account set --subscription "$SUBSCRIPTION_ID"

echo "==> Creating resource group: $RG_NAME ($LOCATION)"
az group create -n "$RG_NAME" -l "$LOCATION" >/dev/null

echo "==> Deploying baseline lab (Bicep)"
az deployment group create \
  -g "$RG_NAME" \
  -n "baseline-$(date +%Y%m%d%H%M%S)" \
  -f "$ROOT/infra/main.bicep" \
  -p \
    prefix="$PREFIX" \
    location="$LOCATION" \
    adminUsername="$ADMIN_USERNAME" \
    adminPassword="$ADMIN_PASSWORD" \
    allowedRdpSource="$ALLOWED_RDP_SOURCE" \
  >/dev/null

echo "==> Baseline lab deployed successfully."
