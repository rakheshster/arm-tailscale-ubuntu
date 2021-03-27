# What is this?

This is an ARM template to create an Ubuntu 20.04 VM in Azure that has TailScale pre-installed. The template create a virtual network (vnet), subnet, network security group, public IP etc. for the VM and by default has no incoming Internet traffic allowed except for a UDP port that makes it easy for TailScale to operate (this is optional as far as I know, so feel free to disable it if you want). The template also creates a disk encryption set and encrypts the disks with a key generated by the template and stored in a key vault it creates. 

## What is TailScale? 
What is TailScale, you ask? Check out [this](https://tailscale.com/) website. It's a WireGuard based mesh network, which means all your TailScale nodes are on a WireGuard VPN network of their own independent of where they actually are (Azure, your home, your phone, etc.) and they talk to each other directly rather than via a centralized VPN server. TailScale also lets you route specific subnets via selected nodes in the mesh network. So this means if I have TailScale deployed in Azure using this template, and I set it as the exit node for all my Azure subnets, and I setup vnet peerings from all my other Azure vnets to the vnet containing this TailScale VM - I can then connect to all my Azure resources without exposing any of them to the public Internet or setting up bastion hosts or Site to Site/ Point to Site VPNs. Nice, huh! 

Of course I could have gone with a VM running WireGuard in Azure, but that would mean hooking up each of my clients to this WireGuard VPN, whereas now I don't have to do anything expect install TailScale on whatever client I am using and it's automatically connected to my home, Azure, etc.

## Required Parameters and inputs
The template takes the following parameters:
  * `virtualMachineName` - the name of the VM. This is optional and defaults to the name of the resource group. 
  * `adminKey` - an SSH key that gets added to the VM so you can SSH into it. Remember you cannot SSH via the public IP - you will have to use the TailScale IP. 
  * `resourceTags` - tags. Optional. The template creates a user account named after the VM with `admin` suffixed to it. 
  * `addressSpace` - the address space of the vnet that's created for this VM. The subnet created in this vnet occupies the entire address space. Be sure to choose a subnet not used by any of your existing vnets as that would interfere with the peering. 

The template has a `cloud-init.txt` script that installs TailScale via cloud-init. There's two things you need to fill there:
  * A pre-authentication key. You can generate one following the steps in [this article](https://tailscale.com/kb/1085/auth-keys) and put it in the cloud-init.txt file. This is what joins the VM to your TailScale network automatically.
  * A list of subnets that will be routed via this node. More information can be found in [this article](https://tailscale.com/kb/1019/subnets). 

# Getting Started
## Using Bash or PowerShell

  1. Clone this repo. 
  2. Edit `artifacts/cloud-init.txt` and the parameters file in `artifacts/` with the required info.
  3. Login to Azure
  4. If using **Bash** do: `./deploy.sh -g <resourceGroup> -d artifacts -l <location>`. 
  4. If using **PowerShell** do: `./Deploy-AzTemplate.ps1 -ResourceGroupName <resourceGroup> -ArtifactStagingDirectory artifacts -Location <location>`
    
Note: 
  * PowerShell Core is sufficient so you can run this from macOS, Linux etc. 
  * If `<resourceGroup>` does not exist it will be created at `<location>`. 
  * If `<resourceGroup>` exists you can skip `-l <location>`.

## Using Azure DevOps Pipelines

  1. Clone this repo.
  2. Create an Azure DevOps pipeline that points to the repo.
  3. Run the pipeline. Fill in the pre-authentication key, SSH key, subnets etc. when prompted. 
