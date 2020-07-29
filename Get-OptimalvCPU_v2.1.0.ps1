<#
    .NOTES
        Author: Mark McGill, VMware
        Last Edit: 5-7-2020
        Version 2.1.0
    .SYNOPSIS
        Calculates the optimal vCPU (sockets & cores) based on the current VM and Host architecture
    .DESCRIPTION
        Uses the logic from Mark Achtemichuk's blog "Virtual Machine vCPU and vNUMA Rightsizing – Rules of Thumb"
        https://blogs.vmware.com/performance/2017/03/virtual-machine-vcpu-and-vnuma-rightsizing-rules-of-thumb.html

        If no -vmName is specified, Get-OptimalvCPU will get all VMs from connected vCenters
        If -simple is passed, only the VM information will be returned
    .EXAMPLE
        Get-OptimalvCPU       #Gets all VMs from currently connected vCenters
    .EXAMPLE
        Get-OptimalvCPU | Export-CSV -path "c:\temp\vNUMA.csv" -NoTypeInformation
    .EXAMPLE
        Get-OptimalvCPU -vmName "MyVmName"
    .EXAMPLE
        Get-OptimalvCPU -vmName (Get-VM -Name "*NY-DC*")
    .EXAMPLE
        Get-OptimalvCPU -simple      #Returns only VM information
    .OUTPUTS
        Object containing vCenter,Cluster,Host and VM information, as well as optimal vCPU recommendations
#>

function Get-OptimalvCPU
{
    [cmdletbinding()]
    Param
    (
        [Parameter(Mandatory=$false)]$vmName,
        [Parameter(Mandatory=$false)][switch]$simple
    )

    $nameFilter = ""
    $vmFilter = @{'RunTime.ConnectionState'='^(?!disconnected|inaccessible|invalid|orphaned).*$';'Runtime.PowerState'='poweredOn';'Config.Template'='False'}
    $hostFilter = @{'Runtime.ConnectionState'='connected';'Runtime.PowerState'='poweredOn'}
    $results = @()
    $vms = @()
    Write-Verbose "Retrieving VMs information - Skipping Disconnected, Powered Off, or Template VMs"

    Try
    {
        If ($VMName -ne $null)
        {
            foreach ($name in $VMName)
            {
                $nameFilter += "$name|"
            }
            $nameFilter = $nameFilter.TrimEnd("|")
            $vmFilter += @{"Name" = $nameFilter}
        }
        #gets VM information
        $vms = get-view -ViewType VirtualMachine -Filter $vmFilter -Property Name,Config.Hardware.MemoryMB,Config.Hardware.NumCPU,Config.Hardware.NumCoresPerSocket,Config.CpuHotAddEnabled,Config.Version,Config.ExtraConfig,Runtime.Host | 
            select Name, @{n='MemoryGB'; e={[math]::Round(($_.Config.Hardware.MemoryMB / 1024),2)}},@{n='Sockets';e={($_.Config.Hardware.NumCPU)/($_.Config.Hardware.NumCoresPerSocket)}},@{n='CoresPerSocket'; 
            e={$_.Config.Hardware.NumCoresPerSocket}},@{n='NumCPU';e={$_.Config.Hardware.NumCPU}},@{n='CpuHotAdd';e={$_.Config.CpuHotAddEnabled}},@{n='HWVersion';e={$_.Config.Version}},@{n='HostId';
            e={$_.Runtime.Host.Value}},@{n='vCenter';e={([uri]$_.client.ServiceUrl).Host}},@{n='NumaVcpuMin';e={($_.Config.ExtraConfig | where {$_.Key -eq "numa.vcpu.min"}).Value}}
        If($vms -eq $null)
        {
            Throw "No VMs found, or VMs are not powered on, or connected"
        }
    }
    Catch
    {
        Write-Error -Message "Error retrieving VM information: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"
        break
    }
    
    Try
    {
        Write-Verbose "Retrieving Host information. Skipping Disconnected or Powered Off Hosts"
        If ($VMName -ne $null)
        {
            $hostsUnique = $vms | Select @{n="Id";e={"HostSystem-" + "$($_.HostId)"}},vCenter | Sort-Object -Property @{e="Id"},@{e="vCenter"} -Unique
            $hostCommand = {get-view -Id $($hostsUnique.Id) -Property Name,Parent,Config.Product.Version,Config.HyperThread,Hardware.MemorySize,Hardware.CpuInfo,Config.PowerSystemInfo.CurrentPolicy.Key,Config.Option}
        }
        Else
        {
            $hostCommand = {get-view -ViewType HostSystem -Filter $hostFilter -Property Name,Parent,Config.Product.Version,Config.HyperThread,Hardware.MemorySize,Hardware.CpuInfo,Config.PowerSystemInfo.CurrentPolicy.Key,Config.Option}
        }
    
        $vmHosts = Invoke-Command $hostCommand | select Name,@{n='Id';e={$_.MoRef.Value}},@{n='Version';e={$_.Config.Product.Version}},@{n='vCenter';e={([uri]$_.Client.serviceurl).Host}},@{n="ClusterId";
            e={$_.Parent | Where{$_.Type -eq "ClusterComputeResource"} | select -expand Value}},@{n='MemoryGB';e={[int](($_.Hardware.MemorySize)/1073741824)}},@{n="MemPerChannel";
            e={[int](($_.Hardware.MemorySize)/1073741824) / ($_.Hardware.CpuInfo.NumCpuPackages)}},@{n='Sockets';e={($_.Hardware.CpuInfo.NumCpuPackages)}},@{n='CoresPerSocket';
            e={($_.Hardware.CpuInfo.NumCPUCores)/$($_.Hardware.CpuInfo.NumCpuPackages)}},@{n='CPUs';e={$_.Hardware.CpuInfo.NumCPUCores}},@{n='CpuThreads';e={($_.Hardware.CpuInfo.NumCpuThreads)}},@{n='HTActive';
            e={$_.Config.HyperThread.Active}},@{n='NumaVcpuMin'; e={$_.Config.Option | where {$_.Key -eq "numa.vcpu.min"}}},@{n='PowerPolicy'; 
            e={
                switch($_.Config.PowerSystemInfo.CurrentPolicy.Key)
                {
                    "1" {"HighPerformance"}
                    "2" {"Balanced"}
                    "3" {"LowPower"}
                    "4" {"Custom"}
                }
               }
        }
    }
    Catch
    {
        Write-Error -Message "Error retrieving Host information: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"
        break
    }

    Try
    {
        Write-Verbose "Retrieving Cluster information" 
        $clustersUnique = $vmHosts | Where{$_.ClusterId -ne $null} | Select @{n="Id";e={"ClusterComputeResource-" + "$($_.ClusterId)"}},vCenter | Sort-Object -Property @{e="Id"},@{e="vCenter"} -Unique
        #accounts for hosts with no cluster
        If ($clustersUnique -ne $Null)
        {
            $clusters = get-view -Id $($clustersUnique.Id) -Property Name | Select Name,@{n="Id";e={$_.MoRef.Value}},@{n="vCenter";
                e={([uri]$_.Client.serviceurl).Host}},MinMemoryGB,MinSockets,MinCoresPerSocket -ErrorAction Stop
 
            foreach ($cluster in $clusters)
            {
                $clusterHosts = $vmHosts | Where{($_.vCenter -eq $cluster.vCenter) -and $_.clusterID -eq $cluster.Id} | select Name,Id,MemoryGB,Sockets,CoresperSocket
                $cluster.MinMemoryGB = ($clusterHosts.MemoryGB | measure -Minimum).Minimum
                $cluster.MinSockets = ($clusterHosts.Sockets | measure -Minimum).Minimum
                $cluster.MinCoresPerSocket = ($clusterHosts.CoresPerSocket | measure -Minimum).Minimum
            }
        }
    }
    Catch
    {
        Write-Error -Message "Error retrieving Cluster information: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"
        break
    }

    #process VM calculations
    $vmCount = ($vms | Measure-Object).Count
    Write-Verbose "Calculating Optimal vCPU settings for $vmCount VMs"
    $n = 1
    foreach ($vm in $vms)
    {
        $vmsPercent = [math]::Round(($n / $vmCount) * 100)
        Write-Progress -Activity "Calculating Optimum vCPU Config for VMs" -Status "$vmsPercent% Complete:" -PercentComplete $vmsPercent -CurrentOperation "Current VM: $($vm.Name)"
            
        $priorities = @() 
        $priorities += 0   
        $details = ""
        $pNumaNotExpDetails = ""

        $vmHost = $vmHosts | where {$($_.vCenter) -eq $($vm.vCenter) -and $($_.Id) -eq $($vm.HostId)} | select -first 1

        If ($vmHost.ClusterId -eq $null)
        {
            $cluster = "" | Select Name,MinMemoryGB,MinSockets,MinCoresPerSocket
        }
        Else
        {
            $cluster = $clusters | Where{($($_.Id) -eq $($vmHost.ClusterId)) -and ($($_.vCenter) -eq $($vmHost.vCenter))} | Select Name,MinMemoryGB,MinSockets,MinCoresPerSocket | select -first 1
        }
        Try
        {
            #flags if vmMemory spans pNUMA node
            If ($vm.MemoryGB -gt $vmHost.MemPerChannel)
            {
                $memWide = $true
                $memWideDetail = "memory"
            }
            Else
            {
                $memWide = $false
                $memWideDetail = ""
            } 
            #flags if vCPUs span pNUMA node
            If ($vm.NumCPU -gt $vmHost.CoresPerSocket)
            {
                $cpuWide = $true
                $cpuWideDetail = "CPU"
            }
            Else
            {
                $cpuWide = $false
                $cpuWideDetail = ""
            }
        
            #if #vCPUs is odd and crosses pNUMA nodes
            If (($memWide -or $cpuWide) -and (($vm.NumCPU % 2) -ne 0))
            {
                $calcVmCPUs = $vm.NumCPU + 1
                $cpuOdd = $true
            }
            Else
            {
                $calcVmCPUs = $vm.NumCPU
                $cpuOdd = $false
            }
            #calculations for optimal vCPU
            $i = 0
            Do 
            {
                $i++
            }
            Until (
                (($vm.MemoryGB / $i -le $vmHost.MemPerChannel) -or ($calcVmCPUs / $i -eq 1)) `
                    -and (($calcVmCPUs / $i -le $vmHost.CoresPerSocket) -or ($calcVmCPUs / $i -eq 1) -or ($calcVmCPUs -eq $vmHost.CPUs)) `
                    -and (($calcVmCPUs / $i)  % 2 -eq 0 -or ($calcVmCPUs / $i)  % 2 -eq 1)
                )
            $optSockets = $i
            $optCoresPerSocket = $calcVmCPUs / $optSockets
            #flags if adjustments had to be made to the vCPUs
            If (($optSockets -ne $vm.Sockets) -or ($optCoresPerSocket -ne $vm.CoresPerSocket) -or $cpuOdd)
            {
                $cpuOpt = $false
            }
            Else
            {
                $cpuOpt = $true
            }
            #vCPUs are not optimal, but VM is not wide
            If (-not ($memWide -or $cpuWide) -and (-not $cpuOpt))
            {
                $details += "VM does not span pNUMA nodes, but consider configuring it to match pNUMA architecture | "
                $priorities += 1
            }

            ######################################################
            #if crossing pNUMA node(s), additional flags
            If (($memWide -or $cpuWide) -and (-not $cpuOpt))
            {
                If ($memWideDetail -ne "" -and $cpuWideDetail -ne "")
                {
                    $wideDetails = "$memWideDetail and $cpuWideDetail"
                }
                Else
                {
                    $wideDetails = ("$memWideDetail $cpuWideDetail").Trim()
                }
                $details += "VM $wideDetails spans pNUMA nodes and should be distributed evenly across as few as possible | "
            
                #flags if VM is crossing pNUMA nodes, and vHW version is less than 8 (pNUMA not exposed to guest) 
                $vmHWVerNo = [int]$vm.HWVersion.Split("-")[1]
                If($vmHWVerNo -lt 8)
                {
                    $pNumaNotExp = $true
                    $pNumaNotExpDetails = "(vHW < 8) "
                }
                #flags if VM is crossing pNUMA nodes, and CPUHotAdd is enabled (pNUMA not exposed to guest) 
                If($vm.CpuHotAdd -eq $true)
                {
                    $pNumaNotExp = $true
                    $pNumaNotExpDetails = $pNumaNotExpDetails + " (CpuHotAddEnabled = TRUE)"
                }
                #flags if VM is crossing pNUMA nodes, and vCPUs is less than 9 (pNUMA not exposed to guest)
                If($vm.NumCPU -lt 9 -and $vm.NumaVcpuMin -eq $null -and $vmHost.NumaVcpuMin -eq $null)
                {
                    $pNumaNotExp = $true
                    $pNumaNotExpDetails = $pNumaNotExpDetails + " (vCPUs < 9). Consider modifying advanced setting ""Numa.Vcpu.Min"" to $($vm.NumCPU) or lower. "
 
                }
                #if NumaVcpuMin has been modified
                Elseif($vm.NumaVcpuMin -ne $null -or $vmHost.NumaVcpuMin -ne $null)
                {
                    If($vm.NumaVcpuMin -ne $null)
                    {
                        $modVM = "VMValue: $($vm.NumaVcpuMin) "
                    }
                    ElseIf($vmHost.NumaVcpuMin -ne $null)
                    {
                        $modHost = "HostValue: $($vmHost.NumaVcpuMin)"
                    }
                    $modDetail = ("$modVM, $modHost").Trim(", ")

                    switch($vm.NumaVcpuMin -le $vm.NumCPU -or $vmHost.NumaVcpuMin -le $vm.NumCPU)
                    {
                        $true {$details += "vCPUs < 9, but advanced setting ""Numa.Vcpu.Min"" has been modified ($modDetail) to expose pNUMA to guest OS | "}
                        $false 
                        {
                            $pNumaNotExp = $true
                            $pNumaNotExpDetails = $pNumaNotExpDetails + " (Advanced setting ""Numa.Vcpu.Min"" is > VM vCPUs). The setting has been modified ($modDetail), but is still higher than VM vCPUs. Change the value to $($vm.NumCPU) or lower to expose pNUMA to the guest OS"
                        }
                    }
                }
                If($pNumaNotExp)
                {
                    $pNumaNotExpDetails = $pNumaNotExpDetails.Trim() 
                    $details += "VM spans pNUMA nodes, but pNUMA is not exposed to the guest OS: $pNumaNotExpDetails | "
                }
             
                #flags if VM has odd # of vCPUs and spans pNUMA nodes
                If ($cpuOdd)
                {
                    $details += "VM has an odd number of vCPUs and spans pNUMA nodes | "
                }
                $priorities += 3
            }#end if (($memWide -or $cpuWide) -and (-not $cpuOpt))

            #flags if hosts in a cluster are of different size memory or CPU
            If (($vmHost.MemoryGB -ne $cluster.MinMemoryGB -or $vmHost.Sockets -ne $cluster.MinSockets -or $vmHost.CoresPerSocket -ne $cluster.MinCoresPerSocket) -and $cluster.MinMemoryGB -ne "")
            {
                $details += "Host hardware in the cluster is inconsistent. Consider sizing VMs based on the minimums for the cluster | "
                $priorities += 2
            }
            #flags VMs with CPU count higher than physical cores
            If($vm.NumCPU -gt ($vmHost.Sockets * $vmHost.CoresPerSocket))
            {
                $optSockets = $hostSockets
                $optCoresPerSocket = $vmHost.CoresPerSocket
                $priorities += 2
                $details += "VM vCPUs exceed the host's physical cores. Consider reducing the number of vCPUs | "
            }
            #flags if vCPU count is > 8 and Host PowerPolicy is not "HighPerformance"
            If($vm.NumCPU -gt 8 -and $vmHost.PowerPolicy -ne "HighPerformance" -and $vmHost.PowerPolicy -ne "N/A")
            {
                #$priorities += 2
                $details += 'Consider changing the host Power Policy to "High Performance" for clusters with VMs larger than 8 vCPUs | '
            } 
  
            #gets highest priority
            $highestPriority = ($priorities | measure -Maximum).Maximum
            Switch($highestPriority)
            {
                0    {$priority = "N/A"}
                1    {$priority = "LOW"}
                2    {$priority = "MEDIUM"}
                3    {$priority = "HIGH"}
            }

            #flags whether the VM is configured optimally or not
            If ($priority -eq "N/A")
            {
                $vmOptimized = "YES"
            }
            Else
            {
                $vmOptimized = "NO"
            }
            #creates object with data to return from function
            If ($simple -eq $true)
            {
                $objInfo = [pscustomobject]@{
                    VMName                   = $($vm.Name);
                    VMSockets                = $($vm.Sockets);
                    VMCoresPerSocket         = $($vm.CoresPerSocket);
                    vCPUs                    = $($vm.NumCPU);
                    VMOptimized              = $vmOptimized;
                    OptimalSockets           = $optSockets;
                    OptimalCoresPerSocket    = $optCoresPerSocket;
                    Priority                 = $priority;
                    Details                  = $details.Trim("| ")
                    } #end pscustomobject
            }
            Else
            {
                $objInfo = [pscustomobject]@{
                    vCenter                  = $($vmHost.vCenter);
                    Cluster                  = $($cluster.Name);
                    ClusterMinMemoryGB       = $($cluster.MinMemoryGB);
                    ClusterMinSockets        = $($cluster.MinSockets);
                    ClusterMinCoresPerSocket = $($cluster.MinCoresPerSocket);
                    HostName	             = $($vmHost.Name);
                    ESXi_Version             = $($vmHost.Version);
                    HostMemoryGB             = $($vmHost.MemoryGB);
                    HostSockets              = $($vmHost.Sockets);
                    HostCoresPerSocket       = $($vmHost.CoresPerSocket);
                    HostCpuThreads           = $($vmHost.CpuThreads);
                    HostHTActive             = $($vmHost.HTActive);
                    HostPowerPolicy          = $($vmHost.PowerPolicy);
                    VMName                   = $($vm.Name);
                    VMHWVersion              = $($vm.HWVersion);
                    VMCpuHotAddEnabled       = $($vm.CpuHotAdd).ToString();
                    VMMemoryGB               = $($vm.MemoryGB);
                    VMSockets                = $($vm.Sockets);
                    VMCoresPerSocket         = $($vm.CoresPerSocket);
                    vCPUs                    = $($vm.NumCPU);
                    VMOptimized              = $vmOptimized;
                    OptimalSockets           = $optSockets;
                    OptimalCoresPerSocket    = $optCoresPerSocket;;
                    Priority                 = $priority;
                    Details                  = $details.Trim("| ")
                    } #end pscustomobject
            }
            $results += $objInfo
        }
        Catch
        {
            Write-Error "Error calculationing optimal CPU for $($vm.Name): $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"
        }
        $n++
    }#end foreach ($vm in $vms)
    Write-Progress -Activity "Calculating Optimum vCPU Config for VMs" -Completed
    Return $results
}