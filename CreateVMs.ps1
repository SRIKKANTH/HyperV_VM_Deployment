########################################################################
#
# Linux on Hyper-V and Azure Test Code, ver. 1.0.0
# Copyright (c) Microsoft Corporation
#
# All rights reserved.
# Licensed under the Apache License, Version 2.0 (the ""License"");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#     http://www.apache.org/licenses/LICENSE-2.0
#
# THIS CODE IS PROVIDED *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS
# OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION
# ANY IMPLIED WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR
# PURPOSE, MERCHANTABLITY OR NON-INFRINGEMENT.
#
# See the Apache Version 2.0 License for specific language governing
# permissions and limitations under the License.
#
########################################################################

<#
.Synopsis
    Automation to create a VM based on a set of parameters.

.Description
    For a VM to be created, the VM definition in the .xml file must
   include a hardware section.  The <parentVhd> and at least one
   <nic> tag must be part of the hardware definition.  In addition,
   if you  want the VM to be created, the <create> tag must be present
   and set to the value "true".  The remaining tags are optional.

   Before creating the VM, the script will check to make sure all
   required tags are present. It will also check the values of the
   settings.  If the VM exceeds the HyperV's resources, a warning message
   will be displayed, and default values will override the specified
   values.

   If a VM with the same name already exists on the HyperV
   server, the VM will be deleted.

.Parameter testParams
    Tag definitions:
       <hardware>    Start of the hardware definition section.

       <create>      If the tag is defined, and has a value of "true"
                     the VM will be created.

       <numCPUs>     The number of CPUs to assign to the VM

       <memSize>     The amount of memory to allocate to the VM.
                     Memory size can be specified as MB or GB. If
                     no unit indicator is present, MB is assumed.
                        size
                        size MB
                        size GB

       <parentVhd>   The name of the .vhd file to use as the parent
                     of the VMs boot disk.  This may be a relative
                     path, or an absolute path.  If a relative path
                     is specified, the HyperV servers default path
                     for VHDs will be prepended.

       <disableDiff> When set to true, use parentVhd as the boot disk.
                     Otherwise, a differencing disk is used instead.

       <isCluster>   When set to true, the vm will be created on the cluster
                     storage. The vhd will also be copied in the cluster
                     storage. Finally, the vm will be configured for
                     high availability

       <nic>         Defines a NIC to add to the VM. The VM must have
                     at least one <nic> tag, but multiple <nic> are
                     allowed.  The <nic> defines the NIC to add to the
                     VM as follows:
                         <nic>NIC type, Network name, MAC address</nic>
                     Where:
                         NIC type is either VMBus or Legacy
                         Network Name is the name of an existing
                                      HyperV virtual switch
                         MAC address is optional.  If present, a static
                                      MAC address will be assigned to the
                                      new NIC. Otherwise a dynamic MAC is used.

       <imageStoreDir>	A directory to locate the parentVhd, can be either a UNC or local path

       <generation>	Set to 1 to create a gen 1 VM, set to 2 to create a gen 2 VM. If nothing
                     is specified, it will use gen 1.

       <secureBoot>	Define whether to enable secure boot on gen 2 VMs. Set to "true" or "false".
                     If VM is gen 1 or if not specified, this will be false.
       <DataVhd>	List of SCSI data disk sizes to be created and attached. 
					Example: <DataVhd>2GB,10GB</DataVhd> 

.Example
   Example VM definition with a hardware section:
	<Config>
		<global>
			<imageStoreDir></imageStoreDir>
		</global>
		<vm>
			<hvServer>hvServer</hvServer>
			<vmName>VMname</vmName>
			<ipv4>1.2.3.4</ipv4>
			<sshKey>pki_id_rsa.ppk</sshKey>
			<tests>CheckLisInstall, Hearbeat</tests>
			<hardware>
				<create>true</create>
				<numCPUs>2</numCPUs>
				<memSize>1024</memSize>
				<parentVhd>distro.vhd</parentVhd>
				<nic>Legacy,InternalNet</nic>
				<nic>VMBus,ExternalNet</nic>
				<generation>1</generation>
				<secureBoot>false</secureBoot>
				<DataVhd>2GB,10GB</DataVhd>
			</hardware>
		</vm>
		<TEST>
			<TEST_APP_ZIP>C:\Users\Srikantha\source\repos\WebApplication1\WebApplication1\bin\Debug\PublishOutput.zip</TEST_APP_ZIP>
		</TEST>
	</Config>

#>

param (
    [String] $xmlFile = "SampleConfig.xml",
    [switch] $Debug = $false
)

$dbgLevel_Debug = 10
$dbgLevel_Release = 1
if ($Debug) {
    $dbgLevel = $dbgLevel_Debug
}
else {
    $dbgLevel = $dbgLevel_Release
}

$WorkingDir = (Get-Item -Path ".\").FullName
$DateString = $((Get-Date).ToString('yyyy_MM_dd_hh_mm_ss'))
$LogDir = "Logs\$DateString"
$LogFolder = "$($WorkingDir)\$($LogDir)"
$logfile = "$($LogFolder)\LocalLogFile.log"

New-Item -ItemType Directory -Force -Path $LogFolder | out-null

$exitStatus = 1

. .\libs\stateEngine.ps1
. .\libs\sshUtils.ps1

#######################################################################
#
# GetRemoteFileInfo()
#
# Description:
#    Use WMI to retrieve file information for a file residing on the
#    Hyper-V server.
#
# Return:
#    A FileInfo structure if the file exists, null otherwise.
#
#######################################################################
function GetRemoteFileInfo([String] $filename, [String] $server ) {
    $fileInfo = $null

    if (-not $filename) {
        return $null
    }

    if (-not $server) {
        return $null
    }

    $remoteFilename = $filename.Replace("\", "\\")

    $fileInfo = Get-WmiObject -query "SELECT * FROM CIM_DataFile WHERE Name='${remoteFilename}'" -computer $server

    return $fileInfo
}

#######################################################################
#
# DeleteVmAndVhd()
#
# Description:
#
#######################################################################
function DeleteVmAndVhd([String] $vmName, [String] $hvServer, [String] $vhdFilename) {
    #
    # Delete the VM - make sure it does exist
    #
    $vm = Get-VM $vmName -ComputerName $hvServer -ErrorAction SilentlyContinue

    # Delete Role from cluster if it is already present
    Get-Command "Get-ClusterResource" -ErrorAction SilentlyContinue
    if ($?) {
        $group = Get-ClusterGroup -ErrorAction SilentlyContinue
        $vm_matches = $group -match $vmName
        foreach ($vm_match in $vm_matches) {
            Remove-ClusterGroup -Name $vm_match.name -RemoveResources -Force
            if (-not $?) {
                "Error: Failed to remove Cluster Role for VM $vmName"
                return $False
            }

            "Cleanup was successful for $vmName"
        }

        # Also remove VM from second node if it's located there
        if (Get-ClusterGroup -ErrorAction SilentlyContinue) {
            $currentNode = (Get-Clusternode -Name $env:computername).Name.ToLower()
            $clusterNodes = Get-ClusterNode
            if ($currentNode -eq $clusterNodes[0].Name.ToLower()) {
                $destinationNode = $clusterNodes[1].Name.ToLower()
            }
            else {
                $destinationNode = $clusterNodes[0].Name.ToLower()
            }

            if (Get-VM -Name $vmName -ComputerName $destinationNode -ErrorAction SilentlyContinue) {
                Remove-VM $vmName -ComputerName $destinationNode -Force
            }
        }
    }

    if ($vm) {
        if (Get-VM -Name $vmName -ComputerName $hvServer | Where-Object { $_.State -like "Running" }) {
            Stop-VM $vmName -ComputerName $hvServer -TurnOff
            if (-not $?) {
                LogMsg 0 "Error: Unable to turn off $vmName in order to remove it!"
                return $False
            }
        }

        LogMsg 0 "Info: Cleanup: Deleting existing VM '$vmName'.."
        Remove-VM $vmName -ComputerName $hvServer -Force
    }

    #
    # Try to delete the .vhd file if we were given a filename, and the file exists
    #
    if ($vhdFilename) {
        $fileInfo = GetRemoteFileInfo $vhdFilename -server $hvServer
        if ($fileInfo) {
            $fileInfo.Delete()
        }
    }
}

function GetParentVhd([System.Xml.XmlElement] $vm, [XML]$xmlData) {
    $parentVhd = ""
    LogMsg 9 "Debug: VMNAME $vm.vmName"
    #
    # Make sure the parent .vhd file exists
    #
    if ($vm.hardware.parentVhd) {
        $parentVhd = $vm.hardware.parentVhd
        if ([System.IO.Path]::IsPathRooted($parentVhd)) {
            LogMsg 0 "Info: Found a vhd at '$parentVhd'"
            return $parentVhd
        }
        else {
            $PathArray = @($(Join-Path (Get-Item -Path ".\").FullName "ParentVhds"), $((Get-VMHost -ComputerName $hvServer).VirtualHardDiskPath), $xmlData.Config.global.imageStoreDir)

            For ($i = 0; $i -lt $PathArray.Length; $i++) {
                if ($PathArray[$i]) {
                    if (Test-Path $PathArray[$i]) {
                        $TempParentVhd = Join-Path $PathArray[$i] $parentVhd
                        if ((test-path $TempParentVhd)) {
                            LogMsg 9 "Debug: Found a vhd at '$TempParentVhd'"
                            return $TempParentVhd
                        }
                    }
                }
            }
        }

        $uriPath = New-Object -TypeName System.Uri -ArgumentList $parentVhd
        if ($uriPath.IsUnc) {
            if (-not $(Test-Path $parentVhd)) {
                LogMsg 0 "Error: Remote parent vhd file ${parentVhd} does not exist."
                return $False
            }
        }
        else {
            $fileInfo = GetRemoteFileInfo $parentVhd $hvServer
            if (-not $fileInfo) {
                LogMsg 0 "Error: The parent .vhd file ${parentVhd} does not exist for ${vmName}"
                return $False
            }
        }
        LogMsg 9 "Debug: parentVhd=$parentVhd"
    }
    elseif ($vm.hardware.importVM) {
        #
        # Verify the .xml file for the import VM exists
        #
        $importVmInfo = GetRemoteFileInfo $vm.hardware.importVM
        if (-not $fileInfo) {
            LogMsg 0 "Error: The importVM xml file does not exist, or cannot be accessed"
            return $False
        }
    }
    else {
        LogMsg 1 "Warn: As no valid vhd provided. Now I will try to get the latest .vhd file from the default locations."
        $PathArray = @($(Join-Path (Get-Item -Path ".\").FullName "ParentVhds"), $xmlData.Config.global.imageStoreDir, $((Get-VMHost -ComputerName $hvServer).VirtualHardDiskPath))

        For ($i = 0; $i -lt $PathArray.Length; $i++) {
            if ($PathArray[$i]) {
                if (Test-Path $PathArray[$i]) {
                    $latestFile = Join-Path $PathArray[$i] "latest"
                    if (Test-Path $latestFile) {
                        $parentVhd = Get-Content $latestFile
                    }
                    else {
                        $TempParentVhd = $(Get-ChildItem $PathArray[$i] | Where-Object { $_.Extension -eq ".vhd" -or $_.Extension -eq ".vhdx" } | Sort LastWriteTime | Select -Last 1).Name
                        if ($TempParentVhd) {
                            if ((test-path $(Join-Path $PathArray[$i] $TempParentVhd))) {
                                $parentVhd = Join-Path $PathArray[$i] $TempParentVhd
                                LogMsg 9 "Debug: Found a vhd at '$parentVhd'"
                                LogMsg 1 "Warn: As no valid vhd provided. I will use '$parentVhd' as parentVhd."
                                LogMsg 1 "Warn: This might cause issues like login credential mismatch etc.,"
                                LogMsg 1 "Warn: To avoid this, provide the right path for reference .vhd file in <parentVhd> tag of the '$xmlFile'"
                                return $parentVhd
                            }
                        }
                    }
                }
            }
        }    
    }
    LogMsg 1 "Error: Unable to get Parentvhd file exitting now..."
    exit 1
}
#######################################################################
#
# CheckRequiredParameters()
#
# Description:
#    Check the XML data for the VM to make sure all required tags
#    are present. Next, check the values of the tags to make sure
#    they are valid values.
#
#######################################################################
function CheckRequiredParameters([System.Xml.XmlElement] $vm, [XML]$xmlData) {
    #
    # Make sure the required tags are present
    #
    if (-not $vm.vmName) {
        LogMsg 0 "Error: VM $($vm.vmName) in '$xmlFile' is missing a 'vmName' tag"
        return $False
    }

    if (-not $vm.hvServer) {
        LogMsg 0 "Error: VM $($vm.vmName) in '$xmlFile' is missing a 'hvServer' tag"
        return $False
    }
    if (-not $vm.userName) {
        LogMsg 0 "Error: VM $($vm.vmName) in '$xmlFile' is missing a 'userName' tag"
        return $False
    }

    if (-not $vm.passWord) {
        LogMsg 0 "Error: VM $($vm.vmName) in '$xmlFile' is missing a 'passWord' tag"
        return $False
    }

    if (-not $vm.StartupScript) {
        LogMsg 0 "Warn: VM $($vm.vmName) in '$xmlFile' is missing a 'StartupScript' tag, **No Scripts will be executed once the VM creation is done.**"
    }

    $vmName = $vm.vmName
    $hvServer = $vm.hvServer

    $vhdDir = GetVhdDir $xmlData

    $vhdName = "${vmName}.vhd"
    $vhdFilename = "\\" + $hvServer + "\" + $vhdDir + $vhdName
    $vhdFilename = $vhdFilename.Replace(":", "$")
    DeleteVmAndVhd $vmName $hvServer $vhdFilename

    #
    # Make sure the future boot disk .vhd file does not already exist
    #
    $fileInfo = GetRemoteFileInfo $vhdFilename -server $hvServer
    if ($fileInfo) {
        LogMsg 0 "Error: The boot disk .vhd file for VM '${vmName}' already exists. VHD = ${vhdFilename}"
        return $False
    }

    #
    # Make sure the parent .vhd file exists
    #
    $parentVhd = GetParentVhd $vm  $xmlData
    if ( -not $parentVhd) {
        LogMsg 0 "Error: Unable to find parentVhd file`n Exitting now..."
        exit 1
    }

    $dataVhd = $vm.hardware.DataVhd
    if ($dataVhd) {
        if (0) {
            if (-not ([System.IO.Path]::IsPathRooted($dataVhd)) ) {
                
                $vhdDir = GetVhdDir( $xmlData )

                #				$vhdDir = $(Get-VMHost -ComputerName $hvServer).VirtualHardDiskPath
                $dataVhdFile = Join-Path $vhdDir $dataVhd
            }

            $fileInfo = GetRemoteFileInfo $dataVhdFile $hvServer
            if (-not $fileInfo) {
                LogMsg 0 "Error: The parent .vhd file '${dataVhd}' does not exist for ${vmName}"
                return $False
            }
        }
    }

    #
    # Now check the optional parameters
    #
    if ($xmlData.Config.TEST.TEST_APP_ZIP) {
        LogMsg 9 "Debug: Copying the "
        Copy-Item $xmlData.Config.TEST.TEST_APP_ZIP -Destination "files"
    }
    #
    # If numCPUs is present, make sure its value is within a valid range.
    #
    if ($vm.hardware.numCPUs) {
        if ([int]$($vm.hardware.numCPUs) -lt 1) {
            LogMsg 0 "Warn: The numCPUs for VM '${vmName}' is less than 1. numCPUs has been set to 1"
            $vm.hardware.numCPUs = "1"
        }

        #
        # Use WMI to ask for the number of logical processors on the HyperV server
        #
        $processors = GWMI Win32_Processor -computer $hvServer
        if (-not $processors) {
            LogMsg 0 "Warn: Unable to determine the number of processors on HyperV server '${hvServer}'. numCPUs has been set to 1"
            $vm.hardware.numCPUs = "1"

        }
        else {
            $CPUs = $processors.NumberOfLogicalProcessors

            $maxCPUs = 0
            foreach ($result in $CPUs) { $maxCPUs += $result }

            if ($maxCPUs -and [int]$($vm.hardware.numCPUs) -gt $maxCPUs) {
                LogMsg 0 "Warn: The numCPUs for VM '${vmName}' is larger than the HyperV server supports (${maxCPUs})."
                $maxCPUs -= 1
                LogMsg 0 "Warn: 'numCPUs' has been set to * $maxCPUs * (leaving 1 for the host)."
                $vm.hardware.numCPUs = "$maxCPUs"
            }
        }
    }

    #
    # If memSize is present, make sure it is within a valid range, then convert
    # it to MB.  If a unit specifier is not present, assume MB. Only MB and GB
    # are supported.  Strings can be in any of the following formats:
    #        "2048"
    #        "2048MB"       "2048GB"
    #        "2040 MB"      "2048 GB"
    #
    if ($vm.hardware.memSize) {
        #
        #    Use regular expressions to parse the memory size string
        #    and convert the value to MB.  Whitespace is parsed out.
        #
        $regex = [regex] '^(\d+)\s*([MG]B)?$'

        $memStr = $vm.hardware.memSize.Trim().ToUpper()
        $mbMemSize = "1024"

        if ( "$memStr" -match "$regex" ) {
            switch ($matches.Count) {
                2 { $mbMemSize = $matches[1] }
                3 {
                    $mbMemSize = $matches[1]
                    if ($matches[2] -eq "GB" ) {
                        $mbMemSize = ([uint64] $matches[1]) * 1KB
                    }
                }
                default {
                    LogMsg 0 "Warn: Invalid memSize. MemSize defaulting to 1024MB"
                }
            }
        }
        else {
            LogMsg 0 "Warn: Invalid memSize. MemSize defaulting to 1024 MB"
        }

        $vm.hardware.memSize = $mbMemSize

        #
        # Make sure the memSize value is reasonable for the host.
        # We picked 512 MB as the lowest amount of memory we will allow.
        #
        $memSize = [Uint64] $vm.hardware.memSize
        if ($memSize -lt 512) {
            LogMsg 0 "Warn: The memSize for VM ${vmName} is below the minimum of 512 MB. memSize set to the default value of 512 MB"
            $vm.hardware.memSize = "512"
        }

        $physMem = GWMI Win32_PhysicalMemory -computer $hvServer
        if ($physMem) {
            #
            # Make sure requested memory does not exceed the HyperV servers max
            #
            $totalMemory = [Uint64] 0
            foreach ($slot in $physMem) {
                $totalMemory += $slot.Capacity
            }

            $memInMB = $totalMemory / 1MB
            $mbMemSize = [uint64]$mbMemSize
            if ($mbMemSize -gt $memInMB) {
                LogMsg 0 "Warn: The memSize for VM '${vmName}' is larger than the HyperV servers physical memory. memSize set to the default size of 512 MB"
                $vm.hardware.memSize = "512"
            }
        }
    }

    $validNicFound = $true
    if ($vm.hardware.network) {
        $validNicFound = $false
        foreach ($nic in $vm.hardware.network.nic) {
            #
            # Make sure there are three parameters specified
            #
            $tokens = $nic.Trim().Split(",")
            if (-not $tokens -or $tokens.Length -lt 2 -or $tokens.Length -gt 3) {
                LogMsg 0 "Error: Invalid NIC defnintion for VM ${vmName}: $nic"
                "       Syntax is 'nic type, network name', 'MAC address'"
                "       Valid nic types: Legacy, VMBus"
                "       The network name must be a valid switch name on the HyperV server"
                "       MAC address is optional.  If present, it is the 12 hex digit"
                "       MAC address to assign to the new NIC. If missing, a dynamic MAC"
                "       address will be assigned to the NIC."
                "       The NIC was not added to the VM"
                Continue
            }

            #
            # Extract the three NIC parameters
            #
            $nicType = $tokens[0].Trim()
            $networkName = $tokens[1].Trim()

            #
            # Was a valid adapter type specified
            #
            if (@("Legacy", "VMBus") -notcontains $nicType) {
                LogMsg 0 "Error: Unknown NIC adapter type: ${nicType}"
                "       The value must be one of: Legacy, VMBus"
                "       The NIC will not be added to the VM"
                Continue
            }

            #
            # Does the specified network name exist on the HyperV server
            #
            $validNetworks = @()
            $availableNetworks = Get-VMSwitch -ComputerName $hvServer
            if ($availableNetworks) {
                foreach ($network in $availableNetworks) {
                    $validNetworks += $network.Name
                }
            }
            else {
                LogMsg 0 "Error: Unable to determine available networks on HyperV server ${hvServer}"
                "       The NIC will not be added (${nic})"
                Continue
            }

            #
            # Is the network name known on the HyperV server
            #
            if ($validNetworks -notcontains $networkName) {
                LogMsg 0 "Error: The network name ${networkName} is unknown on HyperV server ${hvServer}"
                "         The NIC will not be added to the VM"
                Continue
            }

            $macAddress = $null
            if ($tokens.Length -eq 3) {
                #
                # Strip out any colons, hyphens, other junk and leave only hex digits
                #
                $macAddress = $tokens[2].Trim().ToLower() -replace '[^a-f0-9]', ''

                #
                # If 12 hex digits long, it's a valid MAC address
                #
                if ($macAddress.Length -ne 12) {
                    LogMsg 0 "Error: The MAC address ${macAddress} has an invalid length"
                    Continue
                }
            }

            $validNicFound = $True
        }
    }
    #
    # If we got here, our final status depends on whether a valid NIC was found
    #
    return $validNicFound
}

function GetVhdDir( [XML] $xmlData ) {
    if ( $xmlData.Config.global.isCluster -eq "True") {
        Get-Cluster
        if ($? -eq $False) {
            LogMsg 0 "Error: Server '$($xmlData.Config.VMs.VM.hvServer)' doesn't have a cluster set up"
            return $False
        }
        $clusterDir = Get-ClusterSharedVolume
        $vhdDir = $clusterDir.SharedVolumeInfo.FriendlyVolumeName
    }
    elseif ($xmlData.Config.VMs.VM.hvServer -eq "localhost") {
        $vhdDir = Join-Path $(Get-Location) "ParentVhds"
    }
    else {
        $vhdDir = $(Get-VMHost -ComputerName $xmlData.Config.VMs.VM.hvServer ).VirtualHardDiskPath
    }

    if ( -not (Test-Path $vhdDir)) {
        LogMsg 0 "Error: Path $vhdDir given as parameter does not exist"
        exit 1
    }

    if ($vhdDir.EndsWith("\")) {
        $vhdDir = $vhdDir.Substring(0, $vhdDir.Length - 1)
    }
    return $vhdDir
}
#######################################################################
#
# CreateVM()
#
# Description:
#
#######################################################################
function CreateVM([System.Xml.XmlElement] $vm, [XML] $xmlData) {
    $retVal = $False

    $vmName = $vm.vmName
    $hvServer = $vm.hvServer
    $vhdFilename = $null
    $parentVhd = $null

    if (-not $vm.hardware.create -or $vm.hardware.create -ne "true") {
        #
        # The create attribute is missing, or it is not true.
        # So, nothing to do
        LogMsg 0 "Info : VM '${vmName}' does not have a create attribute, or the create attribute is not set to True
                  The VM will not be created"
        return $True
    }

    #
    # Check the parameters from the .xml file to make sure they are
    # present and valid
    #
    # Use the @() operator to force the return value to be an array
    $dataValid = @(CheckRequiredParameters $vm $xmlData)
    if ($dataValid[ $dataValid.Length - 1] -eq "True") {
        #
        # Create the VM
        #
        LogMsg 0 "Info: Required parameters check done, creating VM..."

        $vmGeneration = 1
        if ($vm.hardware.generation) {
            $vmGeneration = [int16]$vm.hardware.generation
        }

        if ( $vm.hardware.isCluster -eq "True") {
            $clusterDir = Get-ClusterSharedVolume
            $vmDir = $clusterDir.SharedVolumeInfo.FriendlyVolumeName
        }

        # WS 2012, 2008 R2 do not support generation 2 VMs
        $OSInfo = get-wmiobject Win32_OperatingSystem -computerName $vm.hvServer
        if ( ($OSInfo.Caption -match '.2008 R2.') -or
            ($OSInfo.Caption -match '.2012 [^R2].')
        ) {
            if ( $vm.hardware.isCluster -eq "True") {
                $newVm = New-VM -Name $vmName -ComputerName $hvServer -Path $vmDir
            }
            else {
                $newVm = New-VM -Name $vmName -ComputerName $hvServer
            }
        }
        else {
            if ( $vm.hardware.isCluster -eq "True") {
                $newVm = New-VM -Name $vmName -ComputerName $hvServer -Generation $vmGeneration -Path $vmDir
            }
            else {
                $newVm = New-VM -Name $vmName -ComputerName $hvServer -Generation $vmGeneration
            }
            # Enable Guest integration services - not enabled by default
            Enable-VMIntegrationService -Name "Guest Service Interface" -vmName $vmName -ComputerName $hvServer
        }

        if ($null -eq $newVm) {
            LogMsg 0 "Error: Unable to create the VM named $($vm.vmName)."
            return $false
        }

        #
        # Disable secure boot on VM unless explicitly told to enable it on Gen2 VMs
        #
        if (($newVM.Generation -eq 2)) {
            if ($vm.hardware.secureBoot -eq "true") {
                Set-VMFirmware -VM $newVm -EnableSecureBoot On
            }
            else {
                Set-VMFirmware -VM $newVm -EnableSecureBoot Off
            }
        }
        else {
            # Setup an unique com port
            $pipeName = $( -join ((48..57) + (97..122) | Get-Random -Count 10 | % { [char]$_ }))
            $pipePath = "\\.\pipe\${pipeName}"
            $comPorts = $(Get-VM -computername $hvServer | Where-Object { ($_.ComPort2 -ne $null) -and ($_.ComPort2.Path -ne '') } | Select -ExpandProperty ComPort2 | Select -ExpandProperty Path)
            while (($comPorts -ne $null) -and ($comPorts.contains($pipePath))) {
                $pipeName = $( -join ((48..57) + (97..122) | Get-Random -Count 10 | % { [char]$_ }))
                $pipePath = "\\.\pipe\${pipeName}"
            }
            Set-VMComPort -ComputerName $hvServer -VMName $vmName -Number 2 -Path $pipePath -ErrorAction SilentlyContinue
            if (-not $?) {
                Write-Error "Error: Unable to set Com Port with the following path: ${pipePath}"
            }
        }

        #
        # Modify VMs CPU count if user specified a new value
        #
        if ($vm.hardware.numCPUs -and $vm.hardware.numCPUs -ne "1") {
            Set-VMProcessor -VMName $vmName -Count $($vm.hardware.numCPUs) -ComputerName $hvServer
        }

        #
        # Modify the VMs memory size of the user specified a new size
        # but only if a new size is present, and it is not equal to
        # default size of 512 MB
        #
        if ($vm.hardware.memSize -and $vm.hardware.memSize -ne "512") {
            $memSize = [Uint64]$vm.hardware.memsize
            Set-VMMemory -VMName $vmName -StartupBytes $($memSize * 1MB) -ComputerName $hvServer
        }

        $parentVhd = GetParentVhd $vm  $xmlData

        LogMsg 9 "Debug: parentVhd == $parentVhd"
        LogMsg 9 "Debug: parentVhd is of == $($parentVhd.GetType())"

        # If parent VHD is remote, copy it to local VHD directory

        $uriPath = New-Object -TypeName System.Uri -ArgumentList $parentVhd
        if ($uriPath.IsUnc) {
            $extension = (Get-Item "${parentVhd}").Extension
            $vhdDir = GetVhdDir $xmlData
            if ( $vm.hardware.isCluster -eq "True") {
                $clusterDir = Get-ClusterSharedVolume
                $vhdDir = $clusterDir.SharedVolumeInfo.FriendlyVolumeName
            }
            else {
                if ($xmlData.Config.global.VhdPath) {
                    $vhdDir = $xmlData.Config.global.VhdPath
                    if ( -not (Test-Path $vhdDir)) {
                        LogMsg 0 "Error: Path $vhdDir given as parameter does not exist"
                        return $false
                    }
                }
                else {
                    $vhdDir = $(Get-VMHost -ComputerName $hvServer).VirtualHardDiskPath
                }
            }
            # If the path has the ending backslash, remove it
            if ($vhdDir.EndsWith("\")) {
                $vhdDir = $vhdDir.Substring(0, $vhdDir.Length - 1)
            }
            $dstPath = $vhdDir + "\" + "${vmName}${extension}"
            $dstDrive = $dstPath.Substring(0, 1)
            $dstlocalPath = $dstPath.Substring(3)
            $dstPathNetwork = "\\${hvServer}\${dstDrive}$\${dstlocalPath}"
            LogMsg 0 "Info: Copying parent vhd from '$parentVhd' to '$dstPathNetwork'"
            Copy-Item -Path $parentVhd -Destination $dstPathNetwork -Force
            $parentVhd = $dstPath
        }
        $vhdFilename = $parentVhd
        LogMsg 9 "Debug: vhdFilename=$vhdFilename"
        $disableDiff = $vm.hardware.disableDiff -eq "true"
        if (-not $disableDiff) {
            #
            # Create differencing boot disk.
            # If the parentVhd is an Absolute path, it will be use as is.
            # If parentVhd is a relative path, then prepent the HyperV servers default VHD directory.
            #
            $vhdName = "${vmName}_diff.vhd"

            $vhdDir = GetVhdDir( $xmlData )

            $vhdFilename = Join-Path $vhdDir  $vhdName
            $vhdFilenameNetPath = "\\" + $hvServer + "\" + $vhdFilename.Replace(":", "$")
            LogMsg 9 "Debug: vhdDir=$vhdDir"
            LogMsg 9 "Debug: vhdFilename=$vhdFilename"
            LogMsg 9 "Debug: vhdFilenameNetPath=$vhdFilenameNetPath"
            LogMsg 1 "Info: Using '$parentVhd' as parentVhd"

            # Check if differencing boot disk exists, and if yes, delete it
            if (Test-Path $vhdFilenameNetPath) {
                Remove-Item -Path $vhdFilenameNetPath -Force
                $parentVhd = GetParentVhd $vm  $xmlData
                LogMsg 9 "Debug: 'parentVhd' updated to'$parentVhd'"
            }
            #
            #Create the boot .vhd
            #
            $bootVhd = New-VHD -Path $vhdFilename -ParentPath $parentVhd -ComputerName $hvServer
            LogMsg 9 "Debug: bootVhd=$bootVhd"
            LogMsg 9 "Debug: parentVhd=$parentVhd"
            if (-not $bootVhd) {
                LogMsg 0 "Error: Failed to create $vhdFilename using parent $parentVhd for VM ${vmName}"
                $fileInfo = GetRemoteFileInfo $vhdFilename $hvServer
                if ($fileInfo) {
                    LogMsg 0 "Error: The file already exists"
                }

                DeleteVmAndVhd $vmName $hvServer $null
                return $false
            }
        }

        #
        # Add a drive to IDE 0, port 0
        #
        $Error.Clear()
        Add-VMHardDiskDrive $vmName -Path $vhdFilename -ControllerNumber 0 -ControllerLocation 0 -ComputerName $hvServer
        #$newDrive = Add-VMDrive $vmName -path $vhdFilename -ControllerID 0  -LUN 0 -server $hvServer

        if ($Error.Count -gt 0) {
            "Error: Failed to add hard drive to IDE 0, port 0"
            #
            # We cannot create the boot disk, so delete the VM
            #
            LogMsg 0 "Error: VM hard disk not created"
            DeleteVmAndVhd $vmName $hvServer $vhdFilename
            return $false
        }

        #
        # If a data disk was specified...
        #
        $Error.Clear()

        $dataVhd = $vm.hardware.DataVhd
        if ($dataVhd) {
            #$vhdDir = $(Get-VMHost -ComputerName $hvServer).VirtualHardDiskPath

            $vhdDir = GetVhdDir( $xmlData )

            $DiskSizeList = $DataVhd.Trim().Split(",")
            $DiskNumber = 0
            foreach ($DiskSize in $DiskSizeList) {
                $DiskName = "$vmName-$DiskSize-$DiskNumber.vhdx"
                $DiskPath = $(Join-Path $vhdDir $DiskName)
                LogMsg 9 "Debug: data disk: $DiskPath"
                If ((test-path $DiskPath)) {
                    Remove-Item "$DiskPath" -force
                }
                $DiskSize = ($DiskSize / 1GB) * 1GB
                New-VHD -Path $DiskPath -SizeBytes $DiskSize

                If (test-path $DiskPath) {
                    Add-VMHardDiskDrive $vmName -Path $DiskPath -ControllerType SCSI -ControllerNumber 0 -ControllerLocation $DiskNumber -ComputerName $hvServer
                }
                else {
                    LogMsg 0 "Error: Cannot attach data disk: Disk not found at $DiskPath"
                    exit 1
                }

                if ($Error.Count -gt 0) {
                    "Error: Failed to attach .vhd file '$vhdFilename' to VM ${vmName}"
                    #
                    # We cannot create the boot disk, so delete the VM
                    #
                    LogMsg 0 "Error: Cannot attach data disk"
                    exit 1
                }
                $DiskNumber += 1
            }
        }
        else {
            LogMsg 9 "Debug: No data disks are being attached as '<DataVhd>' tag is either missing or empty"
        }

        #
        # Clear all NICs and then add the specified NICs
        #
        Get-VMNetworkAdapter -VMName $vmName -ComputerName $hvServer | Remove-VMNetworkAdapter

        if ($vm.hardware.network) {
            $nicAdded = $False
            foreach ($nic in $vm.hardware.network.nic) {
                #
                # Retrieve the NIC parameters
                #
                $tokens = $nic.Trim().Split(",")
                if (-not $tokens -or $tokens.Length -lt 2 -or $tokens.Length -gt 3) {
                    LogMsg 0 "Error: Invalid NIC defnintion for VM ${vmName}: $nic"
                    "       The NIC was not added to the VM"
                    Continue
                }

                #
                # Extract NIC type and Network name (virtual switch name) then add the NIC
                #
                $nicType = $tokens[0].Trim()
                $networkName = $tokens[1].Trim()

                $legacyNIC = $False
                if ($newVm.Generation -eq 1 -and $nicType -eq "Legacy") {
                    $legacyNIC = $True
                }

                $newNic = Add-VMNetworkAdapter -VMName $vmName -ComputerName $hvServer -IsLegacy:$legacyNIC -SwitchName $networkName -Passthru
                if ($newNic) {
                    #
                    # If the optional MAC address is present, set a static MAC address
                    #
                    if ($tokens.Length -eq 3) {
                        $macAddress = $tokens[2].Trim().ToLower() -replace '[^a-f0-9]', ''  # Leave just hex digits

                        if ($macAddress.Length -eq 12) {
                            Set-VMNetworkAdapter -VMNetworkAdapter $newNic -StaticMAC $macAddress
                        }
                        else {
                            LogMsg 0 "Warn: Invalid MAC address for NIC ${nic}. NIC left with dynamic MAC"
                        }
                    }
                }

                if ($newNic) {
                    $nicAdded = $True
                }
                else {
                    LogMsg 0 "Warn: Unable to add legacy NIC (${nic}) to VM ${vmName}"
                }
            }

            if (-not $nicAdded) {
                LogMsg 0 "Error: no NICs were added to VM ${vmName}. The VM was not created"
                DeleteVmAndVhd $vmName $hvServer $vhdFilename
                return $False
            }
        }

        #
        # Configure VM for High Availability
        #
        if ( $vm.hardware.isCluster -eq "True") {
            Add-ClusterVirtualMachineRole -VirtualMachine $vmName
            if ($? -eq $False) {
                LogMsg 0 "Error: High Availability configure for ${vmName} failed. The VM was not created"
                DeleteVmAndVhd $vmName $hvServer $vhdFilename
                return $False
            }
        }

        LogMsg 0 "Info: Virtual Machine '${vmName}' created successfully!"
        $retVal = $True
    }

    #
    # If we made it here, enough things went correctly and the VM was created
    #
    return $retVal
}


function GetVMIPv4Address([System.Xml.XmlElement] $vm, [XML] $xmlData) {
    $BootTime = 0
    LogMsg 0 "Info: Getting IPv4 address of '$($vm.vmName)'"
    $timeout = 180
    while ($timeout -gt 0) {
        #
        # Check if the VM is in the Hyper-v Running state
        #
        $v = Get-VM $vm.vmName -ComputerName $vm.hvServer
        if ($($v.State) -eq "Running") {
            break
        }

        start-sleep -seconds 1
        $timeout -= 1
        $BootTime += 1
    }

    #
    # Check if we timed out waiting to reach the Hyper-V Running state
    #
    if ($timeout -eq 0) {
        LogMsg 0 "Warn: $($vm.vmName) never reached Hyper-V status Running - timed out`n       Terminating test run."

        $v = Get-VM $vm.vmName -ComputerName $vm.hvServer
        Stop-VM $v -ComputerName $vm.hvServer | out-null
        $vm.currentTest = "done"
        UpdateState $vm $ShuttingDown
    }
    else {
        $timeout = 180
        while ($timeout -gt 0) {
            #
            # Check if the VM is in the Hyper-v Running state
            #
            $IPv4 = GetIPv4 $vm.vmName $vm.hvServer
            if ($IPv4 ) {
                $vm.ipv4 = $IPv4
                LogMsg 0 "`nInfo: IP of '$($vm.vmName)': '$($vm.ipv4)'`n"
                return $IPv4
            }
            Write-Host "." -NoNewline

            start-sleep -seconds 1
            $timeout -= 1
        }
        Write-Host ""

        #
        # Check if we timed out waiting to reach the Hyper-V Running state
        #
        if ($timeout -eq 0) {
            LogMsg 0 "Error: IP of $($vm.vmName) not retrivable`n"
        }
    }
}

function CheckDependencies() {
    If (!(test-path $LogFolder)) {
        New-Item -ItemType Directory -Force -Path $LogFolder
    }

    LogMsg 0 "Info: Verifying dependencies.."

    if (! $xmlFile) {
        LogMsg 0 "Error: The xmlFile argument is null."
        exit $exitStatus
    }
    else {
        LogMsg 0 "Info: Getting configuration from '${xmlFile}'"
    }

    $DependencyArray = @(".\bin\dos2unix.exe", ".\bin\plink.exe", "bin\pscp.exe", $xmlFile)
    For ($i = 0; $i -lt $DependencyArray.Length; $i++) {
        if (-not (Test-Path $DependencyArray[$i])) {
            LogMsg 0 "Error: `$DependencyArray[$i]` file doesn't exist`n Exitting now..."
            exit $exitStatus
        }
    }

    LogMsg 0 "Done"
}

function UploadFiles ([System.Xml.XmlElement] $vm) {
    .\bin\dos2unix.exe .\scripts\* 2>&1  >$null
    RemoteCopy -uploadTo $vm.ipv4 -port 22 -files ".\scripts\*" -username $vm.userName -password $vm.passWord -upload
    #.\bin\dos2unix.exe .\files\*  
    RemoteCopy -uploadTo $vm.ipv4 -port 22 -files ".\files\*" -username $vm.userName -password $vm.passWord -upload
}

function DownloadFiles ([System.Xml.XmlElement] $vm) {
    $VMLogDownloadFolder = $(Join-Path $LogFolder $vm.vmName)

    If ( -not (test-path $VMLogDownloadFolder)) {
        New-Item -ItemType Directory -Force -Path $VMLogDownloadFolder | out-null
    }

    RemoteCopy -download -downloadFrom $vm.ipv4 -files "*" -downloadTo $VMLogDownloadFolder -port 22 -username $vm.userName -password $vm.passWord
}

function SetVMHostName ([System.Xml.XmlElement] $vm) {
    LogMsg 0 "Info: Setting Hostname.."

    RunLinuxCmd -username $vm.userName -password $vm.passWord -ip $vm.ipv4 -port 22 -command "echo $($vm.vmName) > /etc/hostname" -runAsSudo
    RunLinuxCmd -username $vm.userName -password $vm.passWord -ip $vm.ipv4 -port 22 -command "hostname $($vm.vmName)" -runAsSudo -ignoreLinuxExitCode
    $hostname = RunLinuxCmd -username $vm.userName -password $vm.passWord -ip $vm.ipv4 -port 22 -command "hostname" -runAsSudo -ignoreLinuxExitCode
    if ($vm.vmName -eq $hostname) {
        LogMsg 0 "Info: Setting Hostname.. Success"    
    }
    else {
        LogMsg 0 "Error: Setting Hostname.. Failed"    
    }
}
#######################################################################
#
# Main script body
#
#######################################################################
$TimeElapsed = [Diagnostics.Stopwatch]::StartNew()
CheckDependencies
#
# Parse the .xml file
#
$xmlData = [xml] (Get-Content -Path $xmlFile)
if ($null -eq $xmlData) {
    LogMsg 0 "Error: Unable to parse the .xml file ${xmlFile}"
    LogMsg 0 "Error: Invalid .xml file ${xmlFile}"
    exit $exitStatus
}

#
# Make sure at lease one VM is defined in the .xml file
#
if (-not $xmlData.Config.VMs.VM) {
    LogMsg 0 "Error: No VMs defined in .xml file ${xmlFile}"
    LogMsg 0 "Error: Invalid .xml file ${xmlFile}"
    exit $exitStatus
}

#
# Process each VM definition
#
foreach ($vm in $xmlData.Config.VMs.VM) {
    #
    # The VM needs a hardware definition before we can create it
    #
    if ($vm.hardware) {
        $VmName = $vm.vmName
        $vm | Add-Member -NotePropertyName state -NotePropertyValue $SystemDown
        for ($i = 0; $i -lt $vm.Count; $i++) {
            $vm.vmName = $VmName + "-$i"
            LogMsg 0 "Info: Creating VM: '$($vm.vmName)'"
            $vmCreateStatus = CreateVM $vm $xmlData
            if (-not $vmCreateStatus) {
                exit $exitStatus
            }
            LogMsg 0 "Info: Starting VM: '$($vm.vmName)'"
            $vmStartStatus = DoStartSystem $vm $xmlData
            if ($vmStartStatus -eq $SystemStarting) {
                $vmStartStatus = DoSystemStarting $vm $xmlData
            }
            else {
                exit $exitStatus
            }
            LogMsg 0 "Info:"
        }
        $vm.vmName = $VmName
    }
    else {
        LogMsg 0 "Error: The VM $($vm.vmName) does not have a hardware definition.
                      The VM will not be created !"
        exit 0
    }
}

$IpList = @()
$VmNameList = @()

foreach ($vm in $xmlData.Config.VMs.VM) {
    $VmName = $vm.vmName
    for ($i = 0; $i -lt $vm.Count; $i++) {
        $vm.vmName = $VmName + "-$i"
        $VmNameList += $vm.vmName
        $VMIP = GetVMIPv4Address $vm $xmlData

        if (-not $VMIP) {
            LogMsg 0 "Error: Unable to get the VM IP, Did you install 'linux-cloud-tools' package in parentVhd? "
            LogMsg 0 "Fix: run 'sudo apt install *`uname -r`* in the parent .vhd and use it'"
            LogMsg 0 "Error: Also check Switch settings!"
            exit 1
        }
        else {
            SetVMHostName($vm)

            $IpList += $VMIP

            if ($vm.StartupScript) {
                UploadFiles $vm
                RunLinuxCmd -username $vm.userName -password $vm.passWord -ip $vm.ipv4 -port 22 -command "chmod +x *" -runAsSudo

                LogMsg 0 "Invoking the main script on the VM. It might take several minutes to complete." "White" "Red"
                LogMsg 0 "Meanwhile you can check the execution status by running 'tail -f ConsoleLogFile.log' on the test VM." "White" "Red"

                LogMsg 0 "VM connection details: * ssh $($vm.userName)@$($vm.ipv4) * Password:$($vm.passWord) " "White" "Red"

                RunLinuxCmd -username $vm.userName -password $vm.passWord -ip $vm.ipv4 -port 22 -command "bash $($vm.StartupScript)" -runAsSudo
                DownloadFiles $vm
            }
        }
    }
    $vm.vmName = $VmName
}

$TimeElapsed.Stop()
LogMsg 0 "Info: Total execution time: $($TimeElapsed.Elapsed.TotalSeconds) Seconds"
LogMsg 0 "Logs are located at '$LogFolder'" "White" "Black"

for ($counter = 0; $counter -lt $IpList.Count; $counter++) {
    $vm = $xmlData.Config.VMs.VM[$counter] 
    LogMsg 0 "VM connection details '$($VmNameList[$counter])' : * ssh $($vm.userName)@$($IpList[$counter]) * Password: * $($vm.passWord) *" "White" "Red"

    if ($vm.StartupScript -eq "PrepareDocker.sh") {
        LogMsg 0 "Test Container connection details '$($VmNameList[$counter])' : * ssh -p 222 $($vm.userName)@$($IpList[$counter]) * Password: $($vm.passWord)" "White" "Red"
    }
}
$exitStatus = 0
exit $exitStatus
