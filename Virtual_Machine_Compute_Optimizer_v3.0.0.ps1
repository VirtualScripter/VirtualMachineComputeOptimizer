#==========================================================================
#
# Powershell Source File 
#
# NAME: Virtual_Machine_Compute_Optimizer.ps1, v2.1.1
#
# AUTHOR: Mark McGill, VMware
# Last Updated: 4/29/2020
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
$VMCOModule = "VMCO"
$minPSVer = 5
#$functionFile = "Get-OptimalvCPU_v2.1.1.ps1"

#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++
#////////////////////////////FUNCTIONS ///////////////////////////////////
#+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++

#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
Function Install_Update_Module($moduleName) 
{
    Try
    {
        $installedVersion = Get-InstalledModule -Name $moduleName -ErrorAction Stop | select -ExpandProperty Version | Measure-Object -Maximum | select -expand Maximum
        $installedVersion = "$($installedVersion.Major).$($installedVersion.Minor).$($installedVersion.Build).$($installedVersion.Revision)"
        $currentVersion = Find-module -name $moduleName | select -expand Version -ErrorAction Stop
        $currentVersion = "$($currentVersion.Major).$($currentVersion.Minor).$($currentVersion.Build).$($currentVersion.Revision)"
        If ($currentVersion -gt $installedVersion)
        {
            Write-Host "Updating module $moduleName from $installedVersion to $currentVersion" -ForegroundColor Yellow
            Update-Module -name $moduleName -Confirm:$false -Force -ErrorAction Stop
            Return "SUCCESS"
        }
        Else
        {
            Write-Host "Current version of module $moduleName is already installed" -ForegroundColor Green
            Return "SUCCESS"
        }
    }
    Catch
    {
        If($_.Exception.Message -Match "No match was found for the specified search criteria and module names")
        {
            Write-Host "Installing module $moduleName" -ForegroundColor Yellow
            Try
            {
                Install-Module $moduleName -Scope CurrentUser -SkipPublisherCheck -Confirm:$false -Force -ErrorAction Stop
                Return "SUCCESS"
            }
            Catch
            {
                Write-Host "Error installing module $moduleName : $_.Exception.Message" -ForegroundColor Red
                Return "ERROR"
            }
        }
        Else
        {
            Write-Host "Failed to find or update module $moduleName : $_.Exception.Message" -ForegroundColor Red
            Return "ERROR"
        }
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
            Set-PowerCLIConfiguration -DefaultVIServerMode Multiple -Scope Session -Confirm:$false
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

$powerCLIResult = Install_Update_Module $powerCLIModule
If ($powerCLIResult -eq "ERROR")
{
    Write-Host "Script will exit." -ForegroundColor Red
    pause; break 
}

$VMCOResults = Install_Update_Module $VMCOModule
If ($VMCOResults -eq "ERROR")
{
    Write-Host "Script will exit." -ForegroundColor Red
    pause; break 
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
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope Session -Confirm:$false | Out-Null
    Set-PowerCLIConfiguration -ParticipateInCEIP:$false -Scope Session -Confirm:$false | Out-Null
    Connect-VIServer $vCenters -credential $creds -ErrorAction Stop | Out-Null
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

#Call function with no parameters (gets all VMs from connected vCenter Servers)
Try
{
    Get-OptimalvCPU -Full -Verbose -ErrorAction Stop | Export-Csv -Path $outPutFile -NoTypeInformation -ErrorAction Stop
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