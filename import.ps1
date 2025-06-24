#################################################
# HelloID-Conn-Prov-Target-Osiris-Import
# PowerShell V2
#################################################

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

#region functions
function Resolve-OsirisError {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object]
        $ErrorObject
    )
    process {
        $httpErrorObj = [PSCustomObject]@{
            ScriptLineNumber = $ErrorObject.InvocationInfo.ScriptLineNumber
            Line             = $ErrorObject.InvocationInfo.Line
            ErrorDetails     = $ErrorObject.Exception.Message
            FriendlyMessage  = $ErrorObject.Exception.Message
        }
        if ($ErrorObject.ErrorDetails) {
            $httpErrorObj.ErrorDetails = $ErrorObject.ErrorDetails
            $httpErrorObj.FriendlyMessage = $ErrorObject.ErrorDetails
        }
        elseif ((-not($null -eq $ErrorObject.Exception.Response) -and $ErrorObject.Exception.GetType().FullName -eq 'System.Net.WebException')) {
            $streamReaderResponse = [System.IO.StreamReader]::new($ErrorObject.Exception.Response.GetResponseStream()).ReadToEnd()
            if (-not([string]::IsNullOrWhiteSpace($streamReaderResponse))) {
                $httpErrorObj.ErrorDetails = $streamReaderResponse
                $httpErrorObj.FriendlyMessage = $streamReaderResponse
            }
        }
        try {
            $httpErrorObj.FriendlyMessage = ($httpErrorObj.FriendlyMessage | ConvertFrom-Json).error_description
        }
        catch {
            # Displaying the old message if an error occurs during an API call, as the error is related to the API call and not the conversion process to JSON.
            Write-Warning "Unexpected web-service response, Error during Json conversion: $($_.Exception.Message)"
        }
        Write-Output $httpErrorObj
    }
}

function ConvertTo-AccountObject {
    param(
        [parameter(Mandatory)]
        [PSCustomObject]
        $AccountModel,

        [parameter( Mandatory,
            ValueFromPipeline = $True)]
        [PSCustomObject]
        $SourceObject
    )
    try {
            $modifiedObject = [PSCustomObject]@{}
            foreach ($property in $AccountModel.PSObject.Properties) {
                $LookupName = ($property.Name).SubString(2,$property.Name.length - 2)
                $modifiedObject | Add-Member @{ $($property.Name) = $SourceObject.$LookupName}
            }
            Write-Output $modifiedObject
    } catch {
         $PSCmdlet.ThrowTerminatingError($_)
    }
}
#endregion

try {
    Write-Information 'Starting Osiris account entitlement import'
    $headers = @{
        'Api-Key'      = "$($actionContext.configuration.ApiKey)"
        'Content-Type' = 'application/json'
        Accept         = 'application/json'
    }   
   
    $splatGetUserGeneriekParams = @{
        Uri     = "$($actionContext.Configuration.BaseUrl)/generiek/medewerker/"
        Method  = 'GET'
        Headers = $headers
    }
    $importedAccounts = (Invoke-RestMethod @splatGetUserGeneriekParams -Verbose:$false).items 

    foreach ($importedAccount in $importedAccounts) {
        $data = @{}
        $AccountObject = $importedAccount |  ConvertTo-AccountObject -AccountModel $outputContext.Data        
        foreach ($field in $actionContext.ImportFields) {                         
            $data[$field] = $AccountObject[$field]
        }
        if ($actionContext.CorrelationConfiguration.Enabled) {
            $correlationField = $actionContext.CorrelationConfiguration.AccountField
            $correlationValue = $actionContext.CorrelationConfiguration.PersonFieldValue

            if ([string]::IsNullOrEmpty($($correlationField))) {
                throw 'Correlation is enabled but not configured correctly'
            }
            if ([string]::IsNullOrEmpty($($correlationValue))) {
                throw 'Correlation is enabled but [accountFieldValue] is empty. Please make sure it is correctly mapped'
            }
            $encodedOpenFieldQuery = Resolve-UrlEncoding -InputString "{`"vrij_veld`":`"$correlationField`",`"rubriek`":`"HRM`",`"medewerker`":`"$($AccountObject.medewerker)`"}"
            $splatOpenFieldParams = @{
                Uri     = "$($actionContext.Configuration.BaseUrl)/generiek/medewerker/vrij_veld/?q=$($encodedOpenFieldQuery)"
                Method  = 'GET'
                Headers = $headers
            }
            $targetOpenField = Invoke-RestMethod @splatOpenFieldParams -Verbose:$false
            $data['PersID'] = $targetOpenField.inhoud
        }

        # Return the result
        [bool] $enabled = $false
        if ($AccountObject.indienst -eq "J")
        {
            $enabled = $true
        }
        Write-Output @{
            AccountReference = $importedAccount.mede_id
            DisplayName      = $AccountObject.ldap_login
            UserName         = $AccountObject.ldap_login
            Enabled          = $enabled
            Data             = $data
        }
    }
    Write-Information 'Osiris account entitlement import completed'
} catch {
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-OsirisError -ErrorObject $ex
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
        Write-Error "Could not import Osiris account entitlements. Error: $($errorObj.FriendlyMessage)"
    } else {
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
        Write-Error "Could not import Osiris account entitlements. Error: $($ex.Exception.Message)"
    }
}