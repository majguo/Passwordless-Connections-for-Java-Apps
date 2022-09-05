RESOURCE_GROUP=rg-spring-containerapp-passwordless
POSTGRESQL_HOST=psql-spring-containerapp-passwordless
DATABASE_NAME=checklist
DATABASE_FQDN=${POSTGRESQL_HOST}.postgres.database.azure.com
# Note that the connection url does not includes the password-free authentication plugin
# The configuration is injected by spring-cloud-azure-starter-jdbc

# CONTAINER APPS RELATED VARIABLES
ACR_NAME=credenialfreeacr
CONTAINERAPPS_ENVIRONMENT=acaenv-passwordless
CONTAINERAPPS_NAME=aca-passwordless
CONTAINERAPPS_CONTAINERNAME=passwordless-container

LOCATION=eastus
POSTGRESQL_ADMIN_USER=azureuser
# Generating a random password for the PostgreSQL admin user as it is mandatory
# postgres admin won't be used as Azure AD authentication is leveraged also for administering the database
POSTGRESQL_ADMIN_PASSWORD=$(pwgen -s 15 1)

# Get current user logged in azure cli to make it postgres AAD admin
CURRENT_USER=$(az account show --query user.name -o tsv)
CURRENT_USER_OBJECTID=$(az ad user show --id $CURRENT_USER --query id -o tsv)

CURRENT_USER_DOMAIN=$(cut -d '@' -f2 <<<$CURRENT_USER)
# APPSERVICE_LOGIN_NAME=${APPSERVICE_NAME}'@'${CURRENT_USER_DOMAIN}
APPSERVICE_LOGIN_NAME='checklistapp'

# create resource group
az group create --name $RESOURCE_GROUP --location $LOCATION

# create postgresql server
az postgres flexible-server create \
    --name $POSTGRESQL_HOST \
    --resource-group $RESOURCE_GROUP \
    --location $LOCATION \
    --admin-user $POSTGRESQL_ADMIN_USER \
    --admin-password $POSTGRESQL_ADMIN_PASSWORD \
    --public-access 0.0.0.0 \
    --tier Burstable \
    --sku-name Standard_B1ms \
    --storage-size 32 
# create postgres database
az postgres flexible-server db create -g $RESOURCE_GROUP -s $POSTGRESQL_HOST -d $DATABASE_NAME

# create an Azure Container Registry (ACR) to hold the images for the demo
az acr create --resource-group $RESOURCE_GROUP --name $ACR_NAME --sku Standard --location $LOCATION --admin-enabled true

# register container apps extension
az extension add --name containerapp --upgrade
# register Microsoft.App namespace provider
az provider register --namespace Microsoft.App
# create an azure container app environment
az containerapp env create \
    --name $CONTAINERAPPS_ENVIRONMENT \
    --resource-group $RESOURCE_GROUP \
    --location $LOCATION

# Create a user managed identity and assign AcrPull role on the ACR. By creating an user managed identity it is possible to assign AcrPull role before starting the deployment
# the same user manage identity is granted to access to the database
USER_IDENTITY=$(az identity create -g $RESOURCE_GROUP -n $CONTAINERAPPS_NAME --location $LOCATION --query clientId -o tsv)
ACR_RESOURCEID=$(az acr show --name $ACR_NAME --resource-group $RESOURCE_GROUP --query "id" --output tsv)
az role assignment create \
    --assignee "$USER_IDENTITY" --role AcrPull --scope "$ACR_RESOURCEID"

POSTGRESQL_CONNECTION_URL="jdbc:postgresql://${DATABASE_FQDN}:5432/${DATABASE_NAME}?clientid=${USER_IDENTITY}"



# Build JAR file and push to ACR using buildAcr profile
mvn clean package -DskipTests -PbuildAcr -DRESOURCE_GROUP=$RESOURCE_GROUP -DACR_NAME=$ACR_NAME

# Create the container app
az containerapp create \
    --name ${CONTAINERAPPS_NAME} \
    --resource-group $RESOURCE_GROUP \
    --environment $CONTAINERAPPS_ENVIRONMENT \
    --container-name $CONTAINERAPPS_CONTAINERNAME \
    --user-assigned ${CONTAINERAPPS_NAME} \
    --registry-server $ACR_NAME.azurecr.io \
    --image $ACR_NAME.azurecr.io/spring-checklist-passwordless:0.0.1-SNAPSHOT \
    --ingress external \
    --target-port 8080 \
    --cpu 1 \
    --memory 2 \
    --env-vars "SPRING_DATASOURCE_AZURE_CREDENTIALFREEENABLED=true"

# create service connection.
az containerapp connection create postgres-flexible \
    --resource-group $RESOURCE_GROUP \
    --name $CONTAINERAPPS_NAME \
    --container $CONTAINERAPPS_CONTAINERNAME \
    --tg $RESOURCE_GROUP \
    --server $POSTGRESQL_HOST \
    --database $DATABASE_NAME \
    --client-type springboot \
    --system-identity