#Requires -Modules CamundaPowerShell
#Requires -Version 5

$TopicNamesToGetExternalTasksFor = @"
Get-ADUserSAMAccountNameFromName
Disable-ADAccount
"@ -split "`r`n"

$TimeToLockTasksInMS = 1000

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
        $PowerShellResult = Invoke-Expression $PowerShellCommand
    
        $Variables = @{}
        $Variables += New-CamundaVariable -Name "Response" -Value $PowerShellResult | ConvertTo-HashTable

        Complete-CamundaExternalTask -ExternalTaskID $ExternalServiceTask.id -WorkerID "PowerShell" -Variables $Variables
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
