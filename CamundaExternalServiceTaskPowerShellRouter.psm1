#Requires -Modules CamundaPowerShell
#Requires -Version 5

$TopicNamesToGetExternalTasksFor = @"
Get-BPMNADUserSAMAccountNameFromName
Disable-ADAccount
"@ -split "`r`n"

$TimeToLockTasksInMS = 1000

function Install-CamundaExternalServiceTaskPowerShellRouter {
    param(
        [parameter(Mandatory)]$CamundaServer,
        $PathToScriptForScheduledTask = $PSScriptRoot,
        [parameter(Mandatory)]$ScheduledTaskUserPassword
    )
    
    [Environment]::SetEnvironmentVariable("CamundaServer", $CamundaServer, "User")

@"
Invoke-CamundaExternalServiceTaskPowerShellRouting
"@ | Out-File "$PathToScriptForScheduledTask\Invoke-CamundaExternalServiceTaskPowerShellRouting.ps1"


    $ScriptFilePath = "$PathToScriptForScheduledTask\Invoke-CamundaExternalServiceTaskPowerShellRouting.ps1"

    $ScheduledTaskAction = New-ScheduledTaskAction –Execute "Powershell.exe" -Argument "-noprofile -file $ScriptFilePath"
    $ScheduledTaskTrigger = New-ScheduledTaskTrigger -Daily -At 12am
    $ScheduledTaskSettingsSet = New-ScheduledTaskSettingsSet
    $Task = Register-ScheduledTask -TaskName "Invoke-CamundaExternalServiceTaskPowerShellRouting" `
                    -TaskPath "\" `
                    -Action $ScheduledTaskAction `
                    -Trigger $ScheduledTaskTrigger `
                    -User "$env:USERDOMAIN\$env:USERNAME" `
                    -Password $ScheduledTaskUserPassword `
                    -Settings $ScheduledTaskSettingsSet

    $Task.Triggers[0].ExecutionTimeLimit = "PT30M"
    $task.Triggers.Repetition.Duration = "P1D" 
    $task.Triggers.Repetition.Interval = "PT1M"
    $task | Set-ScheduledTask -Password $ScheduledTaskUserPassword -User "$env:USERDOMAIN\$env:USERNAME"
}

function Uninstall-CamundaExternalServiceTaskPowerShellRouter {
    $Task = Get-ScheduledTask | where taskname -match "Invoke-CamundaExternalServiceTaskPowerShellRouting"
    $Task | Unregister-ScheduledTask
}

function Invoke-CamundaExternalServiceTaskPowerShellRouting {
    $CamundaTopics = @()
    $CamundaTopics += foreach ($TopicNameToGetExternalTasksFor in $TopicNamesToGetExternalTasksFor) {
        $PowerShellFunctionName = $TopicNameToGetExternalTasksFor
        Try {
            $PowerShellFunctionParameterNames = get-help $PowerShellFunctionName | 
                select -ExpandProperty parameters | 
                select -ExpandProperty parameter | 
                select -ExpandProperty name
            New-CamundaTopic -topicName $TopicNameToGetExternalTasksFor -lockDuration $TimeToLockTasksInMS -VariableNames $PowerShellFunctionParameterNames
        } catch { 
            throw "Couldn't process all the TopicNamesToGetExternalTasksFor, check to make sure they are all valid powershell functions" 
        }
    }

    $ExternalServiceTasks = Get-CamundaExternalTasksAndLock -workerID "PowerShell" -maxTasks 100 -topics $CamundaTopics

    foreach ($ExternalServiceTask in $ExternalServiceTasks) {

        $PowerShellFunctionName = $ExternalServiceTask.topicName
        
        $ExternalTaskVariables = foreach ($Property in $ExternalServiceTask.variables.psobject.Properties) {
            [pscustomobject]@{
                Name = $Property.Name 
                Value = $Property.value.value
            }
        }

        $PowerShellFunctionParameters = foreach ($Variable in $ExternalTaskVariables) {
            "-" + $Variable.Name + ' "' + $Variable.value + '"' 
        }

        $PowerShellCommand = $PowerShellFunctionName + " " + $PowerShellFunctionParameters -join " "
        $Variables = @{}

        try {
            $PowerShellResult = Invoke-Expression $PowerShellCommand
            $Variables += $PowerShellResult | ConvertTo-CamundaVariable | ConvertTo-HashTable
            Complete-CamundaExternalTask -ExternalTaskID $ExternalServiceTask.id -WorkerID "PowerShell" -Variables $Variables
        } catch {
            $ExceptionString = $_.Exception.Message
            Invoke-CamundaExternalTaskFailure -ExternalTaskID $ExternalServiceTask.id -WorkerID "PowerShell" -ErrorMessage $_.Exception.Message
        }
    
        #$Variables += New-CamundaVariable -Name "Response" -Value $PowerShellResult | ConvertTo-HashTable
        

        #$PowerShellResult | ConvertTo-CamundaVariable

    }
}


$DotNetToCamundaTypeMappings = [pscustomobject][ordered]@{
    DotNetTypeName = "System.Int32"
    CamundaTypeName = "integer"
},
[pscustomobject][ordered]@{
    DotNetTypeName = "System.Int16"
    CamundaTypeName = "short"
},
[pscustomobject][ordered]@{
    DotNetTypeName = "System.Boolean"
    CamundaTypeName = "boolean"
},
[pscustomobject][ordered]@{
    DotNetTypeName = "System.Int64"
    CamundaTypeName = "long"
},
[pscustomobject][ordered]@{
    DotNetTypeName = "System.Double"
    CamundaTypeName = "double"
},
[pscustomobject][ordered]@{
    DotNetTypeName = "System.DateTime"
    CamundaTypeName = "date"
},
[pscustomobject][ordered]@{
    DotNetTypeName = "System.String"
    CamundaTypeName = "string"
},
[pscustomobject][ordered]@{
    DotNetTypeName = "System.Xml.XmlDocument"
    CamundaTypeName = "XML"
}
#,
#[pscustomobject][ordered]@{
#    DotNetTypeName = ""
#    CamundaTypeName = "JSON"
#},
#[pscustomobject][ordered]@{
#    DotNetTypeName = ""
#    CamundaTypeName = "file"
#},
#[pscustomobject][ordered]@{
#    DotNetTypeName = ""
#    CamundaTypeName = "bytes"
#},

function ConvertTo-CamundaVariable {
    param(
        [Parameter(Mandatory,ValueFromPipeline)]$InputObject
    )

    Foreach ($Property in $InputObject.psobject.properties) {

        if ($Property.typenameofvalue -in $DotNetToCamundaTypeMappings.dotnettypename) {
            $CamundaTypeName = $DotNetToCamundaTypeMappings | 
            where dotnettypename -eq $Property.typenameofvalue |
            Select -ExpandProperty CamundaTypeName

            New-CamundaVariable -Name $Property.Name -Value $Property.Value -Type $CamundaTypeName
        } else {
            New-CamundaVariable -Name $Property.Name -Value $Property.Value -Type JSON
        }
    }
}

function ConvertTo-HashTable {
    #Inspired by http://stackoverflow.com/questions/3740128/pscustomobject-to-hashtable
    param(
        [Parameter(ValueFromPipeline)]$Object
    )
    $HashTable = @{}
    $Object.psobject.properties | Foreach { $HashTable[$_.Name] = $_.Value }
    $HashTable
}
