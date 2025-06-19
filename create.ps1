#################################################
# HelloID-Conn-Prov-Target-Osiris-Create
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
    # Initial Assignments
    $outputContext.AccountReference = 'Currently not available'

    $headers = @{
        'Api-Key'      = "$($actionContext.configuration.ApiKey)"
        'Content-Type' = 'application/json'
        Accept         = 'application/json'
    }

    # Validate correlation configuration
    if ($actionContext.CorrelationConfiguration.Enabled) {
        $correlationField = $actionContext.CorrelationConfiguration.AccountField
        $correlationValue = $actionContext.CorrelationConfiguration.PersonFieldValue

        if ([string]::IsNullOrEmpty($($correlationField))) {
            throw 'Correlation is enabled but not configured correctly'
        }
        if ([string]::IsNullOrEmpty($($correlationValue))) {
            throw 'Correlation is enabled but [accountFieldValue] is empty. Please make sure it is correctly mapped'
        }

        # Get open field [vrij veld]
        $encodedOpenFieldQuery = Resolve-UrlEncoding -InputString "{`"vrij_veld`":`"$correlationField`",`"rubriek`":`"HRM`",`"inhoud_verkort`":`"$correlationValue`"}"
        $splatOpenFieldParams = @{
            Uri     = "$($actionContext.Configuration.BaseUrl)/generiek/medewerker/vrij_veld/?q=$($encodedOpenFieldQuery)"
            Method  = 'GET'
            Headers = $headers
        }
        $targetOpenField = Invoke-RestMethod @splatOpenFieldParams -Verbose:$false
        if ($targetOpenField.items.count -gt 1) {
            throw ("Correlation failed. Multiple 'vrij_veld' items found with [$correlationField = $correlationValue]")
        }

        # Get employee
        if ($targetOpenField.items.referentie_id) {
            $encodedUserQuery = Resolve-UrlEncoding -InputString "{`"mede_id`":`"$($targetOpenField.items.referentie_id)`"}"
            $splatUserParams = @{
                Uri     = "$($actionContext.Configuration.BaseUrl)/generiek/medewerker/?q=$($encodedUserQuery)"
                Method  = 'GET'
                Headers = $headers
            }
            $correlatedAccount= (Invoke-RestMethod @splatUserParams -Verbose:$false).items
        }
    }

    if ($correlatedAccount.Count -eq 0) {
        $action = 'CreateAccount'
    } elseif ($correlatedAccount.Count -eq 1) {
        $action = 'CorrelateAccount'
        $correlatedAccount = ($correlatedAccount | Select-Object -First 1)
    } elseif ($correlatedAccount.Count -gt 1) {
        throw "Multiple accounts found for person where mede_id is: [$($targetOpenField.items.referentie_id)]"
    }

    # Process
    switch ($action) {
        'CreateAccount' {
            $splatCreateParams = @{
                Uri    = "$($actionContext.Configuration.BaseUrl)/basis/medewerker"
                Method = 'PUT'
                Body   = [System.Text.Encoding]::UTF8.GetBytes(($actionContext.Data | ConvertTo-Json))
                Headers = $headers
                ContentType = "application/json;charset=utf-8"
            }

            # Make sure to test with special characters and if needed; add utf8 encoding.
            if (-not($actionContext.DryRun -eq $true)) {
                Write-Information 'Creating and correlating Osiris account'
                $createdAccount = Invoke-RestMethod @splatCreateParams -Verbose:$false
                if (-Not([string]::IsNullOrEmpty($createdAccount.statusmeldingen.code))) {
                    throw "Osiris returned a error [$($createdAccount.statusmeldingen | convertto-json)]"
                }

                # Get the just created employee as a "generieke medewerker"  (required to access the mede_id field that will be used as reference)
                $encodedGeneriekUserQuery = Resolve-UrlEncoding -InputString "{`"ldap_login`":`"$($actionContext.Data.p_ldap_login)`"}"
                $splatGetUserGeneriekParams = @{
                    Uri     = "$($actionContext.Configuration.BaseUrl)/generiek/medewerker/?q=$($encodedGeneriekUserQuery)"
                    Method  = 'GET'
                    Headers = $headers
                }
                $generiekUser = Invoke-RestMethod @splatGetUserGeneriekParams -Verbose:$false
                $outputContext.Data = $generiekUser.items[0] | ConvertTo-AccountObject -AccountModel $outputContext.Data
                $outputContext.AccountReference = $generiekUser.items[0].mede_id

                if ($actionContext.CorrelationConfiguration.Enabled) {
                    try {
                        # Get open field [vrij veld]
                        $encodedOpenFieldQuery = Resolve-UrlEncoding -InputString "{`"vrij_veld`":`"$correlationField`",`"rubriek`":`"HRM`",`"medewerker`":`"$($generiekUser.items.medewerker)`"}"
                        $splatOpenFieldParams = @{
                            Uri     = "$($actionContext.Configuration.BaseUrl)/generiek/medewerker/vrij_veld/?q=$($encodedOpenFieldQuery)"
                            Method  = 'GET'
                            Headers = $headers
                        }
                        $targetOpenField = Invoke-RestMethod @splatOpenFieldParams -Verbose:$false
                        $targetOpenFieldId = $targetOpenField.items.mvrv_id
                        if ($targetOpenFieldId) {
                            Write-Warning "Open field [vrij veld] has not been created automatically with the correct value in the content [inhoud] property, creating new one"
                        }

                        # Create or update open field [vrij veld]
                        $openField = @{
                            medewerker         = $generiekUser.items.medewerker
                            rubriek            = "HRM"
                            volgnummer_rubriek = 1
                            vrij_veld          = $correlationField
                            inhoud             = $correlationValue
                            inhoud_verkort     = $correlationValue
                            referentietabel    = "mede"
                            referentie_id      = $generiekUser.items.mede_id
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
                            throw "Osiris returned a error [$($response.statusmeldingen | convertto-json)]"
                        }
                    }
                    catch {
                        $ex = $PSItem
                        $errorObj = Resolve-OsirisError -ErrorObject $ex
                        $auditMessage = "Setting open field [vrij veld] was not successful. AccountReference is: [$($outputContext.AccountReference)] Error: $($errorObj.FriendlyMessage)"                         
                        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
                        $outputContext.AuditLogs.Add([PSCustomObject]@{
                            Message = $auditMessage
                            IsError = $false
                        })                      
                    }
                }
               
            } else {
                Write-Information '[DryRun] Create and correlate Osiris account, will be executed during enforcement'
            }
            $auditLogMessage = "Create account was successful. AccountReference is: [$($outputContext.AccountReference)]"
            break
        }

        'CorrelateAccount' {
            Write-Information 'Correlating Osiris account'
            $outputContext.Data = $correlatedAccount | ConvertTo-AccountObject -AccountModel $outputContext.Data
            $outputContext.AccountReference = $correlatedAccount.mede_Id
            $outputContext.AccountCorrelated = $true
            $auditLogMessage = "Correlated account: [$($outputContext.AccountReference)] on field: [$($correlationField)] with value: [$($correlationValue)]"
            break
        }
    }

    $outputContext.success = $true
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Action  = $action
            Message = $auditLogMessage
            IsError = $false
        })
} catch {
    $outputContext.success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-OsirisError -ErrorObject $ex
        $auditMessage = "Could not create or correlate Osiris account. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    } else {
        $auditMessage = "Could not create or correlate Osiris account. Error: $($ex.Exception.Message)"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
            Message = $auditMessage
            IsError = $true
        })
}