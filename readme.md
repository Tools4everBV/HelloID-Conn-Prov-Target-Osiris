# HelloID-Conn-Prov-Target-Osiris

| :information_source: Information |
|:---------------------------|
| This repository contains the connector and configuration code only. The implementer is responsible to acquire the connection details such as username, password, certificate, etc. You might even need to sign a contract or agreement with the supplier before implementing this connector. Please contact the client's application manager to coordinate the connector requirements. |

<p align="center">
  <img src="assets/logo.png">
</p>

## Table of contents

- [Introduction](#Introduction)
- [Getting started](#Getting-started)
  - [Connection settings](#Connection-settings)
  - [Prerequisites](#Prerequisites)
  - [Remarks](#Remarks)
- [Setup the connector](@Setup-The-Connector)
- [Getting help](#Getting-help)
- [HelloID Docs](#HelloID-docs)

## Introduction

_HelloID-Conn-Prov-Target-Osiris_ is a _target_ connector. The Osiris connector facilitates the creation, updating, enabling, and disabling of employee accounts in Osiris.

| Endpoint                                   | Description                                          |
| ------------------------------------------ | ---------------------------------------------------- |
| /generiek/medewerker/vrij_veld/?q={$query} | Gets the open field [vrij veld] (GET)                |
| /generiek/medewerker/vrij_veld/            | Creates or updates the open field [vrij veld] (POST) |
| /generiek/medewerker/?q={$query}           | Gets the employee (GET)                              |
| /basis/medewerker                          | Creates or updates the employee (PUT)                |

The following lifecycle events are available:

| Event       | Description                                 | Notes |
| ----------- | ------------------------------------------- | ----- |
| create.ps1  | Create (or update) and correlate an Account | -     |
| update.ps1  | Update the Account                          | -     |
| enable.ps1  | Enable the Account                          | -     |
| disable.ps1 | Disable the Account                         | -     |
| delete.ps1  | No delete script available / Supported      | -     |

## Getting started

### Connection settings

The following settings are required to connect to the API.

| Setting | Description                       | Mandatory |
| ------- | --------------------------------- | --------- |
| ApiKey  | The API key to connect to the API | Yes       |
| BaseUrl | The URL to the API                | Yes       |

### Prerequisites
- An open field [vrij veld] is necessary for the correlation process. The 'content' [inhoud] and 'shortened content' [inhoud verkort] need to be populated with the ExternalID.
- The open field [vrij veld] need to have category [rubriek] of value "HRM" and need to be of type "PersId", this is because these value's are used in the filtering used when getting the open field [vrij veld]

### Remarks
- There is an additional open field [vrij veld] object where the externalId is stored; this is utilized in the correlation process.
- When creating an employee, the open field [vrij veld] can be generated automatically; this option is available as a checkbox in the UI of the target system. We assume that it is checked, but because there are instances where the 'content' [inhoud] is not populated correctly, we attempt to update it if this occurs. If, for any reason, the update of the open field [vrij veld] results in an error, we set the boolean variable ($isPersIdUpdateRequired) to true. This action does not lead to a failed create process but instead generates a warning. Subsequently, we make another attempt to update it within the update script.
- When retrieving the open field [vrij veld], there is no option available to filter based on the content [inhoud] itself, but it is possible to filter based on the shortened content [inhoud verkort]. As a result, it's crucial to ensure that both of these properties are always filled with the same values.
- The 'GET employee' request from the generic [generiek] endpoint yields an object that differs from what the PUT request expects in its body. Therefore, the presence of an additional account object ($targetAccount) becomes necessary. In case there are extra fields introduced to the account object, these fields must also be included in the additional account object ($targetAccount). 
- The queries used in the filtering of the API request must undergo URL encoding, otherwise it results in an error.

#### Creation / correlation process

A new functionality is the possibility to update the account in the target system during the correlation process. By default, this behavior is disabled. Meaning, the account will only be created or correlated.

You can change this behavior by adjusting the updatePersonOnCorrelate within the configuration

> Be aware that this might have unexpected implications.

## Setup the connector

> _How to setup the connector in HelloID._ Are special settings required. Like the _primary manager_ settings for a source connector.

## Getting help

> _For more information on how to configure a HelloID PowerShell connector, please refer to our [documentation](https://docs.helloid.com/hc/en-us/articles/360012558020-Configure-a-custom-PowerShell-target-system) pages_

> _If you need help, feel free to ask questions on our [forum]([https://forum.helloid.com](https://forum.helloid.com/forum/helloid-connectors/provisioning/4943-helloid-conn-prov-target-osiris)https://forum.helloid.com/forum/helloid-connectors/provisioning/4943-helloid-conn-prov-target-osiris)_

## HelloID docs

The official HelloID documentation can be found at: https://docs.helloid.com/
