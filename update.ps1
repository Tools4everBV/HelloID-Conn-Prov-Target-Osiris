#################################################
# HelloID-Conn-Prov-Target-Osiris-Update
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

function Resolve-UrlEncoding {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object]
        $InputString
    )
    process {
        try {
            $UrlEncodedString = ([URI]::EscapeUriString($InputString))
            Write-Output $UrlEncodedString
        }
        catch {
            throw "Could not encode query, error: $($_.Exception.Message)"
        }
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
    # Verify if [aRef] has a value
    if ([string]::IsNullOrEmpty($($actionContext.References.Account))) {
        throw 'The account reference could not be found'
    }

    $headers = @{
        'Api-Key'      = "$($actionContext.configuration.ApiKey)"
        'Content-Type' = 'application/json'
        Accept         = 'application/json'
    }

    Write-Information 'Verifying if a Osiris account exists'
    $encodedGeneriekUserQuery = Resolve-UrlEncoding -InputString "{`"mede_id`":`"$($actionContext.References.Account)`"}"
    $splatGetUserGeneriekParams = @{
        Uri     = "$($actionContext.Configuration.BaseUrl)/generiek/medewerker/?q=$($encodedGeneriekUserQuery)"
        Method  = 'GET'
        Headers = $headers
    }
    $correlatedAccount = (Invoke-RestMethod @splatGetUserGeneriekParams -Verbose:$false).items  

    if ($null -ne $correlatedAccount) {
        if ($correlatedAccount.Count -gt 1) {
            throw "Multiple accounts found for person where mede_id is: [$($actionContext.References.Account)]"
        }

        $correlatedAccount = ($correlatedAccount | Select-Object -First 1)
        $outputContext.PreviousData = $correlatedAccount | ConvertTo-AccountObject -AccountModel $outputContext.Data
        # Always compare the account against the current account in target system
        $splatCompareProperties = @{
            ReferenceObject  = @($outputContext.PreviousData.PSObject.Properties)
            DifferenceObject = @($actionContext.Data.PSObject.Properties)
        }
        $propertiesChanged = Compare-Object @splatCompareProperties -PassThru | Where-Object { ($_.SideIndicator -eq '=>') -and ($_.Value -ne '#ONVERANDERD#') }
        if ($propertiesChanged) {
            $action = 'UpdateAccount'
        } else {
            $action = 'NoChanges'
        }
    } else {
        $action = 'NotFound'
    }

    # Process
    switch ($action) {
        'UpdateAccount' {
            Write-Information "Account property(s) required to update: $($propertiesChanged.Name -join ', ')"
            if (-not($actionContext.DryRun -eq $true)) {
                Write-Information "Updating Osiris account with accountReference: [$($actionContext.References.Account)]"
                $body = $actionContext.Data
                $body | Add-Member -MemberType 'NotePropery' -Name "p_medewerker" -value $correlatedAccount.medewerker
                $body = ($body | ConvertTo-Json -Depth 10)
                $splatAddUserParams = @{
                    Uri         = "$($actionContext.Configuration.BaseUrl)/basis/medewerker"
                    Method      = 'PUT'
                    Body        = ([System.Text.Encoding]::UTF8.GetBytes($body))
                    Headers     = $headers
                    ContentType = "application/json;charset=utf-8"
                }
                $response = Invoke-RestMethod @splatAddUserParams -Verbose:$false
                if (-Not([string]::IsNullOrEmpty($response.statusmeldingen.code))) {
                    throw "Osiris returned a error [$($response.statusmeldingen | convertto-json)]"
                }

                $outputContext.Success = $true
                $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = "Update account was successful, Account property(s) updated: [$($propertiesChanged.name -join ',')]"
                    IsError = $false
                })

                # check if updaten of free field is required
                if ($actionContext.CorrelationConfiguration.Enabled) {
                    $correlationField = $actionContext.CorrelationConfiguration.AccountField
                    $correlationValue = $actionContext.CorrelationConfiguration.PersonFieldValue

                    if ([string]::IsNullOrEmpty($($correlationField))) {
                        throw 'Correlation is enabled but not configured correctly'
                    }
                    if ([string]::IsNullOrEmpty($($correlationValue))) {
                        throw 'Correlation is enabled but [accountFieldValue] is empty. Please make sure it is correctly mapped'
                    }

                    $encodedOpenFieldQuery = Resolve-UrlEncoding -InputString "{`"vrij_veld`":`"$correlationField`",`"rubriek`":`"HRM`",`"medewerker`":`"$($correlatedAccount.medewerker)`"}"
                    $splatOpenFieldParams = @{
                        Uri     = "$($actionContext.Configuration.BaseUrl)/generiek/medewerker/vrij_veld/?q=$($encodedOpenFieldQuery)"
                        Method  = 'GET'
                        Headers = $headers
                    }
                    $targetOpenField = Invoke-RestMethod @splatOpenFieldParams -Verbose:$false

                    if ($targetOpenField.inhoud_verkort -ne $correlationValue) {
                         # Create or update open field [vrij veld]
                        $openField = @{
                            medewerker         = $correlatedAccount.medewerker
                            rubriek            = "HRM"
                            volgnummer_rubriek = 1
                            vrij_veld          = $correlationField
                            inhoud             = $correlationValue
                            inhoud_verkort     = $correlationValue
                            referentietabel    = "mede"
                            referentie_id      = $correlatedAccount.mede_id
                            mvrv_id            = $targetOpenFieldId
                        }

                        $openFieldBody = ($openField | ConvertTo-Json -Depth 10)
                        $splatAddOpenFieldParams = @{
                            Uri     = "$($actionContext.Configuration.BaseUrl)/generiek/medewerker/vrij_veld/"
                            Method  = 'POST'
                            Body    = ([System.Text.Encoding]::UTF8.GetBytes($openFieldBody))
                            Headers = $headers
                        }
                        $response = Invoke-RestMethod @splatAddOpenFieldParams -Verbose:$false # Exception if not found
                        # if response has a error code throw
                        if (-Not([string]::IsNullOrEmpty($response.statusmeldingen.code))) {
                            throw "Updating vrij_veld failed with message [$($response.statusmeldingen | convertto-json)]"
                        }
                    }
                }
            } else {
                Write-Information "[DryRun] Update Osiris account with accountReference: [$($actionContext.References.Account)], will be executed during enforcement"
            }
            break
        }

        'NoChanges' {
            Write-Information "No changes to Osiris account with accountReference: [$($actionContext.References.Account)]"

            $outputContext.Success = $true
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = 'No changes will be made to the account during enforcement'
                    IsError = $false
                })
            break
        }

        'NotFound' {
            Write-Information "Osiris account: [$($actionContext.References.Account)] could not be found, indicating that it may have been deleted"
            $outputContext.Success = $false
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = "Osiris account: [$($actionContext.References.Account)] could not be found, indicating that it may have been deleted"
                    IsError = $true
                })
            break
        }
    }
} catch {
    $outputContext.Success  = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-OsirisError -ErrorObject $ex
        $auditMessage = "Could not update Osiris account. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    } else {
        $auditMessage = "Could not update Osiris account. Error: $($ex.Exception.Message)"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditMessage
            IsError = $true
        })
}
