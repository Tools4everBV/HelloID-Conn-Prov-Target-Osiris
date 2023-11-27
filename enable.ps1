########################################
# HelloID-Conn-Prov-Target-Osiris-Enable
#
# Version: 1.0.1
########################################
# Initialize default values
$config = $configuration | ConvertFrom-Json
$p = $person | ConvertFrom-Json
$aRef = $AccountReference | ConvertFrom-Json
$success = $false
$auditLogs = [System.Collections.Generic.List[PSCustomObject]]::new()

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

# Set debug logging
switch ($($config.IsDebug)) {
    $true { $VerbosePreference = 'Continue' }
    $false { $VerbosePreference = 'SilentlyContinue' }
}

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

# Begin
try {
    Write-Verbose "Verifying if a Osiris account for [$($p.DisplayName)] exists"
    # Make sure to fail the action if the account does not exist in the target system!

    $headers = @{
        'Api-Key'      = $config.ApiKey
        'Content-Type' = 'application/json'
        Accept         = 'application/json'
    }

    if ($null -eq $aRef.internalId) {
        throw "Account reference is empty, cannot enable Osiris account"
    }

    # Get employee
    $encodedGeneriekUserQuery = Resolve-UrlEncoding -InputString "{`"mede_id`":`"$($aRef.internalId)`"}"
    $splatGetUserGeneriekParams = @{
        Uri     = "$($config.BaseUrl)/generiek/medewerker/?q=$($encodedGeneriekUserQuery)"
        Method  = 'GET'
        Headers = $headers
    }
    $currentAccount = (Invoke-RestMethod @splatGetUserGeneriekParams -Verbose:$false).items

    if ($null -eq $currentAccount) {
        throw "Can't enable account for employee [$($aRef.internalId)], possibly deleted"
    }

    # Add an auditMessage showing what will happen during enforcement
    if ($dryRun -eq $true) {
        Write-Warning "[DryRun] Enable Osiris account for: [$($p.DisplayName)] will be executed during enforcement"
    }

    # Process
    if (-not($dryRun -eq $true)) {
        Write-Verbose "Enabling Osiris account with accountReference: [$($aRef.internalId)]"

        # Account object, object in $currentAccount is different compared to the body of the put
        $targetAccount = [PSCustomObject]@{
            p_medewerker           = $currentAccount.medewerker
            p_achternaam           = $currentAccount.achternaam
            p_voorvoegsels         = $currentAccount.voorvoegsels
            p_voorletters          = $currentAccount.voorletters
            p_roepnaam             = $currentAccount.roepnaam
            p_geslacht             = $currentAccount.geslacht
            p_titel                = $currentAccount.titel
            p_titel_achter         = $currentAccount.titel_achter
            p_indienst             = "J"
            p_ldap_login           = $currentAccount.ldap_login
            p_extern_onderhouden   = $currentAccount.extern_onderhouden
            p_e_mail_adres         = $currentAccount.e_mail_adres
            p_faculteit            = "#ONVERANDERD#"
            p_organisatieonderdeel = "#ONVERANDERD#"
            p_profiel              = "#ONVERANDERD#"
            p_opleiding            = "#ONVERANDERD#"
            p_onderdeel_toegang    = "#ONVERANDERD#"
            p_opleiding_werkzaam   = "#ONVERANDERD#"
        }

        $body = ($targetAccount | ConvertTo-Json -Depth 10)           
        $splatAddUserParams = @{
            Uri         = "$($config.BaseUrl)/basis/medewerker"
            Method      = 'PUT'
            Body        = ([System.Text.Encoding]::UTF8.GetBytes($body))
            Headers     = $headers
            ContentType = "application/json;charset=utf-8"
        }
        $response = Invoke-RestMethod @splatAddUserParams -Verbose:$false # Exception if not found

        # if response has a error code throw
        if (-Not([string]::IsNullOrEmpty($response.statusmeldingen.code))) {
            throw "Osiris returned a error [$($response.statusmeldingen | convertto-json)]"
        }

        $success = $true
        $auditLogs.Add([PSCustomObject]@{
                Message = 'Enable account was successful'
                IsError = $false
            })
    }
}
catch {
    $success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-OsirisError -ErrorObject $ex
        $auditMessage = "Could not enable Osiris account. Error: $($errorObj.FriendlyMessage)"
        Write-Verbose "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditMessage = "Could not enable Osiris account. Error: $($ex.Exception.Message)"
        Write-Verbose "Error at Line '$($ex.InvocationInfo.ScriptLineNumber)': $($ex.InvocationInfo.Line). Error: $($ex.Exception.Message)"
    }
    $auditLogs.Add([PSCustomObject]@{
            Message = $auditMessage
            IsError = $true
        })
    # End
}
finally {
    $result = [PSCustomObject]@{
        Success   = $success
        Auditlogs = $auditLogs
    }
    Write-Output $result | ConvertTo-Json -Depth 10
}