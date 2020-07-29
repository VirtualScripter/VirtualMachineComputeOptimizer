#==========================================================================
#
# Powershell Source File 
#
# NAME: Virtual_Machine_Compute_Optimizer.ps1, v2.1.0
#
# AUTHOR: Mark McGill, VMware
# Last Updated: 5/7/2020
#
# COMMENT: Verifies necessary Powershell versions and Modules needed in 
#          order to utilize the Get-OptimalvCPU function. Also completes
#          the connection process to vCenter Server(s)
#
#==========================================================================

#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#////////////////////DIMENSION & DECLARE VARIABLES////////////////////////
#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

$defaultPath = $PSScriptRoot
$defaultReportPath = "$defaultPath\VMCO_Report.csv"
$powerCLIModule = "VMware.VimAutomation.Core"
$minPSVer = 5
$functionFile = "Get-OptimalvCPU_v2.1.0.ps1"

#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#////////////////////////////FUNCTIONS ///////////////////////////////////
#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
Function Import_Update_Module($moduleName) 
{
    #Test to see if Module Exists
    Try
    {
        $installedVersion = Get-InstalledModule -Name $moduleName | select -ExpandProperty Version | Measure-Object -Maximum | select -expand Maximum -ErrorAction Stop
        $installedVersion = "$($installedVersion.Major).$($installedVersion.Minor).$($installedVersion.Build).$($installedVersion.Revision)"
        If ($installedVersion -eq $null) 
        {
            Write-Host "$moduleName is not installed. Type 'Y' to install module, or 'N' to skip: " -ForegroundColor Yellow -NoNewline
            Do
            {
                $choice = Read-Host
                Switch ($choice)
                {
                    "Y" {$action = "Install"}
                    "N" {$action = "Module Not Installed"; return $action}
                    default {Write-Host "Invalid choice. Please type 'Y' or 'N': " -ForegroundColor Yellow -NoNewline; $action = "Invalid"}
                }
            }
            Until ($action -ne "Invalid")
        }
        Else
        {
            $currentVersion = Find-module -name $moduleName | select -expand Version -ErrorAction Stop
            $currentVersion = "$($currentVersion.Major).$($currentVersion.Minor).$($currentVersion.Build).$($currentVersion.Revision)"
            If ($currentVersion -gt $installedVersion)
            {
                Write-Host "A newer version of $moduleName is available. Type 'Y' to update module to $currentVersion or 'N' to continue with current version $($installedVersion): " `
                    -ForegroundColor Yellow -NoNewline
                Do
                {
                    $choice = Read-Host
                    Switch ($choice)
                    {
                        "Y" {$action = "Update"}
                        "N" {$action = "$moduleName Module Update Skipped"; return $action}
                        default {Write-Host "Invalid choice. Please type 'Y' or 'N': " -ForegroundColor Yellow -NoNewline; $action = "Invalid"}
                    }
                }
                Until ($action -ne "Invalid")
            }
            Else 
            {
                return "$moduleName already installed and updated"
            }
        }
    }
    Catch
    {
        Return "ERROR: Failed to detect $moduleName module: $($_.exception.Message)" 
    }
    #Install or update depending on status and choice  
    Try
    {
        Switch ($action)
        {
            "Install"
            {
                Import-Module -name $moduleName -Scope CurrentUser -Force -ErrorAction Stop
            }
            "Update"
            {
                Update-Module -name $moduleName -Confirm:$false -ErrorAction Stop
            } 
        }
        Return "SUCCESS: Completed $action of $moduleName."
    }
    Catch
    {
        Return "ERROR: Could not $action $($moduleName): $($_.exception.Message)"
    }
}
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
Function Set_MultivCenterMode()
{
    $userMulti = Get-PowerCLIConfiguration -Scope User | Select -ExpandProperty DefaultVIServerMode
    If ($userMulti -ne "Multiple")
    {
        Try
        {
            Set-PowerCLIConfiguration -DefaultVIServerMode Multiple -Scope User -Confirm:$false
            Write-host "Changed DefaultVIServerMode to Multiple" -ForegroundColor Green
            Return "SUCCESS"
        }
        Catch
        {
            Write-Host "Error changing DefaultVIServerMode to Multiple: $($_.Exception.Message )" -ForegroundColor Red
            Return "ERROR"
        }
    }
    Else
    {
        Write-Host "DefaultVIServerMode is already set to Multiple" -ForegroundColor Green
        Return "SUCCESS"
    }
}
#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@

#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#///////////////////////////////CODE BODY ////////////////////////////////
#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

$psVer = [string]$PsVersionTable.PSVersion.major + "." + [string]$PsVersionTable.PSVersion.Minor + `
		"." + [string]$PsVersionTable.PSVersion.Build + "." + [string]$PsVersionTable.PSVersion.Revision
If($psVer -lt $minPSVer)
{
    Write-Host "Powershell version is at $psVer.  It must be at a minimum of version 5 to run this script properly. `
    Please update and re-run this script." -ForegroundColor Red
    pause; break
}

Write-Host "Enter the path for the CSV Report, or press <enter> to accept the default path. `
    $($defaultReportPath): " -ForegroundColor Yellow -noNewline
$outPutFile = Read-Host

If ($outPutFile -eq "")
{
    $outPutFile = $defaultReportPath
}

#checks to see if outPutFile already exists
If (test-path $outPutFile)
{
    Write-Host "*** $outPutFile already exists!  New data will be appended to this report! ***" -ForegroundColor Red
}

Write-Host "Checking for $powerCLIModule module" -ForegroundColor Yellow
$powerCLIResult = Import_Update_Module $powerCLIModule
If ($powerCLIResult -match ("ERROR" -or "Not Installed"))
{
    Write-Host "$($powerCLIResult). Script will exit." -ForegroundColor Red
    pause; break 
}
Else 
{
    Write-Host "$powerCLIResult" -ForegroundColor Green
}

Write-Host "Type vCenter Server FQDNs Separated by a comma. `
    IE: vcenter1.domain.com,vcenter2.domain.com : " -foregroundcolor Yellow -noNewline
$vCenters = Read-Host 

$vCenters = $vCenters.Split(",").Trim()

#sets Multi vCenter mode if > 1 vCenter

If ($vCenters.Count -gt 1)
{
    $multiVCResult = Set_MultivCenterMode
    If($multiVCResult -eq "ERROR")
    {
        "Script will exit"
        pause; break 
    }
}

$creds = Get-Credential -Message "Enter credentials to connect to vCenter Servers"

#disconnects any existing vCenter connections
$vcConnections = $global:DefaultVIServers
If ($vcConnections.Count -ge 1)
{
    $vcConnections | Disconnect-VIServer -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "Disconnecting existing vCenter connections to: ` $vcConnections." -ForegroundColor Yellow
}

Try 
{
    Connect-VIServer $vCenters -credential $creds -ErrorAction Stop
}    
Catch
{
    Write-Host "Error connecting to vCenter Servers: $vcenters" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    pause; break 
}
Finally
{
    Remove-Variable creds
}

#load Get-OptimalvCPU function
$functionPath = "$defaultPath\$functionFile"
Try
{
    . "$defaultPath\$functionFile"
}
Catch
{
    If(Test-Path $functionPath)
    {
        Write-Host "Error loading Get-OptimalvCPU function: $($_.Exception.Message)" -ForegroundColor Red
    }
    Else
    {
        Write-Host "Get-OptimalvCPU.ps1 is not in the $defaultPath directory."
    }
    pause; break
}

#Call function with no parameters (gets all VMs from connected vCenter Servers)
Try
{
    Get-OptimalvCPU -Verbose -ErrorAction Stop | Export-Csv -Path $outPutFile -NoTypeInformation -ErrorAction Stop
}
Catch
{
    Write-Host "Error generating VMCO report: $($_.Exception.Message)" -ForegroundColor Red
}

foreach ($vCenter in $vCenters)
{
    Disconnect-VIServer $vCenter -Confirm:$false -Force
}

Write-Host "Analysis complete.  Please check report at $outPutFile" -ForegroundColor Green
pause; break