# HelloID-Conn-Prov-Target-Osiris

> [!IMPORTANT]
> This repository contains the connector and configuration code only. The implementer is responsible to acquire the connection details such as username, password, certificate, etc. You might even need to sign a contract or agreement with the supplier before implementing this connector. Please contact the client's application manager to coordinate the connector requirements.
>
> [!IMPORTANT]
> This connector is updated from a v1 to a powershell v2 connector without access to a test environment, therefore the code is not tested and should be treated as such.

<p align="center">
  <img src="assets/logo.png">
</p>

## Table of contents

- [HelloID-Conn-Prov-Target-Osiris](#helloid-conn-prov-target-osiris)
  - [Table of contents](#table-of-contents)
  - [Introduction](#introduction)
  - [Supported  features](#supported--features)
  - [Getting started](#getting-started)
    - [Prerequisites](#prerequisites)
    - [Connection settings](#connection-settings)
    - [Correlation configuration](#correlation-configuration)
    - [Field mapping](#field-mapping)
    - [Account Reference](#account-reference)
  - [Remarks](#remarks)
    - [Additionel open fields](#additionel-open-fields)
    - [`GET` employee returns a different object](#get-employee-returns-a-different-object)
    - [URL Encondig](#url-encondig)
  - [Development resources](#development-resources)
    - [API endpoints](#api-endpoints)
    - [API documentation](#api-documentation)
  - [Getting help](#getting-help)
  - [HelloID docs](#helloid-docs)

## Introduction

_HelloID-Conn-Prov-Target-Osiris_ is a _target_ connector. _Osiris_ provides a set of REST API's that allow you to programmatically interact with its data.

## Supported  features

The following features are available:

| Feature                                   | Supported | Actions                         | Remarks |
| ----------------------------------------- | --------- | ------------------------------- | ------- |
| **Account Lifecycle**                     | ✅         | Create, Update, Enable, Disable |         |
| **Permissions**                           | ❌         | -                               |         |
| **Resources**                             | ❌         | -                               |         |
| **Entitlement Import: Accounts**          | ✅         |                                 |         |
| **Entitlement Import: Permissions**       | ❌         | -                               |         |
| **Governance Reconciliation Resolutions** | ❌         | -                               |         |

## Getting started

### Prerequisites

- An open field [vrij veld] is necessary for the correlation process. The 'content' [inhoud] and 'shortened content' [inhoud verkort] need to be populated with the ExternalID.

- The open field [vrij veld] need to have category [rubriek] of value "HRM" and need to be of type "PersId", this is because these value's are used in the filtering used when getting the open field [vrij veld]

### Connection settings

The following settings are required to connect to the API.

| Setting  | Description                        | Mandatory |
| -------- | ---------------------------------- | --------- |
| UserName | The UserName to connect to the API | Yes       |
| Password | The Password to connect to the API | Yes       |
| BaseUrl  | The URL to the API                 | Yes       |

### Correlation configuration

The correlation configuration is used to specify which properties will be used to match an existing account within _Osiris_ to a person in _HelloID_.

| Setting                   | Value                             |
| ------------------------- | --------------------------------- |
| Enable correlation        | `True`                            |
| Person correlation field  | `PersonContext.Person.ExternalId` |
| Account correlation field | `PersID`                          |

> [!TIP]
> The basic account does not contain the required data for correlation. Therefore the correlation uses the open field `vrij veld` "PersID". If you want to use a differen open field, change the name of this field in both the field mapping and correlation configuration.
Currently the connector only supports  correlation on open fields, not on basic account fields.

> _For more general information on correlation, please refer to our correlation [documentation](https://docs.helloid.com/en/provisioning/target-systems/powershell-v2-target-systems/correlation.html) pages_.

### Field mapping

The field mapping can be imported by using the _fieldMapping.json_ file.
Note that the field p_medewerker is only used by the create, as it cannot be updated because it is used as an identifier by the update call of Osirus. Therefore it is by default mapped as "none" If added in for the update action, It will be ignored in the update call even if you specify a value in the mapping.

### Account Reference

The account reference is populated with the property `mede_Id` property from _Osiris_

## Remarks

### Additionel open fields
There is an additional open field `[vrij veld]` object where the externalId is stored; this field is used for the correlation process.

When creating an employee, the open field `[vrij veld]` can be generated automatically. This option can only be set within Caci Osiris itself. We assume that it is checked, but because there are instances where the 'content' `[inhoud]` is not populated correctly, in which case we attempt to update its contents. If, for any reason, the update of the open field `[vrij veld]` results in an error, we let the create succeed normally, and only log a warning. In the update script we check that it is correctly set and make another attempt to update it if required.
If this action fails in the update script, it is considered an normal update error.   

When retrieving the open field `[vrij veld]`, there is no option available to filter based on the content `[inhoud]` itself, but it is possible to filter based on the shortened content `[inhoud verkort]`. As a result, it's crucial to ensure that both of these properties are always filled with the same values.

### `GET` employee returns a different object
- The `GET` employee API request to the generic [generiek] endpoint, returns an object that differs from what the `PUT` request expects in its body. The fields names used in Helloid are the names that are used in the `PUT` request' The script automatically converts syntax  from the `GET` to the syntax required for the `PUT`.

### URL Encondig
- The queries used in the filtering of the API request must be encoded using URL encoding.

## Development resources

### API endpoints

The following endpoints are used by the connector

| Endpoint                                   | Description                                          |
| ------------------------------------------ | ---------------------------------------------------- |
| /generiek/medewerker/vrij_veld/?q={$query} | Gets the open field [vrij veld] (GET)                |
| /generiek/medewerker/vrij_veld/            | Creates or updates the open field [vrij veld] (POST) |
| /generiek/medewerker/?q={$query}           | Gets the employee (GET)                              |
| /basis/medewerker                          | Creates or updates the employee (PUT)                |

### API documentation

Not available publicly.

## Getting help

> [!TIP]
> _For more information on how to configure a HelloID PowerShell connector, please refer to our [documentation](https://docs.helloid.com/en/provisioning/target-systems/powershell-v2-target-systems.html) pages_.

> [!TIP]
>  _If you need help, feel free to ask questions on our [forum] https://forum.helloid.com/forum/helloid-connectors/provisioning/4943-helloid-conn-prov-target-osiris_.

## HelloID docs

The official HelloID documentation can be found at: https://docs.helloid.com/
