Import-Module "$PSScriptRoot\PhaseCore.psm1" -Force -ErrorAction Stop

function Merge-ContextDefaults {
    param (
        [hashtable]$Context,
        [hashtable]$Defaults
    )
    if (-not $Context) { $Context = @{} }
    foreach ($key in $Defaults.Keys) {
        if (-not $Context.ContainsKey($key)) {
            $Context[$key] = $Defaults[$key]
        }
    }
    return $Context
}

function Invoke-CheckPhase {
    param(
        [Parameter(Mandatory)][string]       $Step,
        [Parameter()][hashtable]             $Context = @{},
        [Parameter(Mandatory)][scriptblock]  $Block,
        [Parameter(Mandatory)][object]       $Logger
    )

    $ctx = @{} + $Context
    $defaults = @{
        PhaseName    = 'Check'
        WhatIf       = $false
        Confirm      = $false
        Force        = $false
        RetryCount   = 1
        DelaySeconds = 0
        ErrorAction  = 'Continue'
        Verbose      = $true
        Debug        = $false
    }
    $ctx = Merge-ContextDefaults -Context $ctx -Defaults $defaults

    Invoke-Phase -PhaseName 'Check' `
                 -StepName ("Precondition $Step") `
                 -Block $Block -Logger $Logger -Context $ctx
}

function Invoke-RunPhase {
    param(
        [Parameter(Mandatory)][string]       $Step,
        [Parameter()][hashtable]             $Context = @{},
        [Parameter(Mandatory)][scriptblock]  $Block,
        [Parameter(Mandatory)][object]       $Logger
    )

    $ctx = @{} + $Context
    $defaults = @{
        PhaseName    = 'Run'
        WhatIf       = $false
        Confirm      = $false
        Force        = $true
        RetryCount   = 3
        DelaySeconds = 2
        ErrorAction  = 'Stop'
        Verbose      = $true
        Debug        = $false
    }
    $ctx = Merge-ContextDefaults -Context $ctx -Defaults $defaults

    Invoke-Phase -PhaseName 'Run' `
                 -StepName $Step `
                 -Block $Block -Logger $Logger -Context $ctx
}

function Invoke-VerifyPhase {
    param(
        [Parameter(Mandatory)][string]       $Step,
        [Parameter()][hashtable]             $Context = @{},
        [Parameter(Mandatory)][scriptblock]  $Block,
        [Parameter(Mandatory)][object]       $Logger
    )

    $ctx = @{} + $Context
    $defaults = @{
        PhaseName    = 'Verify'
        WhatIf       = $false
        Confirm      = $false
        Force        = $false
        RetryCount   = 1
        DelaySeconds = 0
        ErrorAction  = 'SilentlyContinue'
        Verbose      = $true
        Debug        = $false
    }
    $ctx = Merge-ContextDefaults -Context $ctx -Defaults $defaults

    Invoke-Phase -PhaseName 'Verify' `
                 -StepName ("Confirmation $Step") `
                 -Block $Block -Logger $Logger -Context $ctx
}

function Invoke-PreVerifyPhase {
    param(
        [Parameter(Mandatory)][string]       $Step,
        [Parameter()][hashtable]             $Context = @{},
        [Parameter(Mandatory)][scriptblock]  $Block,
        [Parameter(Mandatory)][object]       $Logger
    )

    $ctx = @{} + $Context
    $defaults = @{
        PhaseName    = 'PreVerify'
        WhatIf       = $false
        Confirm      = $false
        Force        = $false
        RetryCount   = 1
        DelaySeconds = 0
        ErrorAction  = 'SilentlyContinue'
        Verbose      = $true
        Debug        = $false
    }
    $ctx = Merge-ContextDefaults -Context $ctx -Defaults $defaults

    Invoke-Phase -PhaseName 'PreVerify' `
                 -StepName $Step `
                 -Block $Block -Logger $Logger -Context $ctx
}

function Invoke-FixupPhase {
    param(
        [Parameter(Mandatory)][string]       $Step,
        [Parameter()][hashtable]             $Context = @{},
        [Parameter(Mandatory)][scriptblock]  $Block,
        [Parameter(Mandatory)][object]       $Logger
    )

    $ctx = @{} + $Context
    $defaults = @{
        PhaseName    = 'Fixup'
        WhatIf       = $false
        Confirm      = $false
        Force        = $true
        RetryCount   = 3
        DelaySeconds = 2
        ErrorAction  = 'Stop'
        Verbose      = $true
        Debug        = $false
    }
    $ctx = Merge-ContextDefaults -Context $ctx -Defaults $defaults

    Invoke-Phase -PhaseName 'Fixup' `
                 -StepName $Step `
                 -Block $Block -Logger $Logger -Context $ctx
}

function Invoke-CheckRunVerifyPhase {
    param(
        [Parameter(Mandatory)][string]       $Step,
        [hashtable]                          $CheckContext   = @{},
        [scriptblock]                        $CheckBlock     = $null,
        [Parameter(Mandatory)][scriptblock]  $ExecuteBlock,
        [hashtable]                          $ExecuteContext = @{},
        [scriptblock]                        $VerifyBlock    = $null,
        [hashtable]                          $VerifyContext  = @{},
        [Parameter(Mandatory)][object]       $Logger
    )

    if ($VerifyBlock) {
        $preVerifyResult = Invoke-VerifyPhase `
            -Step    $Step `
            -Block   $VerifyBlock `
            -Logger  $Logger `
            -Context $VerifyContext

        if ($preVerifyResult.Success -eq $true) {
            return $true
        }
    }

    if ($CheckBlock) {
        $checkResult = Invoke-CheckPhase `
            -Step    $Step `
            -Block   $CheckBlock `
            -Logger  $Logger `
            -Context $CheckContext

        if ($checkResult.Success -ne $true) {
            return $false
        }
    }

    $runResult = Invoke-RunPhase `
        -Step    $Step `
        -Block   $ExecuteBlock `
        -Logger  $Logger `
        -Context $ExecuteContext

    if ($runResult.Success -ne $true) {
        return $false
    }

    if ($VerifyBlock) {
        $postVerifyResult = Invoke-VerifyPhase `
            -Step    $Step `
            -Block   $VerifyBlock `
            -Logger  $Logger `
            -Context $VerifyContext

        if ($postVerifyResult.Success -ne $true) {
            return $false
        }
    }

    return $true
}

function Invoke-CheckDoReportPhase {
    param(
        [Parameter(Mandatory)][string]       $Action,
        [hashtable]                          $PreVerifyContext = @{},
        [scriptblock]                        $PreVerifyBlock   = $null,
        [hashtable]                          $CheckContext     = @{},
        [scriptblock]                        $CheckBlock       = $null,
        [hashtable]                          $FixupContext     = @{},
        [scriptblock]                        $FixupBlock       = $null,
        [Parameter(Mandatory)][hashtable]    $DoContext,
        [Parameter(Mandatory)][scriptblock]  $DoBlock,
        [hashtable]                          $VerifyContext    = @{},
        [scriptblock]                        $VerifyBlock      = $null,
        [Parameter(Mandatory)][object]       $Logger,
        [switch]                             $LogFixupChanges,
        [string]                             $FixupName = "fixup"
    )

    <#
    Phase result shape (returned by PreVerify/Check/Fixup/Run/Verify blocks):
      @{ Success = [bool]; Hint = "<optional>"; Detail = "<optional>" }
    - Success is required and must be a boolean.
    - Hint is a short, strict token (e.g., missing.source, policy.denied).
    - Detail is free text for diagnostics.
    #>

    $result = @{
        Observed = 0
        Applied   = 0
        Changed   = 0
        Failed    = 0
        Skipped   = 0
        Reason    = ""
    }

    $extraHints = @()

    function Set-OutcomeCounters {
        param(
            [hashtable] $Target,
            [string] $Phase,
            [string] $Outcome,
            [string] $Reason
        )

        $Target.Observed = 1

        switch ("$Phase.$Outcome") {
            "preverify.ok" { }
            "check.fail" { $Target.Skipped = 1 }
            "fixup.fail" { $Target.Applied = 1; $Target.Failed = 1 }
            "run.fail" { $Target.Applied = 1; $Target.Failed = 1 }
            "verify.fail" { $Target.Applied = 1; $Target.Failed = 1 }
            "verify.ok" { $Target.Applied = 1; $Target.Changed = 1 }
            "run.ok" { $Target.Applied = 1; $Target.Changed = 1 }
            default { }
        }

        if ($Target.Changed -eq 1) {
            $Target.Applied = 1
            $Target.Observed = 1
        }

        if ($Target.Failed -eq 1) {
            $Target.Applied = 1
            $Target.Observed = 1
        }

        if ($Target.Skipped -eq 1) {
            $Target.Applied = 0
        }
    }

    function Get-PhaseResult {
        param (
            [string] $Phase,
            [object] $PhaseResult,
            [hashtable] $PhaseContext = @{}
        )

        if ($PhaseResult -is [bool]) {
            return @{ Success = $PhaseResult }
        }

        if ($PhaseResult -is [hashtable]) {
            if ($PhaseResult.ContainsKey('Success') -and $PhaseResult.Success -is [bool]) {
                return $PhaseResult
            }

            $Logger.WrapLog(
                "Phase '$Phase' returned invalid result (missing/invalid Success).",
                "ERROR",
                $PhaseContext
            )

            return @{
                Success = $false
                Hint   = "invalid_phase_result"
                Detail = "phase=$Phase | missing_or_invalid_success"
            }
        }

        $successProp = $PhaseResult.PSObject.Properties["Success"]
        if ($successProp -and $successProp.Value -is [bool]) {
            $normalized = @{
                Success = [bool]$successProp.Value
            }

            $hintProp = $PhaseResult.PSObject.Properties["Hint"]
            if ($hintProp) { $normalized.Hint = $hintProp.Value }

            $detailProp = $PhaseResult.PSObject.Properties["Detail"]
            if ($detailProp) { $normalized.Detail = $detailProp.Value }

            return $normalized
        }

        $Logger.WrapLog(
            "Phase '$Phase' returned invalid result type '$($PhaseResult.GetType().Name)'.",
            "ERROR",
            $PhaseContext
        )

        return @{
            Success = $false
            Hint   = "invalid_phase_result"
            Detail = "phase=$Phase | invalid_type"
        }
    }

    function New-Reason {
        param([string]$Phase, [string]$Status, $Detail)
        $reasonText = "$Phase.$Status"
        if ($Detail) { return "$reasonText | $Detail" }
        return $reasonText
    }

    function New-PhaseReason {
        param(
            [string] $Phase,
            [string] $Status,
            [hashtable] $PhaseResult,
            [string[]] $ExtraHints
        )

        $detailParts = @()
        if ($ExtraHints) { $detailParts += $ExtraHints }
        if ($PhaseResult.Hint) { $detailParts += $PhaseResult.Hint }
        if ($PhaseResult.Detail) { $detailParts += $PhaseResult.Detail }
        $detail = if ($detailParts.Count -gt 0) { $detailParts -join " | " } else { $null }
        return New-Reason -Phase $Phase -Status $Status -Detail $detail
    }

    function Set-PhaseResult {
        param(
            [hashtable] $Target,
            [string] $Phase,
            [string] $Outcome,
            [hashtable] $PhaseResult,
            [string[]] $Hints
        )

        Set-OutcomeCounters -Target $Target -Phase $Phase -Outcome $Outcome -Reason $PhaseResult.Hint
        $Target.Reason = New-PhaseReason -Phase $Phase -Status $Outcome -PhaseResult $PhaseResult -ExtraHints $Hints
        return $Target
    }

    if ($PreVerifyBlock) {
        $pre = Invoke-PreVerifyPhase -Step $Action -Block $PreVerifyBlock -Logger $Logger -Context $PreVerifyContext
        $preResult = Get-PhaseResult -Phase $Action -PhaseResult $pre -PhaseContext $PreVerifyContext
        if ($preResult.Success -eq $true) {
            return Set-PhaseResult -Target $result -Phase "preverify" -Outcome "ok" -PhaseResult $preResult -Hints @()
        }
    }

    if ($CheckBlock) {
        $check = Invoke-CheckPhase -Step $Action -Block $CheckBlock -Logger $Logger -Context $CheckContext
        $checkResult = Get-PhaseResult -Phase $Action -PhaseResult $check -PhaseContext $CheckContext
        if ($checkResult.Success -ne $true) {
            if ($FixupBlock) {
                $fixupRun = Invoke-FixupPhase -Step $Action -Block $FixupBlock -Logger $Logger -Context $FixupContext
                $fixupResult = Get-PhaseResult -Phase $Action -PhaseResult $fixupRun -PhaseContext $FixupContext
                if ($fixupResult.Success -ne $true) {
                    return Set-PhaseResult -Target $result -Phase "fixup" -Outcome "fail" -PhaseResult $fixupResult -Hints @()
                }
                $extraHints = @("fixup.ok")
                if ($LogFixupChanges) {
                    $Logger.WrapLog(
                        "Fixup applied: '$FixupName' for '$Action' | Reason=fixup.applied | observed=1 applied=1 changed=1 failed=0 skipped=0",
                        "NOTICE",
                        $FixupContext
                    )
                }
                $check = Invoke-CheckPhase -Step $Action -Block $CheckBlock -Logger $Logger -Context $CheckContext
                $checkResult = Get-PhaseResult -Phase $Action -PhaseResult $check -PhaseContext $CheckContext
                if ($checkResult.Success -ne $true) {
                    return Set-PhaseResult -Target $result -Phase "check" -Outcome "fail" -PhaseResult $checkResult -Hints @()
                }
            } else {
                return Set-PhaseResult -Target $result -Phase "check" -Outcome "fail" -PhaseResult $checkResult -Hints @()
            }
        }
    }

    $run = Invoke-RunPhase -Step $Action -Block $DoBlock -Logger $Logger -Context $DoContext
    $runResult = Get-PhaseResult -Phase $Action -PhaseResult $run -PhaseContext $DoContext
    if ($runResult.Success -ne $true) {
        return Set-PhaseResult -Target $result -Phase "run" -Outcome "fail" -PhaseResult $runResult -Hints $extraHints
    }

    if ($VerifyBlock) {
        $verify = Invoke-VerifyPhase -Step $Action -Block $VerifyBlock -Logger $Logger -Context $VerifyContext
        $verifyResult = Get-PhaseResult -Phase $Action -PhaseResult $verify -PhaseContext $VerifyContext
        if ($verifyResult.Success -ne $true) {
            return Set-PhaseResult -Target $result -Phase "verify" -Outcome "fail" -PhaseResult $verifyResult -Hints $extraHints
        }
        return Set-PhaseResult -Target $result -Phase "verify" -Outcome "ok" -PhaseResult $verifyResult -Hints $extraHints
    }

    return Set-PhaseResult -Target $result -Phase "run" -Outcome "ok" -PhaseResult $runResult -Hints $extraHints
}



Export-ModuleMember -Function `
    Merge-ContextDefaults, `
    Invoke-CheckPhase, `
    Invoke-RunPhase, `
    Invoke-PreVerifyPhase, `
    Invoke-FixupPhase, `
    Invoke-VerifyPhase, `
    Invoke-CheckRunVerifyPhase, `
    Invoke-CheckDoReportPhase
