#This Scripts could not used to run NDIS job current currently,it is still under developing
#Tested passed in following scenario :
#1.install all the guest platforms 
#2.same version driver sumbit to HCK Manager at different time
#3.same driver w/ Different version use the same devicefamily 
#todo list:
#1.NDIS test support
#2.Exception handle
#3.make the scripts into function
# Author: Mike Cao <bcao@redhat.com>

$ObjectModel = [Reflection.Assembly]::LoadFrom($env:WTTSTDIO + "microsoft.windows.Kits.Hardware.objectmodel.dll")
$ObjectModel = [Reflection.Assembly]::LoadFrom($env:WTTSTDIO + "microsoft.windows.Kits.Hardware.objectmodel.dbconnection.dll")

Clear-Host
Write-Host "Usage: %SystemRoot%\syswow64\WindowsPowerShell\v1.0\powershell.exe -file network2.ps1 <<ControllerMachineName>> <<Driver_name>> <<Driver version>> "

$ControllerName = $args[0]
$Driver = $args[1]
$Driver_version = $args[2]
$projectname = "virtio-win-prewhql-"+$Driver_version+"-"+$Driver

if ($Driver -eq $null -OR $Driver  -eq "")
{
    write-host "Pls supply which driver you want to be tested viostor, netkvm, vioscsi, balloon, vioser "
    return
} #end of if

if ($Driver_version  -eq $null -OR $Driver_version  -eq "")
{
    write-host "Need to supply the driver version for whql"
    return
} #end of if

if ($ControllerName -eq $null -OR $ControllerName -eq "")
{
    write-host "Need to supply the controller Name as a parameter to this script"
    return
} #end of if
else
{
    write-host connecting to the controller $ControllerName
} #end of if

# create a device family via the param provided by user

switch($Driver)
{
    
    {$Driver -eq "netkvm"} {Write-host "netkvm";[string[]]$HardwareIds = "PCI\VEN_1AF4&DEV_1000&SUBSYS_00011AF4"; $MachineNameSignature = "NIC"; break}
    
    default {Write-host Invalid driver name ,pls check whehter you type viostor netkvm vioscsi vioser balloon; return}
}  # end of switch


# connect to the controller
$Manager = new-object -typename Microsoft.Windows.Kits.Hardware.ObjectModel.DBConnection.DatabaseProjectManager -Args $ControllerName, DTMJobs

$RootPool = $Manager.GetRootMachinePool()
$DefaultPool = $RootPool.DefaultPool

#load or create TestMachinePoolGroup
$TestPoolGroupFlag = 0
$RootPool.GetChildPools() | foreach {
    if ($_.Name -eq $projectname)
    {
    Write-Host $_.Path
    $TestPoolGroup = $_
    $TestPoolGroupFlag = 1
    } #end of if
} #end of GetChildPools() foreach
if ($TestPoolGroupFlag -eq "0")
{
$TestPoolGroup=$RootPool.CreateChildPool($projectname)
} #end of load or create TestMachinePoolGroup

#load or create a project
$projectFlag = 0
$Manager.GetProjectNames() | foreach {
    if ($_ -eq $projectname)
    {
	   $Project = $Manager.GetProject($projectname)
       $ProjectFlag = 1      
    } #end of if
} # end of GetProjectNames()

if ($ProjectFlag -eq "0")
{
    $Project = $Manager.CreateProject($projectname)
    $TestPoolGroup = $RootPool.CreateChildPool($projectname)
} #end of if

#Load or create a DeviceFamily
$DeviceFamilyFlag = 0
$Manager.GetDeviceFamilies() | foreach {
    Write-Host $_.name
    if ($_.name -eq $Driver)
    {
        $DeviceFamily = $_
        $DeviceFamilyFlag = 1
    } #end of if
} #end of GetDeviceFamilies foreach

if ($DeviceFamilyFlag -eq "0")
{
    $DeviceFamily = $Manager.CreateDeviceFamily($Driver, $HardwareIds)
} #end of if



"there are {0} machines in the default pool" -f $DefaultPool.GetMachines().Count

$DefaultPool.GetMachines() | foreach {
    write-host $_.Name
    if ($_.name.Contains($MachineNameSignature) -AND  ($_.name.SubString(13,1) -eq "C") ) {
        $SUT = $_       
        $MachineName = $SUT.Name
        $MachinePoolName = $SUT.Name.SubString(0,12)
        $TestMachinePoolFlag = 0    
        
        $TestPoolGroup.GetChildPools() | foreach {
            if($_.Name -eq $MachinePoolName) #if the pool exists ,move the previous guests to sub-pool
            {
                $TestPool = $_ 
                $TestMachinePoolFlag = 1
            }
            
        } # end if GetChildPools()
        
        if ($TestMachinePoolFlag -eq "0")
        {
            $TestPool = $TestPoolGroup.CreateChildPool($MachinePoolName)
        }
        
        $SlaveMachineFlag = 0 
        "Machine name {0}" -f $MachineName
        "TestPool {0}" -f $TestPool
        
        $DefaultPool.GetMachines() | foreach {   

            if(($_.Name -ne $MachineName) -And ($_.Name.SubString(0,12) -eq $TestPool.Name) -and ($_.Name.SubString(13,1) -eq "S")){
                $SlaveMachine = $_
                $DefaultPool.MoveMachineTo($_, $TestPool)
                $SlaveMachineFlag = 1
                Write-Host "we have slave hosts now "
            }
        
        } #end of get Slave clients 
        
        if ($SlaveMachineFlag -eq "1"){
            
            $DefaultPool.MoveMachineTo($SUT, $TestPool) #move SUT guests to Test Pool
            
            # now, make sure that the computers are in a ready state
            $TestPool.GetMachines() | foreach { $_.SetMachineStatus([Microsoft.Windows.Kits.Hardware.ObjectModel.MachineStatus]::Ready, 1)  }   
            sleep 10
            $ProductInstance = $Project.CreateProductInstance($MachineName, $TestPool, $SUT.OSPlatform)
            $TargetFamily = $ProductInstance.CreateTargetFamily($DeviceFamily)          
                
            "Targetdata count is {0}" -f $ProductInstance.FindTargetFromDeviceFamily($DeviceFamily).Count
            #find all the devices in this machine pool that are in this device family
            $ProductInstance.FindTargetFromDeviceFamily($DeviceFamily) | foreach {
                #"attempting to add target $_.Name on machine $_.Machine.Name to TargetFamily"
                # and add those to the target family
                # check this first, to make sure that this can be added to the target family
                 "TargetData name is {0}" -f $_.Name
                 "TargetData machine is {0}" -f $_.Machine.Name
                if ($TargetFamily.IsValidTarget($_) -And $_.Machine.Name -eq $MachineName) {                
                    $TargetFamily.CreateTarget($_)           
                } 
               
            }
            "mike cao want {0} " -f $TestPool.GetMachines().Count

            $TargetFamily.GetTests()| foreach {    
                "Test name :{0}" -f $_.Name 
                $MachineRole = $_.GetMachineRole()   #return machineset
                if ($MachineRole -eq "" -OR $MachineRole -eq $null) {
                    $_.QueueTest()
                    "job run"               
                }
       
                else {
                    $MachineRole.Roles[1].AddMachine($SlaveMachine)
                    $_.QueueTest($MachineRole)
                    "slave job run "
                }
            } # end of TestPool.GetTests
      
        }  #end of if SlaveMachineFlag =1
    } # ($_.name.Contains($MachineNameSignature) -AND  ($_.name.SubString(13,1) -eq "C") ) 
  
} # end of get machines
    
   