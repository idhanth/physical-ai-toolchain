#Requires -Version 7.0
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '../../ci/Sync-StaleDocumentationIssues.ps1'
    . $script:ScriptPath

    function gh { throw 'Unmocked gh call.' }

    $script:Repository = 'owner/repo'
    $script:RunUrl = 'https://github.com/owner/repo/actions/runs/123'
    $script:Now = [datetime]::new(2026, 10, 12, 9, 38, 0, [DateTimeKind]::Utc)
    $script:Complete = 'Issue creation/update complete'

    function New-FreshnessRow {
        param(
            [string]$File,
            [bool]$IsStale = $true,
            [long]$AgeDays = 91
        )

        [ordered]@{ File = $File; MsDate = '2026-07-13'; AgeDays = $AgeDays; IsStale = $IsStale; Threshold = 90 }
    }

    function New-ResultsFile {
        param(
            [object[]]$Rows = @(),
            [string]$Raw
        )

        $path = Join-Path $TestDrive "results-$([guid]::NewGuid()).json"
        $content = if ($PSBoundParameters.ContainsKey('Raw')) { $Raw } else { ConvertTo-Json -InputObject @($Rows) -Depth 5 }
        Set-Content -LiteralPath $path -Value $content -NoNewline -Encoding utf8NoBOM
        return $path
    }

    function Invoke-Sync {
        param([string]$ResultsFile)

        Sync-StaleDocumentationIssuesCore -ResultsFile $ResultsFile -Repository $script:Repository -ThresholdDays 90 -WorkflowRunUrl $script:RunUrl -Now $script:Now
    }

    function Get-ArgumentValue {
        param(
            [object[]]$Arguments,
            [string]$Name
        )

        $index = [array]::IndexOf($Arguments, $Name)
        if ($index -lt 0) { return $null }
        return $Arguments[$index + 1]
    }
}

Describe 'Sync-StaleDocumentationIssuesCore' -Tag 'Unit' {
    BeforeEach {
        $script:GhCalls = [System.Collections.Generic.List[object]]::new()
        $script:Messages = [System.Collections.Generic.List[string]]::new()
        $script:ExistingIssues = @{}
        $script:LookupOutput = @{}
        $script:FailOperation = $null
        $script:FailFile = $null

        Mock Write-Host { $script:Messages.Add([string]$Object) }
        Mock gh {
            $arguments = @($args)
            $operation = "$($arguments[0]) $($arguments[1])"
            $file = switch ($operation) {
                'issue list' { ([regex]::Match((Get-ArgumentValue -Arguments $arguments -Name '--search'), 'automation:stale-docs:([^"]+)')).Groups[1].Value }
                'issue create' { ([regex]::Match((Get-ArgumentValue -Arguments $arguments -Name '--body'), 'automation:stale-docs:(.+?) -->')).Groups[1].Value }
                'issue edit' { ([regex]::Match((Get-ArgumentValue -Arguments $arguments -Name '--body'), 'automation:stale-docs:(.+?) -->')).Groups[1].Value }
                'issue comment' { ($script:ExistingIssues.GetEnumerator() | Where-Object { $_.Value -eq $arguments[2] } | Select-Object -First 1).Key }
                default { throw "Unexpected gh call: $($arguments -join ' ')" }
            }
            $script:GhCalls.Add([PSCustomObject]@{ Operation = $operation; File = $file; Arguments = $arguments })

            if ($operation -eq $script:FailOperation -and (-not $script:FailFile -or $file -eq $script:FailFile)) {
                $global:LASTEXITCODE = 1
                return
            }

            $global:LASTEXITCODE = 0
            switch ($operation) {
                'issue list' {
                    if ($script:LookupOutput.ContainsKey($file)) { return $script:LookupOutput[$file] }
                    return $script:ExistingIssues[$file]
                }
                'issue create' { return "https://github.com/owner/repo/issues/$($script:GhCalls.Count)" }
            }
        }
    }

    Context 'Valid reports without stale files' {
        It 'Performs no issue operations for <Name>' -ForEach @(
            @{ Name = 'an empty report'; Rows = @() }
            @{ Name = 'an all-fresh report'; Rows = @([ordered]@{ File = 'docs/fresh.md'; MsDate = '2026-10-09'; AgeDays = 3; IsStale = $false; Threshold = 90 }) }
        ) {
            Invoke-Sync -ResultsFile (New-ResultsFile -Rows $Rows) | Should -Be 0

            $script:GhCalls | Should -HaveCount 0
            $script:Messages | Should -Contain 'No stale files found, skipping issue creation'
            $script:Messages | Should -Not -Contain $script:Complete
        }
    }

    Context 'Successful notifications' {
        It 'Creates an actionable issue for a new stale file' {
            $expectedBody = @(
                '## Stale Documentation Detected'
                ''
                '**File:** `docs/stale.md`'
                '**Current ms.date:** `2026-07-13`'
                '**Age:** 91 days (threshold: 90 days)'
                ''
                '---'
                '**Workflow Run:** https://github.com/owner/repo/actions/runs/123'
                '**Detection Date:** 2026-10-12'
                ''
                '### Action Required'
                '- [ ] Review and update this documentation file'
                '- [ ] Update `ms.date` frontmatter to current date'
                '- [ ] Verify technical accuracy of content'
                '- [ ] Close this issue manually after fixes are merged'
                ''
                '<!-- automation:stale-docs:docs/stale.md -->'
            ) -join "`n"

            Invoke-Sync -ResultsFile (New-ResultsFile -Rows @((New-FreshnessRow -File 'docs/stale.md'))) | Should -Be 0

            ($script:GhCalls.Operation -join ' > ') | Should -Be 'issue list > issue create'
            $lookup = $script:GhCalls[0].Arguments
            Get-ArgumentValue -Arguments $lookup -Name '--repo' | Should -BeExactly 'owner/repo'
            Get-ArgumentValue -Arguments $lookup -Name '--search' | Should -BeExactly 'repo:owner/repo is:issue is:open in:body "automation:stale-docs:docs/stale.md"'
            Get-ArgumentValue -Arguments $lookup -Name '--jq' | Should -BeExactly '.[0].number // empty'

            $create = $script:GhCalls[1].Arguments
            Get-ArgumentValue -Arguments $create -Name '--title' | Should -BeExactly 'docs: Update stale documentation - docs/stale.md'
            Get-ArgumentValue -Arguments $create -Name '--body' | Should -BeExactly $expectedBody
            Get-ArgumentValue -Arguments $create -Name '--label' | Should -BeExactly 'documentation,stale-docs,automated,needs-triage'
            $script:Messages | Should -Contain $script:Complete
        }

        It 'Updates and comments on an existing open issue instead of creating another' {
            $script:ExistingIssues['docs/stale.md'] = '17'

            Invoke-Sync -ResultsFile (New-ResultsFile -Rows @((New-FreshnessRow -File 'docs/stale.md'))) | Should -Be 0

            ($script:GhCalls.Operation -join ' > ') | Should -Be 'issue list > issue edit > issue comment'
            $script:GhCalls[1].Arguments[2] | Should -BeExactly '17'
            Get-ArgumentValue -Arguments $script:GhCalls[1].Arguments -Name '--body' | Should -Match '<!-- automation:stale-docs:docs/stale\.md -->$'
            $comment = Get-ArgumentValue -Arguments $script:GhCalls[2].Arguments -Name '--body'
            $comment | Should -BeExactly "$([char]::ConvertFromUtf32(0x1F504)) **Weekly validation update:** Still stale (91 days) as of 2026-10-12"
            $script:Messages | Should -Contain $script:Complete
        }

        It 'Processes each stale file independently and skips fresh files' {
            $script:ExistingIssues['docs/existing.md'] = '8'
            $rows = @(
                (New-FreshnessRow -File 'docs/new.md')
                (New-FreshnessRow -File 'docs/fresh.md' -IsStale $false -AgeDays 10)
                (New-FreshnessRow -File 'docs/existing.md' -AgeDays 120)
            )

            Invoke-Sync -ResultsFile (New-ResultsFile -Rows $rows) | Should -Be 0

            ($script:GhCalls | ForEach-Object { "$($_.Operation):$($_.File)" }) -join ' > ' | Should -Be (@(
                'issue list:docs/new.md'
                'issue create:docs/new.md'
                'issue list:docs/existing.md'
                'issue edit:docs/existing.md'
                'issue comment:docs/existing.md'
            ) -join ' > ')
            $script:Messages | Should -Contain $script:Complete
        }
    }

    Context 'Invalid reports' {
        It 'Rejects <Name> before any issue operation' -ForEach @(
            @{ Name = 'a missing file'; Raw = $null; Pattern = 'not found' }
            @{ Name = 'invalid JSON'; Raw = '[{'; Pattern = 'not valid JSON' }
            @{ Name = 'a null payload'; Raw = 'null'; Pattern = 'must be a JSON array' }
            @{ Name = 'an object payload'; Raw = '{"File":"docs/a.md"}'; Pattern = 'must be a JSON array' }
            @{ Name = 'a scalar row'; Raw = '[1]'; Pattern = 'must be an object' }
            @{ Name = 'a missing field'; Raw = '[{"File":"docs/a.md","MsDate":"2026-07-13","AgeDays":91,"IsStale":true}]'; Pattern = "missing 'Threshold'" }
            @{ Name = 'a malformed date'; Raw = '[{"File":"docs/a.md","MsDate":"2026-13-40","AgeDays":91,"IsStale":true,"Threshold":90}]'; Pattern = 'invalid MsDate' }
            @{ Name = 'a string IsStale value'; Raw = '[{"File":"docs/a.md","MsDate":"2026-07-13","AgeDays":91,"IsStale":"true","Threshold":90}]'; Pattern = 'invalid IsStale' }
            @{ Name = 'a mismatched threshold'; Raw = '[{"File":"docs/a.md","MsDate":"2026-07-13","AgeDays":91,"IsStale":true,"Threshold":30}]'; Pattern = 'expected 90' }
            @{ Name = 'a duplicated file'; Raw = '[{"File":"docs/a.md","MsDate":"2026-07-13","AgeDays":91,"IsStale":true,"Threshold":90},{"File":"docs/a.md","MsDate":"2026-07-13","AgeDays":91,"IsStale":true,"Threshold":90}]'; Pattern = 'duplicated' }
        ) {
            $path = if ($null -eq $Raw) { Join-Path $TestDrive 'missing.json' } else { New-ResultsFile -Raw $Raw }

            { Invoke-Sync -ResultsFile $path } | Should -Throw -ExpectedMessage "*$Pattern*"
            $script:GhCalls | Should -HaveCount 0
            $script:Messages | Should -Not -Contain $script:Complete
        }

        It 'Rejects malformed successful lookup output without creating an issue' {
            $script:LookupOutput['docs/stale.md'] = 'not-a-number'

            { Invoke-Sync -ResultsFile (New-ResultsFile -Rows @((New-FreshnessRow -File 'docs/stale.md'))) } |
                Should -Throw -ExpectedMessage "*invalid issue number for 'docs/stale.md' in owner/repo*"
            ($script:GhCalls.Operation -join ' > ') | Should -Be 'issue list'
            $script:Messages | Should -Not -Contain $script:Complete
        }
    }

    Context 'GitHub CLI failures' {
        It 'Stops when <Operation> fails' -ForEach @(
            @{ Operation = 'lookup'; FailOperation = 'issue list'; Existing = $null; Expected = @('issue list') }
            @{ Operation = 'create'; FailOperation = 'issue create'; Existing = $null; Expected = @('issue list', 'issue create') }
            @{ Operation = 'edit'; FailOperation = 'issue edit'; Existing = '17'; Expected = @('issue list', 'issue edit') }
            @{ Operation = 'comment'; FailOperation = 'issue comment'; Existing = '17'; Expected = @('issue list', 'issue edit', 'issue comment') }
        ) {
            $script:FailOperation = $FailOperation
            if ($Existing) { $script:ExistingIssues['docs/stale.md'] = $Existing }

            { Invoke-Sync -ResultsFile (New-ResultsFile -Rows @((New-FreshnessRow -File 'docs/stale.md'))) } |
                Should -Throw -ExpectedMessage "GitHub issue $Operation failed for 'docs/stale.md' in owner/repo (exit code 1)."
            ($script:GhCalls.Operation -join ' > ') | Should -Be ($Expected -join ' > ')
            $script:Messages | Should -Not -Contain $script:Complete
        }

        It 'Does not let later successful operations mask an earlier failure' {
            $script:FailOperation = 'issue create'
            $script:FailFile = 'docs/first.md'
            $rows = @((New-FreshnessRow -File 'docs/first.md'), (New-FreshnessRow -File 'docs/second.md'))

            { Invoke-Sync -ResultsFile (New-ResultsFile -Rows $rows) } |
                Should -Throw -ExpectedMessage "GitHub issue create failed for 'docs/first.md'*"
            $script:GhCalls.File | Should -Not -Contain 'docs/second.md'
            $script:Messages | Should -Not -Contain $script:Complete
        }
    }
}

Describe 'Sync-StaleDocumentationIssues.ps1 entry point' -Tag 'Unit' {
    BeforeAll {
        $script:Pwsh = (Get-Process -Id $PID).Path
    }

    It 'Returns <ExitCode> for <Name>' -ForEach @(
        @{ Name = 'a valid report with no stale files'; Raw = '[]'; ExitCode = 0; Pattern = 'No stale files found' }
        @{ Name = 'an invalid report'; Raw = 'null'; ExitCode = 1; Pattern = 'Stale documentation issue sync failed: Freshness results * must be a JSON array' }
    ) {
        $path = New-ResultsFile -Raw $Raw
        $output = & $script:Pwsh -NoProfile -NonInteractive -File $script:ScriptPath -ResultsFile $path -Repository 'owner/repo' -ThresholdDays '90' -WorkflowRunUrl 'https://github.com/owner/repo/actions/runs/123' 2>&1
        $exitCode = $LASTEXITCODE

        $exitCode | Should -Be $ExitCode
        (@($output | ForEach-Object { "$_" }) -join "`n") | Should -BeLike "*$Pattern*"
    }
}
