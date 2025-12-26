Deploy it:

RG=rg-veeam-lab
LOC=westeurope

az group create -n $RG -l $LOC

az deployment group create \
  -g $RG \
  -f main.bicep \
  -p adminUsername='veeamadmin' \
  -p adminPassword='REPLACE_ME' \
  -p rdpSourceCidr='YOUR_PUBLIC_IP/32'


Tear it down:

az group delete -n rg-veeam-lab --yes --no-wait

Step 3 — Deploy “Veeam Backup for Microsoft Azure Free Edition” (Marketplace managed app)
3.1 Find Marketplace identifiers (Publisher / Product / Plan)

Microsoft’s guidance: open the offer in Azure Portal Marketplace → Usage Information + Support tab → copy:

Publisher ID

Product ID (Offer ID)

Plan ID (SKU) 
Microsoft Learn
+1

3.2 Accept terms (once per subscription)

For managed apps, Azure notes you can accept terms using the same mechanism as VM offers. 
Microsoft Learn

Example (replace values from “Usage Information”):

az vm image terms accept \
  --publisher veeam \
  --offer azure_backup_free \
  --plan free


(Those strings are placeholders — use the real IDs from the portal.)

3.3 Deploy the managed app (CLI)

Azure CLI supports Marketplace managed apps like this: 
Microsoft Learn
+1

RG=rg-veeam-lab
LOC=westeurope
APPNAME=vbazure-free-lab-01
MANAGED_RG=/subscriptions/$(az account show --query id -o tsv)/resourceGroups/rg-vbazure-managed

az group create -n $RG -l $LOC
az group create -n rg-vbazure-managed -l $LOC

az managedapp create \
  -g $RG \
  -n $APPNAME \
  -l $LOC \
  --kind MarketPlace \
  -m "$MANAGED_RG" \
  --plan-publisher "<PublisherId>" \
  --plan-product   "<ProductId>" \
  --plan-name      "<PlanId>" \
  --plan-version   "<PlanVersion>" \
  --parameters @vbazure.parameters.json


Where vbazure.parameters.json contains the marketplace-required fields (region, networking mode, etc). Those parameter names differ by offer version; the easiest way to capture them:

Deploy once in portal

Go to the RG → Deployments → export the template/parameters

Reuse them for fully automated redeployments (Microsoft recommends this workflow for Marketplace programmatic deployment). 
Microsoft Learn

Destroy VB for Azure

Delete the app + managed RG:

az managedapp delete -g rg-veeam-lab -n vbazure-free-lab-01
az group delete -n rg-vbazure-managed --yes --no-wait
