#Requires -Modules CamundaPowerShell
#Requires -Version 5

$TopicNamesToGetExternalTasksFor = @"
Get-ADUserSAMAccountNameFromName
"@ -split "`r`n"
#Disable-ADAccount

$TimeToLockTasksInMS = 1000

$CamundaTopics = foreach ($TopicNameToGetExternalTasksFor in $TopicNamesToGetExternalTasksFor) {
    $PowerShellFunctionName = $TopicNameToGetExternalTasksFor
    Try {
        $PowerShellFunctionParameterNames = get-help $PowerShellFunctionName | 
            select -ExpandProperty parameters | 
            select -ExpandProperty parameter | 
            select -ExpandProperty name
        New-CamundaTopic -topicName $TopicNameToGetExternalTasksFor -VariableNames $PowerShellFunctionParameterNames -lockDuration $TimeToLockTasksInMS
    } catch { 
        throw "Couldn't process all the TopicNamesToGetExternalTasksFor, check to make sure they are all valid powershell functions" 
    }
}

$ExternalServiceTasks = Get-CamundaExternalTasksAndLock -workerID "PowerShell" -maxTasks 100 -topics $CamundaTopics

$FetchAndLockJSONParameters = [pscustomobject][ordered]@{
    workerId = "PowerShell"
    maxTasks = 100
    topics = $CamundaTopics
} | ConvertTo-Json    


$ExternalServiceTasks = Invoke-WebRequest -Uri http://cmagnuson-lt:8080/engine-rest/external-task/fetchAndLock -Method Post -Body $FetchAndLockJSONParameters -Verbose -ContentType "application/json" |
select -ExpandProperty content |
ConvertFrom-Json

foreach ($ExternalServiceTask in $ExternalServiceTasks) {

    $PowerShellFunctionName = $ExternalServiceTask.topicName
    
    $PowerShellFunctionParameterNames = get-help $PowerShellFunctionName | 
    select -ExpandProperty parameters | 
    select -ExpandProperty parameter | 
    select -ExpandProperty name
    
    $ExternalTaskVariables = $ExternalServiceTask.variables | 
    Get-Member -MemberType NoteProperty | 
    select Name, @{
        Name = "Value"
        Expression = {$ExternalServiceTask.variables."$($_.Name)".value}
    }

    $ExternalTaskVariablesThatMatchPowerShellFunctionParameters = $ExternalTaskVariables |
    Where Name -in $PowerShellFunctionParameterNames

    $PowerShellFunctionParameters = foreach ($Variable in $ExternalTaskVariablesThatMatchPowerShellFunctionParameters) {
        "-" + $Variable.Name + ' "' + $Variable.value + '"' 
    }

    $PowerShellCommand = $PowerShellFunctionName + " " + $PowerShellFunctionParameters -join " "
    $PowerShellResult = Invoke-Expression $PowerShellCommand

    $CompleteTaskJSONParameters = [pscustomobject][ordered]@{
        workerId = "PowerShell"
        variables = [pscustomobject][ordered]@{
            Response = [pscustomobject][ordered]@{ 
                value = $PowerShellResult 
            }
        }        
    } | ConvertTo-Json


    $TaskCompleteResponse = Invoke-WebRequest -Uri "http://cmagnuson-lt:8080/engine-rest/external-task/$($ExternalServiceTask.id)/complete" -Method Post -Body $CompleteTaskJSONParameters -Verbose -ContentType "application/json"
    




}


Invoke-WebRequest -Uri http://cmagnuson-lt:8080/engine-rest/external-task/count -Method Post <#-Credential (Get-Credential)#> -ContentType "application/json" -Body '{"topicName":"Get-ADUserSAMAccountNameFromName"}'
