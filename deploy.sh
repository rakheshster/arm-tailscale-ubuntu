#!/bin/bash
set -eo pipefail
IFS=$'\n\t'

# -e: immediately exit if any command has a non-zero exit status
# -o: prevents errors in a pipeline from being masked
# IFS new value is less likely to cause confusing bugs when looping arrays or arguments (e.g. $@)

# defining some colours
# see https://stackoverflow.com/questions/4332478/read-the-current-text-color-in-a-xterm/4332530#4332530 for more
normal=$(tput sgr0)
blue=$(tput setaf 4)
powder_blue=$(tput setaf 153)
yellow=$(tput setaf 3)
lime_yellow=$(tput setaf 190)
red=$(tput setaf 1)
bold=$(tput bold)
underline=$(tput smul)

function usage {
    printf "%s\n\n" "${blue}Usage: ${normal}${bold} $0 -g <resourceGroupName> -d <artifactsStagingDirectory> [-l <resourceGroupLocation>] [-s <artifactsStorageAccount>] [-t <templateFilePath>] [-p <parametersFilePath>]${normal}" 1>&2; 

	printf "%s\n" "${powder_blue}Note 1: ${normal} If the template contains an ${bold}_artifactsLocation${normal} parameter then the contents of <artifactsStagingDirectory> will be uploaded to a storage account you specify via <artifactsStorageAccount>" 1>&2;
    printf "%s\n" "${powder_blue}Note 2: ${normal} In the case of note 1 if no storage account is specified then ${underline}a random storage account will be created${normal} for this purpose" 1>&2;

	printf "%s\n" "${powder_blue}Note 3: ${normal} If the specified <resourceGroupName> does not exist it will be created if <resourceGroupLocation> is specified"  1>&2;
    printf "%s\n" "${powder_blue}Note 4: ${normal} If <templateFilePath> or <paramtersFilePath> are not specified then <artifactsStagingDirectory>/azuredeploy.json and <artifactsStagingDirectory>/azuredeploy.parameters.json are tried"  1>&2;
	exit 1;
}

# initialize parameters specified from command line
# if a flag expects and argument put a ":" after it else skip
# I start with a ":" because I want to disable getopts' error handling and do it myself
while getopts ":g:d:s:l:t:p:" o; do
	case "${o}" in
		g)
			resourceGroupName=${OPTARG}
			;;
		d)
			artifactsStagingDirectory=${OPTARG}
			;;
		l)
			resourceGroupLocation=${OPTARG}
			;;
        s) 
			artifactsStorageAccount=${OPTARG}
            ;;
		t)
			templateFilePath=${OPTARG}
			;;
		p)
			parametersFilePath=${OPTARG}
			;;
		\?)
			usage
			;;
	esac
done
shift $((OPTIND-1))

# show usage and exit if mandatory parameters are not specified
if [ -z $artifactsStagingDirectory ] || [ -z $resourceGroupName ]; then 
	usage
fi

# check for the jq command
if ! command -v jq &> /dev/null; then 
	echo -e "${red}==> ${normal}${bold}Cannot find jq. Please install it and retry.${normal}"; 
	exit 1; 
fi

# check if we are logged in and exit script if not.
# this is a little workaround to see if we are still logged in. the `list-locations` subcommand needs you to be logged in.
# other `az account` subcommands seem to rely on cached information.
echo -e "${blue}==> ${normal}${bold}Checking if we are logged in${normal}"
az account list-locations >/dev/null || exit 1 && echo -e "${powder_blue}==> ${normal}${bold}Success!${normal}"

unset rgLocation
# show usage and exit if mandatory parameters are not specified
# check if the resourcegroup exists
rgLocation=`az group list | jq -r --arg resourceGroupName "$resourceGroupName" 'map(select(.name == $resourceGroupName)) | .[] | .location'`
if [ ! -z "$rgLocation" ]; then
    # $rgLocation is not empty; that means the resourceGroup exists. let's capture the location for future use
    resourceGroupLocation=$rgLocation
    echo -e "${blue}==> ${normal}${bold}Specified resource group ${resourceGroupName} exists at location ${resourceGroupLocation}${normal}"
else
    if [ ! -z "$resourceGroupLocation" ]; then
        # the resource group doesn't exist but we do have a location so let's create one
        echo -e "${yellow}==> ${normal}${bold}Couldn't find resource group ${resourceGroupName} so will create a new one at location ${resourceGroupLocation}${normal}"
        az group create --name $resourceGroupName --location $resourceGroupLocation
    else
        echo -e "${red}==> ${normal}${bold}Unable to find resource group ${resourceGroupName} and no location's specified to create a new one${normal}"
        exit 1
    fi
fi

# default templatefile if none specified
if [ -z "$templateFilePath" ]; then
	templateFilePath="${artifactsStagingDirectory}/azuredeploy.json"
	
	if [ -e "$templateFilePath" ]; then
		echo -e "${blue}==> ${normal}${bold}Found and will use ${templateFilePath} as the template${normal}"
	else
		echo -e "${red}==> ${normal}${bold}Missing templateFilePath. Tried ${templateFilePath}${normal}"
		exit 1
	fi
fi

# default parametersfile if none specified
if [ -z "$parametersFilePath" ]; then
	parametersFilePath="${artifactsStagingDirectory}/azuredeploy.parameters.json"

	if [ -e "$parametersFilePath" ]; then
		echo -e "${blue}==> ${normal}${bold}Found and will use ${parametersFilePath} as the parameters file${normal}"
	else
		echo -e "${yellow}==> ${normal}${bold}Continuing without a parameters file as none was specifed and nothing found at ${parametersFilePath} either${normal}"
		unset parametersFilePath
	fi
fi

unset uploadRequired
unset artifactsUrlRequired
# Check the template file to see if there's any mention of artifacts
# jq doesn't like comments so I strip them out first
testForArtifacts=`grep -v "^\s*//" ${templateFilePath} | jq -r '.parameters._artifactsLocation'`
if [ "$testForArtifacts" == "null" ]; then
	uploadRequired=false
else
	uploadRequired=true
fi

# if there is mention of artifacts then we must upload to the storage account
if [ "$uploadRequired" == "true" ]; then
	# explictly unset this variable so I know it's not set at the beginning of this 
	unset artifactsLocation
	unset artifactsLocationSasToken
	unset createstorageaccount


	# if there's a parameters file read it for the value of artifacts location & token
	if [ ! -z "$parametersFilePath" ]; then
        echo -e "${yellow}==> ${normal}${bold}If you get an error at this stage look for comments in ${parametersFilePath} and remove them${normal}"
		artifactsLocation=`grep -v "^\s*//" ${parametersFilePath} | jq -r '.parameters._artifactsLocation.value'`
	fi

	# if I found something above the variable wouldn't be null (no property) or "" (no value set). or it would still be unset if we don't have a params file.
	# if this is the case read from the template file to see if it has a defaultValue
	if [ -z $artifactsLocation ] || [ "$artifactsLocation" == "" ] || [ "$artifactsLocation" == "null" ]; then
        echo -e "${yellow}==> ${normal}${bold}If you get an error at this stage look for comments in ${templateFilePath} and remove them${normal}"
		artifactsLocation=`grep -v "^\s*//" ${templateFilePath} | jq -r '.parameters._artifactsLocation.defaultValue'`
	fi

	# if it is empty still that means we don't have any location specified. 
	# so we'll have to provide the URL of the storage account as a parameter later
	if [ -z "$artifactsLocation" ] || [ "$artifactsLocation" == "" ]; then
		artifactsUrlRequired=true
	fi

	# I will create a container that has the resourceGroupName (in lower letters) with -stageartifacts suffixed
	resourceGroupNameLower=`echo $resourceGroupName | tr "[:upper:]" "[:lower:]" | cut -c1-20`
	containername="${resourceGroupNameLower}-stageartifacts"

	# was any storage account specified? 
	if [ -z "$artifactsStorageAccount" ]; then
		# if no storage account is specified get our subscription id, strip dashes, extract the first 10 chars
		tempId=`az account show | jq -r '.id' | tr -d '-' | cut -c1-10`
		# add that to some random numbers ($RANDOM is an in-built bash variable) to create a storage account name
		artifactsStorageAccount="stage${tempId}${RANDOM}"
		createstorageaccount=true
		echo -e "${yellow}==> ${normal}${bold}No storage account was specified. Will create ${artifactsStorageAccount}${normal}"
	else 
		# a storage account was specified, lets see if it exists
		testForStorageAccount=`az storage account check-name --name ${artifactsStorageAccount} | jq -r '.nameAvailable'`
		if [ "$testForStorageAccount" == "false" ]; then
			# the account exists and we can use that
			createstorageaccount=false
			echo -e "${blue}==> ${normal}${bold}Found storage account ${artifactsStorageAccount}${normal}"
			# create the container within this storage account
			echo -e "${powder_blue}==> ${normal}${bold}Creating a container ${containername} within storage account ${artifactsStorageAccount}${normal}"
			echo -e "${yellow}==> ${normal}${bold}If this step fails it could be that the specified storage account exists but does not belong to you${normal}"
			az storage container create -n ${containername} --account-name ${artifactsStorageAccount}
		else
			# the account does not exist, we need to create it
			createstorageaccount=true
			echo -e "${yellow}==> ${normal}${bold}Specified storage account ${artifactsStorageAccount} does not exist and will be created${normal}"			
		fi
	fi

	# create a storage account if required
	if [ "$createstorageaccount" == "true" ]; then
		echo -e "${blue}==> ${normal}${bold}Creating storage account $artifactsStorageAccount in resource group $resourceGroupName${normal}"
		az storage account create -n $artifactsStorageAccount -g $resourceGroupName -l $resourceGroupLocation --sku Standard_LRS
		
		# if that went well create the container
		if [ $? -eq 0 ]; then
			echo -e "${powder_blue}==> ${normal}${bold}Creating a container ${containername} within storage account ${artifactsStorageAccount}${normal}"
			az storage container create -n ${containername} --account-name ${artifactsStorageAccount} --auth-mode login
		else
			echo -e "${red}==> ${normal}${bold}Error creating a storage account ${artifactsStorageAccount}${normal}"
			exit 1;
		fi
	fi	

	# generate a SAS token and URL as we need it (there was nothing found in the template/ parameters file above)
	# set the expiry of this to be 10 mins
	if [ "$artifactsUrlRequired" == "true" ]; then
		# generate a SAS token
		if [ $(uname) == "Darwin" ]; then
			sasexpiry=`date -v+2H '+%Y-%m-%dT%H:%MZ'`
		else
			sasexpiry=`date -u -d "2 hours" '+%Y-%m-%dT%H:%MZ'`
		fi

		echo -e "${blue}==> ${normal}${bold}Creating access tokens and URI${normal}"
		# create a storage account token
		# https only; read permissions only 'r'; to the blob service only 'b'; for resource types container and object only 'co'
		# the token needs some massaging to remove " and I gotta add a ?
		artifactsLocationSasTokenTemp=`az storage account generate-sas --permissions r --account-name ${artifactsStorageAccount} --services b --resource-types co --expiry $sasexpiry | jq -r`
		artifactsLocationSasToken="?${artifactsLocationSasTokenTemp}"
		
		artifactsLocationBlobEndpoint=`az storage account show --name ${artifactsStorageAccount} -g $resourceGroupName | jq -r '.primaryEndpoints.blob'`
		artifactsLocation="${artifactsLocationBlobEndpoint}${containername}/"
	fi

	# now let's upload
	# loop through each file in the staging directory and upload
	for filename in ${artifactsStagingDirectory}/*; do
		az storage blob upload --name $(basename $filename) --container-name ${containername} --file $filename --account-name ${artifactsStorageAccount} 
	done
fi

# Start deployment
echo -e "${blue}==> ${normal}${bold}Starting deployment${normal}"
if [ "$artifactsUrlRequired" == "false" ]; then
	az deployment group create --resource-group "$resourceGroupName" --template-file "$templateFilePath" --parameters "$parametersFilePath"
else
	az deployment group create --resource-group "$resourceGroupName" --template-file "$templateFilePath" --parameters "$parametersFilePath" --parameters _artifactsLocation="${artifactsLocation}" --parameters _artifactsLocationSasToken="${artifactsLocationSasToken}"
fi