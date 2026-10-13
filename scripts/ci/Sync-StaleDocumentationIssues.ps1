#!/usr/bin/env pwsh
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

#Requires -Version 7.0

<#
.SYNOPSIS
    Creates or updates one GitHub issue for each stale documentation file.
.DESCRIPTION
    Reads the JSON report produced by Invoke-MsDateFreshnessCheck.ps1. For each
    stale file, updates the open issue carrying the file's automation marker or
    creates a new issue. The report is validated before any issue is changed.
    Every GitHub CLI call is checked, and the first failure stops processing.
.PARAMETER ResultsFile
    Path to the ms.date freshness JSON report.
.PARAMETER Repository
    Repository in owner/name format.
.PARAMETER ThresholdDays
    Staleness threshold, in days, used to produce the report.
.PARAMETER WorkflowRunUrl
    URL of the workflow run that detected the stale files.
.EXAMPLE
    ./scripts/ci/Sync-StaleDocumentationIssues.ps1 -ResultsFile logs/msdate-freshness-results.json -Repository owner/repo -ThresholdDays 90 -WorkflowRunUrl https://github.com/owner/repo/actions/runs/1
.NOTES
    Requires GH_TOKEN with issues: write permission.
#>
[CmdletBinding()]
param(
    [string]$ResultsFile = '',
    [string]$Repository = '',
    [string]$ThresholdDays = '',
    [string]$WorkflowRunUrl = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Functions

function Test-StaleDocumentationInteger {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]
        [object]$Value
    )

    return ($Value -is [int] -or $Value -is [long])
}

function Read-StaleDocumentationReport {
    <#
    .SYNOPSIS
        Reads and validates the freshness report before any issue is changed.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [string]$ResultsFile,
        [int]$ThresholdDays
    )

    if (-not (Test-Path -LiteralPath $ResultsFile -PathType Leaf)) {
        throw "Freshness results file not found: $ResultsFile"
    }

    $raw = Get-Content -LiteralPath $ResultsFile -Raw -ErrorAction Stop
    if ($null -eq $raw -or -not $raw.Trim().StartsWith('[')) {
        throw "Freshness results in $ResultsFile must be a JSON array."
    }

    try {
        $rows = @(ConvertFrom-Json -InputObject $raw -ErrorAction Stop)
    }
    catch {
        throw "Freshness results in $ResultsFile are not valid JSON: $($_.Exception.Message)"
    }

    $seenFiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    for ($index = 0; $index -lt $rows.Count; $index++) {
        $row = $rows[$index]
        $location = "Freshness result $index"

        if ($row -isnot [System.Management.Automation.PSCustomObject]) {
            throw "$location must be an object."
        }

        foreach ($name in @('File', 'MsDate', 'AgeDays', 'IsStale', 'Threshold')) {
            if ($null -eq $row.PSObject.Properties[$name]) {
                throw "$location is missing '$name'."
            }
        }

        if ($row.File -isnot [string] -or [string]::IsNullOrWhiteSpace($row.File)) {
            throw "$location has an invalid File value."
        }

        $location = "Freshness result for '$($row.File)'"
        if (-not $seenFiles.Add($row.File)) {
            throw "$location is duplicated."
        }

        $parsedDate = [datetime]::MinValue
        if ($row.MsDate -isnot [string] -or $row.MsDate -notmatch '^\d{4}-\d{2}-\d{2}$' -or
            -not [datetime]::TryParseExact($row.MsDate, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsedDate)) {
            throw "$location has an invalid MsDate value."
        }

        if (-not (Test-StaleDocumentationInteger -Value $row.AgeDays)) {
            throw "$location has an invalid AgeDays value."
        }

        if ($row.IsStale -isnot [bool]) {
            throw "$location has an invalid IsStale value."
        }

        if (-not (Test-StaleDocumentationInteger -Value $row.Threshold) -or $row.Threshold -ne $ThresholdDays) {
            throw "$location has Threshold '$($row.Threshold)'; expected $ThresholdDays."
        }
    }

    return , $rows
}

function Invoke-StaleDocumentationGh {
    <#
    .SYNOPSIS
        Runs one GitHub CLI operation and throws when it exits unsuccessfully.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [string]$Operation,
        [string]$FilePath,
        [string]$Repository,
        [string[]]$Arguments
    )

    $output = & gh @Arguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "GitHub issue $Operation failed for '$FilePath' in $Repository (exit code $exitCode)."
    }

    return ((@($output) | ForEach-Object { "$_" }) -join "`n").Trim()
}

function New-StaleDocumentationIssueBody {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [object]$Row,
        [int]$ThresholdDays,
        [string]$WorkflowRunUrl,
        [datetime]$Now
    )

    return (@(
            '## Stale Documentation Detected'
            ''
            "**File:** ``$($Row.File)``"
            "**Current ms.date:** ``$($Row.MsDate)``"
            "**Age:** $($Row.AgeDays) days (threshold: $ThresholdDays days)"
            ''
            '---'
            "**Workflow Run:** $WorkflowRunUrl"
            "**Detection Date:** $($Now.ToString('yyyy-MM-dd'))"
            ''
            '### Action Required'
            '- [ ] Review and update this documentation file'
            '- [ ] Update `ms.date` frontmatter to current date'
            '- [ ] Verify technical accuracy of content'
            '- [ ] Close this issue manually after fixes are merged'
            ''
            "<!-- automation:stale-docs:$($Row.File) -->"
        ) -join "`n")
}

function Sync-StaleDocumentationIssuesCore {
    <#
    .SYNOPSIS
        Creates or updates stale documentation issues from a freshness report.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [string]$ResultsFile,
        [string]$Repository,
        [int]$ThresholdDays,
        [string]$WorkflowRunUrl,
        [datetime]$Now = [datetime]::UtcNow
    )

    if ([string]::IsNullOrWhiteSpace($ResultsFile)) {
        throw 'ResultsFile is required.'
    }
    if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
        throw 'Repository must use owner/name format.'
    }
    if ($ThresholdDays -le 0) {
        throw 'ThresholdDays must be a positive integer.'
    }
    $runUri = $null
    if (-not [uri]::TryCreate($WorkflowRunUrl, [UriKind]::Absolute, [ref]$runUri) -or $runUri.Scheme -notin @('http', 'https')) {
        throw 'WorkflowRunUrl must be an absolute HTTP(S) URL.'
    }

    # Exit codes are checked explicitly after each call.
    $PSNativeCommandUseErrorActionPreference = $false

    $rows = Read-StaleDocumentationReport -ResultsFile $ResultsFile -ThresholdDays $ThresholdDays
    $staleRows = @($rows | Where-Object { $_.IsStale })
    if ($staleRows.Count -eq 0) {
        Write-Host 'No stale files found, skipping issue creation'
        return 0
    }

    $updateMarker = [char]::ConvertFromUtf32(0x1F504)
    foreach ($row in $staleRows) {
        $filePath = $row.File
        Write-Host "Processing: $filePath (age: $($row.AgeDays) days)"

        $searchQuery = "repo:$Repository is:issue is:open in:body `"automation:stale-docs:$filePath`""
        $lookup = Invoke-StaleDocumentationGh -Operation 'lookup' -FilePath $filePath -Repository $Repository -Arguments @(
            'issue', 'list', '--repo', $Repository, '--search', $searchQuery, '--limit', '1', '--json', 'number', '--jq', '.[0].number // empty'
        )
        if ($lookup -and $lookup -notmatch '^[1-9]\d*$') {
            throw "GitHub issue lookup returned an invalid issue number for '$filePath' in ${Repository}: $lookup"
        }

        $issueBody = New-StaleDocumentationIssueBody -Row $row -ThresholdDays $ThresholdDays -WorkflowRunUrl $WorkflowRunUrl -Now $Now
        if ($lookup) {
            Write-Host "Updating existing issue #$lookup for $filePath"
            $null = Invoke-StaleDocumentationGh -Operation 'edit' -FilePath $filePath -Repository $Repository -Arguments @(
                'issue', 'edit', $lookup, '--repo', $Repository, '--body', $issueBody
            )

            $comment = "$updateMarker **Weekly validation update:** Still stale ($($row.AgeDays) days) as of $($Now.ToString('yyyy-MM-dd'))"
            $null = Invoke-StaleDocumentationGh -Operation 'comment' -FilePath $filePath -Repository $Repository -Arguments @(
                'issue', 'comment', $lookup, '--repo', $Repository, '--body', $comment
            )
        }
        else {
            Write-Host "Creating new issue for $filePath"
            $created = Invoke-StaleDocumentationGh -Operation 'create' -FilePath $filePath -Repository $Repository -Arguments @(
                'issue', 'create', '--repo', $Repository, '--title', "docs: Update stale documentation - $filePath",
                '--body', $issueBody, '--label', 'documentation,stale-docs,automated,needs-triage'
            )
            if ($created) {
                Write-Host $created
            }
        }
    }

    Write-Host 'Issue creation/update complete'
    return 0
}

#endregion Functions

#region Main Execution

if ($MyInvocation.InvocationName -ne '.') {
    try {
        $threshold = 0
        if (-not [int]::TryParse($ThresholdDays, [ref]$threshold)) {
            throw 'ThresholdDays must be a positive integer.'
        }

        exit (Sync-StaleDocumentationIssuesCore -ResultsFile $ResultsFile -Repository $Repository -ThresholdDays $threshold -WorkflowRunUrl $WorkflowRunUrl)
    }
    catch {
        $message = "Stale documentation issue sync failed: $($_.Exception.Message)"
        if ($env:GITHUB_ACTIONS -eq 'true') {
            Write-Output "::error::$($message -replace '%', '%25' -replace "`r", '%0D' -replace "`n", '%0A')"
        }
        Write-Error -ErrorAction Continue $message
        exit 1
    }
}

#endregion Main Execution
