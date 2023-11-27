########################################
# HelloID-Conn-Prov-Target-Osiris-Create
#
# Version: 1.0.1
########################################
# Initialize default values
$config = $configuration | ConvertFrom-Json
$p = $person | ConvertFrom-Json
$success = $false
$auditLogs = [System.Collections.Generic.List[PSCustomObject]]::new()

switch ($p.Details.gender) {
    { ($_ -eq "man") -or ($_ -eq "male") -or ($_ -eq "M") } {
        $gender = "M"
    }
    { ($_ -eq "vrouw") -or ($_ -eq "female") -or ($_ -eq "V") } {
        $gender = "V"
    }
    Default {
        $gender = "O"
    }
}

# Account mapping
$account = [PSCustomObject]@{
    p_medewerker           = $p.DisplayName
    p_achternaam           = $p.Name.FamilyName
    p_voorvoegsels         = $p.Name.FamilyNamePrefix
    p_voorletters          = $p.Name.Initials
    p_roepnaam             = $p.Name.NickName
    p_geslacht             = $gender
    p_titel                = ""
    p_titel_achter         = ""
    p_indienst             = "N"
    p_ldap_login           = $p.Accounts.MicrosoftActiveDirectory.SamAccountName
    p_extern_onderhouden   = "J"
    p_e_mail_adres         = $p.Accounts.MicrosoftActiveDirectory.mail
    p_faculteit            = "#ONVERANDERD#"
    p_organisatieonderdeel = "#ONVERANDERD#"
    p_profiel              = "#ONVERANDERD#"
    p_opleiding            = "#ONVERANDERD#"
    p_onderdeel_toegang    = "#ONVERANDERD#"
    p_opleiding_werkzaam   = "#ONVERANDERD#"
}

# Enable TLS1.2
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

# Set debug logging
switch ($($config.IsDebug)) {
    $true { $VerbosePreference = 'Continue' }
    $false { $VerbosePreference = 'SilentlyContinue' }
}

# Region functions
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
# Endregion

# Begin
try {
    # Account object mapping
    $account.p_medewerker = $account.p_medewerker.ToUpper()

    # Verify if a user must be either [created and correlated], [updated and correlated] or just [correlated]
    $headers = @{
        'Api-Key'      = $config.ApiKey
        'Content-Type' = 'application/json'
        Accept         = 'application/json'
    }

    # Get open field [vrij veld]
    $encodedOpenFieldQuery = Resolve-UrlEncoding -InputString "{`"vrij_veld`":`"PersID`",`"rubriek`":`"HRM`",`"inhoud_verkort`":`"$($p.ExternalId)`"}"
    $splatOpenFieldParams = @{
        Uri     = "$($config.BaseUrl)/generiek/medewerker/vrij_veld/?q=$($encodedOpenFieldQuery)"
        Method  = 'GET'
        Headers = $headers
    }
    $targetOpenField = Invoke-RestMethod @splatOpenFieldParams -Verbose:$false # Exception if not found

    # Get employee
    if ($targetOpenField.items.referentie_id) {
        $encodedUserQuery = Resolve-UrlEncoding -InputString "{`"mede_id`":`"$($targetOpenField.items.referentie_id)`"}"
        $splatUserParams = @{
            Uri     = "$($config.BaseUrl)/generiek/medewerker/?q=$($encodedUserQuery)"
            Method  = 'GET'
            Headers = $headers
        }

        $responseUser = (Invoke-RestMethod @splatUserParams -Verbose:$false).items  # Exception if not found
    }

    if ($responseUser.count -lt 1) {
        $action = 'Create-Correlate'
    }
    elseif ($($config.UpdatePersonOnCorrelate) -eq $true) {
        $action = 'Update-Correlate'
    }
    else {
        $action = 'Correlate'
    }

    # Add a warning message showing what will happen during enforcement
    if ($dryRun -eq $true) {
        Write-Warning "[DryRun] $action Osiris account for: [$($p.DisplayName)], will be executed during enforcement"
        $aRef = "Unkown"
    }
    # Process
    if (-not($dryRun -eq $true)) {
        switch ($action) {
            'Create-Correlate' {
                Write-Verbose 'Creating and correlating Osiris account'

                # Is set to true if the update script needs to set the externalId in the open field [vrij veld]
                $isPersIdUpdateRequred = $false

                # Create employee
                $body = ($account | ConvertTo-Json -Depth 10)
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

                # Get employee
                $encodedGeneriekUserQuery = Resolve-UrlEncoding -InputString "{`"ldap_login`":`"$($account.p_ldap_login)`"}"
                $splatGetUserGeneriekParams = @{
                    Uri     = "$($config.BaseUrl)/generiek/medewerker/?q=$($encodedGeneriekUserQuery)"
                    Method  = 'GET'
                    Headers = $headers
                }
                $generiekUser = Invoke-RestMethod @splatGetUserGeneriekParams -Verbose:$false # Exception if not found

                try {
                    # Get open field [vrij veld]
                    $encodedOpenFieldQuery = Resolve-UrlEncoding -InputString "{`"vrij_veld`":`"PersID`",`"rubriek`":`"HRM`",`"medewerker`":`"$($generiekUser.items.medewerker)`"}"
                    $splatOpenFieldParams = @{
                        Uri     = "$($config.BaseUrl)/generiek/medewerker/vrij_veld/?q=$($encodedOpenFieldQuery)"
                        Method  = 'GET'
                        Headers = $headers
                    }
                    $targetOpenField = Invoke-RestMethod @splatOpenFieldParams -Verbose:$false # Exception if not found

                    $targetOpenFieldId = $targetOpenField.items.mvrv_id
                    if ($targetOpenFieldId) {
                        Write-Warning "Open field [vrij veld] has not been created automatically with the correct value in the content [inhoud] property, creating new one"
                    }

                    # Create or update open field [vrij veld]
                    $openField = @{
                        medewerker         = $generiekUser.items.medewerker
                        rubriek            = "HRM"
                        volgnummer_rubriek = 1
                        vrij_veld          = "PersID"
                        inhoud             = $p.ExternalId
                        inhoud_verkort     = $p.ExternalId
                        referentietabel    = "mede"
                        referentie_id      = $generiekUser.items.mede_id
                        mvrv_id            = $targetOpenFieldId
                    }

                    $openFieldBody = ($openField | ConvertTo-Json -Depth 10)
                    $splatAddOpenFieldParams = @{
                        Uri     = "$($config.BaseUrl)/generiek/medewerker/vrij_veld/"
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
                    $isPersIdUpdateRequred = $true
                    $auditLogs.Add([PSCustomObject]@{
                            Message = "Setting open field [vrij veld] was not successful. AccountReference is: [$($p.ExternalId)]" 
                            IsError = $false
                        })
                }
                
                $aRef = @{
                    internalId            = $generiekUser.items.mede_id
                    isPersIdUpdateRequred = $isPersIdUpdateRequred
                }
                break
            }

            'Update-Correlate' {
                Write-Verbose 'Updating and correlating Osiris account'

                # p_medewerker must be "#ONVERANDERD#" when updating this value cannot be changed and is added to the body when a update is required
                $account.p_medewerker = "#ONVERANDERD#"
               
                # Second account object for the compare function
                $targetAccount = [PSCustomObject]@{
                    # p_medewerker must be "#ONVERANDERD#" when updating this value cannot be changed and is added to the body when a update is required
                    p_medewerker           = "#ONVERANDERD#"
                    p_achternaam           = $responseUser.achternaam
                    p_voorvoegsels         = $responseUser.voorvoegsels
                    p_voorletters          = $responseUser.voorletters
                    p_roepnaam             = $responseUser.roepnaam
                    p_geslacht             = $responseUser.geslacht
                    p_titel                = $responseUser.titel
                    p_titel_achter         = $responseUser.titel_achter
                    p_indienst             = $responseUser.indienst
                    p_ldap_login           = $responseUser.ldap_login
                    p_extern_onderhouden   = $responseUser.extern_onderhouden
                    p_e_mail_adres         = $responseUser.e_mail_adres
                    p_faculteit            = "#ONVERANDERD#"
                    p_organisatieonderdeel = "#ONVERANDERD#"
                    p_profiel              = "#ONVERANDERD#"
                    p_opleiding            = "#ONVERANDERD#"
                    p_onderdeel_toegang    = "#ONVERANDERD#"
                    p_opleiding_werkzaam   = "#ONVERANDERD#"
                }

                $account.psobject.Properties | ForEach-Object { if ($null -eq $_.value) { $_.value = '' } }
                $targetAccount.psobject.Properties | ForEach-Object { if ($null -eq $_.value) { $_.value = '' } }

                $splatCompareProperties = @{
                    ReferenceObject  = @($targetAccount.PSObject.Properties)
                    DifferenceObject = @($account.PSObject.Properties)
                }
                $propertiesChanged = (Compare-Object @splatCompareProperties -PassThru).Where({ $_.SideIndicator -eq '=>' })
                
                if ($propertiesChanged) {
                    # Update employee
                    $body = $targetAccount
                    
                    if ($propertiesChanged) {
                        foreach ($prop in $propertiesChanged) {
                            $body."$($prop.name)" = $prop.value                       
                        }
                    }
                    # Allways add p_medewerker to the body. This is required to update the medewerker instead of makeing a new one with the value $null
                    $body.p_medewerker = $responseUser.medewerker
                    $body = ($body | ConvertTo-Json -Depth 10)           
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
                }
                
                $aRef = @{
                    internalId            = $responseUser.mede_id
                    isPersIdUpdateRequred = $isPersIdUpdateRequred
                }
                break
            }

            'Correlate' {
                Write-Verbose 'Correlating Osiris account'
                $aRef = @{
                    internalId            = $responseUser.mede_id
                    isPersIdUpdateRequred = $isPersIdUpdateRequred
                }
                break
            }
        }

        $success = $true
        $auditLogs.Add([PSCustomObject]@{
                Message = "$action account was successful. AccountReference is: [$($aRef.internalId)]"
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
        $auditMessage = "Could not create Osiris account. Error: $($errorObj.FriendlyMessage)"
        Write-Verbose "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditMessage = "Could not create Osiris account. Error: $($ex.Exception.Message)"
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
        Success          = $success
        AccountReference = $aRef
        Auditlogs        = $auditLogs
        Account          = $account
    }   

    Write-Output $result | ConvertTo-Json -Depth 10
}