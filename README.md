./scripts/deploy.sh   # creates rg, deploys bicep, deploys managedapp

./scripts/destroy.sh  # deletes managedapp + managed rg + rg-veeam-lab

export SUBSCRIPTION_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

export ADMIN_PASSWORD="StrongPassword!123"

export ADMIN_USERNAME="veeamadmin"

export LOCATION="westeurope"

export RG_NAME="veeam-lab-rg"

export PREFIX="veeam-lab"

export ALLOWED_RDP_SOURCE="$(curl -s ifconfig.me)/32"

export DEPLOY_VBMA=false
