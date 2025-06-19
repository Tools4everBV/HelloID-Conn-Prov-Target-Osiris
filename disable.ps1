#################################################
# HelloID-Conn-Prov-Target-Osiris-Disable
# PowerShell V2
#################################################

# TLS1.2
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
#endregion

try {
    # Verify if [aRef] has a value
    if ([string]::IsNullOrEmpty($($actionContext.References.Account))) {
        throw 'The account reference could not be found'
    }

    $headers = @{
        'Api-Key'      = $actionContext.Configuration.ApiKey
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
    $correlatedAccount = (Invoke-RestMethod @splatGetUserGeneriekParams).items

    if ($null -ne $correlatedAccount) {
        $action = 'DisableAccount'
        if ($correlatedAccount.Count -gt 1) {
            throw "Multiple accounts found for person where mede_id is: [$($actionContext.References.Account)]"
        }
        $correlatedAccount = ($correlatedAccount | Select-Object -First 1)
    } else {
        $action = 'NotFound'
    }

    # Process
    switch ($action) {
        'DisableAccount' {
            $targetAccount = [PSCustomObject]@{
                p_medewerker           = $correlatedAccount.medewerker
                p_achternaam           = $correlatedAccount.achternaam
                p_voorvoegsels         = $correlatedAccount.voorvoegsels
                p_voorletters          = $correlatedAccount.voorletters
                p_roepnaam             = $correlatedAccount.roepnaam
                p_geslacht             = $correlatedAccount.geslacht
                p_titel                = $correlatedAccount.titel
                p_titel_achter         = $correlatedAccount.titel_achter
                p_indienst             = "N"
                p_ldap_login           = $correlatedAccount.ldap_login
                p_extern_onderhouden   = $correlatedAccount.extern_onderhouden
                p_e_mail_adres         = $correlatedAccount.e_mail_adres
                p_faculteit            = "#ONVERANDERD#"
                p_organisatieonderdeel = "#ONVERANDERD#"
                p_profiel              = "#ONVERANDERD#"
                p_opleiding            = "#ONVERANDERD#"
                p_onderdeel_toegang    = "#ONVERANDERD#"
                p_opleiding_werkzaam   = "#ONVERANDERD#"
            }          
    
            $body = ($targetAccount | ConvertTo-Json -Depth 10)
            $splatAddUserParams = @{
                Uri         = "$($actionContext.Configuration.BaseUrl)/basis/medewerker"
                Method      = 'PUT'
                Body        = ([System.Text.Encoding]::UTF8.GetBytes($body))
                Headers     = $headers
                ContentType = "application/json;charset=utf-8"
            }
            if (-not($actionContext.DryRun -eq $true)) {
                Write-Information "Enabling Osiris account with accountReference: [$($actionContext.References.Account)]"
                $response = Invoke-RestMethod @splatAddUserParams -Verbose:$false
                if (-Not([string]::IsNullOrEmpty($response.statusmeldingen.code))) {
                    throw "Osiris returned a error [$($response.statusmeldingen | convertto-json)]"
                }
            } else {
                Write-Information "[DryRun] Disable Osiris account with accountReference: [$($actionContext.References.Account)], will be executed during enforcement"
            }

            $outputContext.Success = $true
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = 'Disable account [$($actionContext.References.Account)] was successful'
                    IsError = $false
                })
            break
        }

        'NotFound' {
            Write-Information "Osiris account: [$($actionContext.References.Account)] could not be found, indicating that it may have been deleted"
            $outputContext.Success = $true
            $outputContext.AuditLogs.Add([PSCustomObject]@{
                    Message = "Osiris account: [$($actionContext.References.Account)] could not be found, indicating that it may have been deleted"
                    IsError = $false
                })
            break
        }
    }

} catch {
    $outputContext.success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-OsirisError -ErrorObject $ex
        $auditMessage = "Could not Disable Osiris account. Error: $($errorObj.FriendlyMessage)"
        Write-Warning "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    } else {
        $auditMessage = "Could not Disable Osiris account. Error: $($_.Exception.Message)"
        Write-Warning "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $outputContext.AuditLogs.Add([PSCustomObject]@{
        Message = $auditMessage
        IsError = $true
    })
}