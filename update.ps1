########################################
# HelloID-Conn-Prov-Target-Osiris-Update
#
# Version: 1.0.0
########################################
# Initialize default values
$config = $configuration | ConvertFrom-Json
$p = $person | ConvertFrom-Json
$aRef = $AccountReference | ConvertFrom-Json
$success = $false
$auditLogs = [System.Collections.Generic.List[PSCustomObject]]::new()

switch ($p.Details.gender) {
    { ($_ -eq "man") -or ($_ -eq "male") } {
        $gender = "M"
    }
    { ($_ -eq "vrouw") -or ($_ -eq "female") } {
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
    p_roepnaam             = $p.Name.GivenName
    p_geslacht             = $gender
    p_titel                = ""
    p_titel_achter         = ""
    p_indienst             = "" # P_indienst is determined automatically later in script
    p_ldap_login           = $p.Name.FamilyName
    p_extern_onderhouden   = "J"
    p_e_mail_adres         = $p.Contact.Business.Email
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
            #displaying the old message if an error occurs during an API call, as the error is related to the API call and not the conversion process to JSON.
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
        }
        catch {
            throw "Could not encode query, error: $($_.Exception.Message)"
        }
        Write-Output $UrlEncodedString
    }
}
#endregion

# Begin
try {
    Write-Verbose "Verifying if a Osiris account for [$($p.DisplayName)] exists"
    $account.p_medewerker = $account.p_medewerker.ToUpper()

    $headers = @{
        'Api-Key'      = $config.ApiKey
        'Content-Type' = 'application/json'
        Accept         = 'application/json'
    }

    if ($null -eq $aRef.internalId) {
        throw "Account reference is empty, cannot update Osiris account"
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
        $action = 'NotFound'
        $dryRunMessage = "Osiris account for: [$($p.DisplayName)] not found. Possibly deleted"
    } else {
        # Gets value from employee account in target system
        $account.p_indienst = $currentAccount.indienst

        # Verify if the account must be updated
        # Always compare the account against the current account in target system
        
        #second account object for the compare function
        $targetAccount = [PSCustomObject]@{
            p_medewerker           = $currentAccount.medewerker
            p_achternaam           = $currentAccount.achternaam
            p_voorvoegsels         = $currentAccount.voorvoegsels
            p_voorletters          = $currentAccount.voorletters
            p_roepnaam             = $currentAccount.roepnaam
            p_geslacht             = $currentAccount.geslacht
            p_titel                = $currentAccount.titel
            p_titel_achter         = $currentAccount.titel_achter
            p_indienst             = $currentAccount.indienst
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

        #set all null value's to empty string for both objects
        $account.psobject.Properties | ForEach-Object { if ($null -eq $_.value) { $_.value = '' } }
        $targetAccount.psobject.Properties | ForEach-Object { if ($null -eq $_.value) { $_.value = '' } }
        
        $splatCompareProperties = @{
            ReferenceObject  = @($targetAccount.PSObject.Properties)
            DifferenceObject = @($account.PSObject.Properties)
        }
        $propertiesChanged = (Compare-Object @splatCompareProperties -PassThru).Where({ $_.SideIndicator -eq '=>' })
        
        $ispMedewerkerChanged = $propertiesChanged | Where-Object { $_.Name -eq "p_medewerker" }

        if ($ispMedewerkerChanged.count -gt 0) {
            throw "Username has changed, the user can not be updated"
        }

        if (($propertiesChanged.count -gt 0) -and ($null -ne $currentAccount)) {
            $action = 'Update'
            $dryRunMessage = "Account property(s) required to update: [$($propertiesChanged.name -join ",")]"
        }
        elseif (-not($propertiesChanged)) {
            $action = 'NoChanges'
            $dryRunMessage = 'No changes will be made to the account during enforcement'
        }
    }

    # Add an auditMessage showing what will happen during enforcement
    if ($dryRun -eq $true) {
        Write-Warning "[DryRun] $dryRunMessage"
    }

    # Process
    if (-not($dryRun -eq $true)) {
        switch ($action) {
            'Update' {
                Write-Verbose "Updating Osiris account with accountReference: [$($aRef.internalId)]"
                # Update employee

                $body = $targetAccount
                if ($propertiesChanged) {
                    foreach ($prop in $propertiesChanged) {
                        $body."$($prop.name)" = $prop.value                       
                    }
                }

                $body = ($body | ConvertTo-Json -Depth 10)           
                $splatAddUserParams = @{
                    Uri         = "$($config.BaseUrl)/basis/medewerker"
                    Method      = 'PUT'
                    Body        = ([System.Text.Encoding]::UTF8.GetBytes($body))
                    Headers     = $headers
                    ContentType = "application/json;charset=utf-8"
                }
                $null = Invoke-RestMethod @splatAddUserParams -Verbose:$false # Exception if not found

                $auditLogs.Add([PSCustomObject]@{
                    Message = 'Update employee [medewerker] was successful'
                    IsError = $false
                })

                if ($aRef.isPersIdUpdateRequred -eq $true) {

                    # Update open field [vrij veld]
                    $encodedOpenFieldQuery = Resolve-UrlEncoding -InputString "{`"vrij_veld`":`"PersID`",`"rubriek`":`"HRM`",`"referentie_id`":`"$($aRef.internalId)`"}"
                    $splatOpenFieldParams = @{
                        Uri     = "$($config.BaseUrl)/generiek/medewerker/vrij_veld/?q=$($encodedOpenFieldQuery)"
                        Method  = 'GET'
                        Headers = $headers
                    }
                    $splatOpenField = Invoke-RestMethod @splatOpenFieldParams -Verbose:$false # Exception if not found

                    if ([string]::IsNullOrEmpty($splatOpenField.items.inhoud)) {
                        $openField = @{
                            medewerker         = $splatOpenField.items.medewerker
                            rubriek            = "HRM"
                            volgnummer_rubriek = 1
                            vrij_veld          = "PersID"
                            inhoud             = $p.ExternalId
                            inhoud_verkort     = $p.ExternalId
                            referentietabel    = "mede"
                            referentie_id      = $splatOpenField.items.referentie_id
                            mvrv_id            = $splatOpenField.items.mvrv_id
                        }
                        $bodyOpenField = ($openField | ConvertTo-Json -Depth 10)
                        $splatAddOpenFieldParams = @{
                            Uri     = "$($config.BaseUrl)/generiek/medewerker/vrij_veld/"
                            Method  = 'POST'
                            Body    = ([System.Text.Encoding]::UTF8.GetBytes($bodyOpenField))
                            Headers = $headers
                            ContentType = "application/json;charset=utf-8"
                        }
                        $null = Invoke-RestMethod @splatAddOpenFieldParams -Verbose:$false # Exception if not found

                        $auditLogs.Add([PSCustomObject]@{
                            Message = 'Update open field [vrij veld] was successful'
                            IsError = $false
                        })
                    }
                }

                $success = $true
                $auditLogs.Add([PSCustomObject]@{
                        Message = 'Update account was successful'
                        IsError = $false
                    })
                break
            }

            'NoChanges' {
                Write-Verbose "No changes to Osiris account with accountReference: [$($aRef.internalId)]"

                $success = $true
                $auditLogs.Add([PSCustomObject]@{
                        Message = 'No changes will be made to the account during enforcement'
                        IsError = $false
                    })
                break
            }

            'NotFound' {
                $success = $false
                $auditLogs.Add([PSCustomObject]@{
                        Message = "Osiris account for: [$($p.DisplayName)] not found. Possibly deleted"
                        IsError = $true
                    })
                break
            }
        }
    }
}
catch {
    $success = $false
    $ex = $PSItem
    if ($($ex.Exception.GetType().FullName -eq 'Microsoft.PowerShell.Commands.HttpResponseException') -or
        $($ex.Exception.GetType().FullName -eq 'System.Net.WebException')) {
        $errorObj = Resolve-OsirisError -ErrorObject $ex
        $auditMessage = "Could not update Osiris account. Error: $($errorObj.FriendlyMessage)"
        Write-Verbose "Error at Line '$($errorObj.ScriptLineNumber)': $($errorObj.Line). Error: $($errorObj.ErrorDetails)"
    }
    else {
        $auditMessage = "Could not update Osiris account. Error: $($ex.Exception.Message)"
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
        Account   = $account
        Auditlogs = $auditLogs
    }
    Write-Output $result | ConvertTo-Json -Depth 10
}
