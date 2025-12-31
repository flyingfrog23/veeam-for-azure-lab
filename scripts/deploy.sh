SUBSCRIPTION_ID="xxxx"
LOCATION="westeurope"
RG_NAME="veeam-lab-rg"
MRG_NAME="veeam-vbma-mrg"

az account set --subscription "$SUBSCRIPTION_ID"
az group create -n "$RG_NAME" -l "$LOCATION"

az deployment group create \
  -g "$RG_NAME" \
  -f infra/main.bicep \
  -p adminUsername=veeamadmin adminPassword="$ADMIN_PASSWORD"

az managedapp create \
  --resource-group "$RG_NAME" \
  --name veeam-vbma-lab \
  --location "$LOCATION" \
  --kind MarketPlace \
  --managed-rg-id "/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$MRG_NAME" \
  --plan-name veeambackupazure_free_v6_0 \
  --plan-product azure_backup_free \
  --plan-publisher veeam \
  --plan-version 6.0.234
