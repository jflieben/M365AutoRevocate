# Durable state in Azure Table storage.
#
# We use Table storage (not a database) because it is cheap, schemaless and --
# crucially -- supports Azure AD authentication, so the tool keeps its "managed
# identity only, no keys" property. The identity is granted the
# "Storage Table Data Contributor" role on the storage account by the deploy
# script.
#
# Tables (see Get-ARTableNames):
#   PendingHardDeletes  - soft-deleted users awaiting permanent deletion
#   DirectorySnapshot   - cached manager/profile/ownership per user
#   ProcessedActions    - dedup + audit trail, partitioned by trigger
#   ActivityLog         - chronological audit feed for the web app
#   FunctionHeartbeats  - per-function last run/status/error
#   SafetyState         - storm-guard counters + paused latch

function Get-ARStorageToken {
    [CmdletBinding()] param()
    $cfg = Get-ARConfig
    return Get-ARManagedIdentityToken -Resource $cfg.StorageResource
}

function ConvertTo-ARODataKey {
    param([Parameter(Mandatory)][string]$Value)
    return $Value.Replace("'", "''")
}

function Invoke-ARTable {
    <#
    .SYNOPSIS
        Low-level Azure Table REST call with managed-identity (AAD) auth.
    .PARAMETER Path
        Path appended to the table endpoint, e.g. "Tables" or
        "PendingHardDeletes(PartitionKey='x',RowKey='y')".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('Get', 'Post', 'Put', 'Merge', 'Delete')][string]$Method = 'Get',
        $Body,
        [hashtable]$ExtraHeaders,
        [switch]$Raw
    )

    $cfg = Get-ARConfig
    $uri = '{0}/{1}' -f $cfg.TableEndpoint, $Path

    $headers = @{
        Authorization    = "Bearer $(Get-ARStorageToken)"
        Accept           = 'application/json;odata=nometadata'
        'x-ms-version'   = '2019-12-12'
        'x-ms-date'      = [DateTime]::UtcNow.ToString('R')
        DataServiceVersion = '3.0;NetFx'
    }
    if ($ExtraHeaders) { $ExtraHeaders.GetEnumerator() | ForEach-Object { $headers[$_.Key] = $_.Value } }

    $params = @{
        Method                  = if ($Method -eq 'Merge') { 'Get' } else { $Method } # placeholder; MERGE handled below
        Uri                     = $uri
        Headers                 = $headers
        ErrorAction             = 'Stop'
        StatusCodeVariable      = 'statusCode'
        SkipHttpErrorCheck      = $true
        ResponseHeadersVariable = 'respHeaders'
    }
    # Invoke-RestMethod supports custom verbs via -CustomMethod; MERGE needs it.
    if ($Method -eq 'Merge') {
        $params.Remove('Method')
        $params.CustomMethod = 'MERGE'
    }
    if ($null -ne $Body) {
        $headers['Content-Type'] = 'application/json'
        $params.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 20 -Compress }
    }

    $response = Invoke-RestMethod @params

    if ($Raw) {
        return [pscustomobject]@{ StatusCode = $statusCode; Body = $response; Headers = $respHeaders }
    }
    if ($statusCode -ge 400 -and $statusCode -ne 404) {
        $detail = if ($response) { ($response | ConvertTo-Json -Depth 8 -Compress) } else { '(no body)' }
        throw "Table $Method $uri failed with HTTP $statusCode`: $detail"
    }
    # Headers are always returned: Table pagination tokens arrive as headers.
    return [pscustomobject]@{ StatusCode = $statusCode; Body = $response; Headers = $respHeaders }
}

$script:ARTablesReady = $false

function Initialize-ARTables {
    <#
    .SYNOPSIS
        Ensures all required tables exist. Safe (and cheap) to call repeatedly --
        the actual REST calls run only once per worker.
    #>
    [CmdletBinding()] param([switch]$Force)
    if ($script:ARTablesReady -and -not $Force) { return }
    $tables = Get-ARTableNames
    foreach ($name in @($tables.Pending, $tables.Directory, $tables.Processed, $tables.Activity, $tables.Heartbeats, $tables.Safety)) {
        $result = Invoke-ARTable -Method Post -Path 'Tables' -Body @{ TableName = $name } -Raw
        if ($result.StatusCode -eq 409) { continue }         # already exists
        if ($result.StatusCode -ge 400) {
            $detail = if ($result.Body) { ($result.Body | ConvertTo-Json -Depth 8 -Compress) } else { '' }
            throw "Failed to create table '$name' (HTTP $($result.StatusCode)): $detail"
        }
        Write-Host "Created table '$name'."
    }
    try { Initialize-ARConfigContainer } catch { Write-Warning "Could not ensure config container: $($_.Exception.Message)" }
    try { New-ARQueue } catch { Write-Warning "Could not ensure the revocations queue: $($_.Exception.Message)" }
    $script:ARTablesReady = $true
}

function Set-ARTableEntity {
    <#
    .SYNOPSIS
        Insert-or-replace an entity. Properties are stored as strings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Table,
        [Parameter(Mandatory)][string]$PartitionKey,
        [Parameter(Mandatory)][string]$RowKey,
        [Parameter(Mandatory)][hashtable]$Properties
    )
    $entity = @{ PartitionKey = $PartitionKey; RowKey = $RowKey }
    foreach ($kvp in $Properties.GetEnumerator()) {
        $entity[$kvp.Key] = if ($null -eq $kvp.Value) { '' } else { [string]$kvp.Value }
    }
    $pk = ConvertTo-ARODataKey $PartitionKey
    $rk = ConvertTo-ARODataKey $RowKey
    $path = "$Table(PartitionKey='$pk',RowKey='$rk')"
    # PUT to the entity address is Insert-Or-Replace (upsert). It must NOT carry
    # an If-Match header -- doing so turns it into a conditional update that
    # fails when the entity does not yet exist.
    $null = Invoke-ARTable -Method Put -Path $path -Body $entity
}

function Merge-ARTableEntity {
    <#
    .SYNOPSIS
        Insert-Or-Merge an entity: listed properties are updated, existing
        properties NOT listed are preserved (unlike Set-ARTableEntity, which
        replaces the whole entity). MERGE without If-Match is the upsert form.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Table,
        [Parameter(Mandatory)][string]$PartitionKey,
        [Parameter(Mandatory)][string]$RowKey,
        [Parameter(Mandatory)][hashtable]$Properties
    )
    $entity = @{ PartitionKey = $PartitionKey; RowKey = $RowKey }
    foreach ($kvp in $Properties.GetEnumerator()) {
        $entity[$kvp.Key] = if ($null -eq $kvp.Value) { '' } else { [string]$kvp.Value }
    }
    $pk = ConvertTo-ARODataKey $PartitionKey
    $rk = ConvertTo-ARODataKey $RowKey
    $path = "$Table(PartitionKey='$pk',RowKey='$rk')"
    $null = Invoke-ARTable -Method Merge -Path $path -Body $entity
}

function Get-ARTableEntity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Table,
        [Parameter(Mandatory)][string]$PartitionKey,
        [Parameter(Mandatory)][string]$RowKey
    )
    $pk = ConvertTo-ARODataKey $PartitionKey
    $rk = ConvertTo-ARODataKey $RowKey
    $path = "$Table(PartitionKey='$pk',RowKey='$rk')"
    $result = Invoke-ARTable -Method Get -Path $path
    if ($result.StatusCode -eq 404) { return $null }
    return $result.Body
}

function Remove-ARTableEntity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Table,
        [Parameter(Mandatory)][string]$PartitionKey,
        [Parameter(Mandatory)][string]$RowKey
    )
    $pk = ConvertTo-ARODataKey $PartitionKey
    $rk = ConvertTo-ARODataKey $RowKey
    $path = "$Table(PartitionKey='$pk',RowKey='$rk')"
    $result = Invoke-ARTable -Method Delete -Path $path -ExtraHeaders @{ 'If-Match' = '*' } -Raw
    if ($result.StatusCode -ge 400 -and $result.StatusCode -ne 404) {
        throw "Failed to delete entity $path (HTTP $($result.StatusCode))."
    }
}

function Invoke-ARTableBatchDelete {
    <#
    .SYNOPSIS
        Deletes many entities that share a PartitionKey in one entity-group
        transaction (100 per batch), instead of one HTTP call each. Falls back
        to per-row deletes for any chunk the batch rejects. Returns the count
        deleted.
    .NOTES
        The Table $batch payload is multipart/mixed and MUST use CRLF line
        endings -- the host runs on Linux, so we build them explicitly rather
        than relying on the platform newline.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Table,
        [Parameter(Mandatory)][string]$PartitionKey,
        [Parameter(Mandatory)][string[]]$RowKeys
    )
    if (-not $RowKeys -or $RowKeys.Count -eq 0) { return 0 }
    $cfg = Get-ARConfig
    $pk = ConvertTo-ARODataKey $PartitionKey
    $CRLF = "`r`n"
    $deleted = 0

    for ($i = 0; $i -lt $RowKeys.Count; $i += 100) {
        $end = [Math]::Min($i + 99, $RowKeys.Count - 1)
        $chunk = @($RowKeys[$i..$end])
        $batchId = 'batch_' + [Guid]::NewGuid().ToString()
        $changesetId = 'changeset_' + [Guid]::NewGuid().ToString()

        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add("--$batchId")
        $lines.Add("Content-Type: multipart/mixed; boundary=$changesetId")
        $lines.Add('')
        foreach ($rk in $chunk) {
            $rke = ConvertTo-ARODataKey $rk
            $url = "$($cfg.TableEndpoint)/$Table(PartitionKey='$pk',RowKey='$rke')"
            $lines.Add("--$changesetId")
            $lines.Add('Content-Type: application/http')
            $lines.Add('Content-Transfer-Encoding: binary')
            $lines.Add('')
            $lines.Add("DELETE $url HTTP/1.1")
            $lines.Add('If-Match: *')
            $lines.Add('Accept: application/json;odata=nometadata')
            $lines.Add('')
        }
        $lines.Add("--$changesetId--")
        $lines.Add("--$batchId--")
        $body = ($lines -join $CRLF) + $CRLF

        $headers = @{
            Authorization  = "Bearer $(Get-ARStorageToken)"
            'x-ms-version' = '2019-12-12'
            'x-ms-date'    = [DateTime]::UtcNow.ToString('R')
            Accept         = 'application/json;odata=nometadata'
        }
        $uri = '{0}/$batch' -f $cfg.TableEndpoint
        try {
            $null = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $body `
                -ContentType "multipart/mixed; boundary=$batchId" -SkipHttpErrorCheck -StatusCodeVariable sc -ErrorAction Stop
        }
        catch { $sc = 500 }
        if ($sc -ge 400) {
            Write-Warning "Table batch delete chunk failed (HTTP $sc); falling back to per-row deletes."
            foreach ($rk in $chunk) { try { Remove-ARTableEntity -Table $Table -PartitionKey $PartitionKey -RowKey $rk; $deleted++ } catch { } }
        }
        else { $deleted += $chunk.Count }
    }
    return $deleted
}

function Get-ARTablePage {
    <#
    .SYNOPSIS
        Returns ONE page of entities plus the continuation token for the next
        page, for callers that paginate (the activity-log API). Note: with a
        $filter, Table storage may return fewer rows than -Top yet still hand
        back a continuation token; an empty page does not mean the end.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Table,
        [string]$Filter,
        [int]$Top = 50,
        [string]$NextPartitionKey,
        [string]$NextRowKey
    )
    $parts = @()
    if ($Filter) { $parts += '$filter={0}' -f [Uri]::EscapeDataString($Filter) }
    if ($Top -gt 0) { $parts += ('$top={0}' -f $Top) }
    if ($NextPartitionKey) { $parts += 'NextPartitionKey={0}' -f [Uri]::EscapeDataString($NextPartitionKey) }
    if ($NextRowKey) { $parts += 'NextRowKey={0}' -f [Uri]::EscapeDataString($NextRowKey) }
    $query = if ($parts) { '?' + ($parts -join '&') } else { '' }

    $result = Invoke-ARTable -Method Get -Path "$Table()$query"
    $items = @()
    if ($result.Body -and ($result.Body.PSObject.Properties.Name -contains 'value')) { $items = @($result.Body.value) }
    $nextPk = $null; $nextRk = $null
    if ($result.Headers) {
        if ($result.Headers['x-ms-continuation-NextPartitionKey']) { $nextPk = $result.Headers['x-ms-continuation-NextPartitionKey'] | Select-Object -First 1 }
        if ($result.Headers['x-ms-continuation-NextRowKey'])       { $nextRk = $result.Headers['x-ms-continuation-NextRowKey']       | Select-Object -First 1 }
    }
    return [pscustomobject]@{ Items = $items; NextPartitionKey = $nextPk; NextRowKey = $nextRk }
}

function Get-ARTableEntities {
    <#
    .SYNOPSIS
        Returns all entities in a table (following continuation tokens), or a
        filtered subset via -Filter (OData $filter expression).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Table,
        [string]$Filter,
        [int]$Top   # 0/unset = all
    )
    $all = [System.Collections.Generic.List[object]]::new()
    $parts = @()
    if ($Filter) { $parts += '$filter={0}' -f [Uri]::EscapeDataString($Filter) }
    if ($Top -gt 0) { $parts += ('$top={0}' -f $Top) }
    $query = if ($parts) { '?' + ($parts -join '&') } else { '' }
    $path = "$Table()$query"

    while ($true) {
        $result = Invoke-ARTable -Method Get -Path $path
        if ($result.StatusCode -eq 404) { break }
        if ($result.Body -and ($result.Body.PSObject.Properties.Name -contains 'value')) {
            foreach ($item in $result.Body.value) { $all.Add($item) }
        }
        if ($Top -gt 0 -and $all.Count -ge $Top) { break }
        # Continuation tokens arrive as response headers; re-query with them.
        $nextPk = $null; $nextRk = $null
        if ($result.Headers) {
            if ($result.Headers['x-ms-continuation-NextPartitionKey']) { $nextPk = $result.Headers['x-ms-continuation-NextPartitionKey'] | Select-Object -First 1 }
            if ($result.Headers['x-ms-continuation-NextRowKey'])       { $nextRk = $result.Headers['x-ms-continuation-NextRowKey']       | Select-Object -First 1 }
        }
        if (-not $nextPk) { break }
        $sep = if ($query) { '&' } else { '?' }
        $cont = 'NextPartitionKey={0}' -f [Uri]::EscapeDataString($nextPk)
        if ($nextRk) { $cont += '&NextRowKey={0}' -f [Uri]::EscapeDataString($nextRk) }
        $path = "$Table()$query$sep$cont"
    }
    return $all
}
