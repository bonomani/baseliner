# PhaseCore.psm1
# Provides execution control for phase-based operations using context-driven logging and retry logic

function Invoke-Phase {
    param(
        [string]        $PhaseName,
        [scriptblock]   $Block,
        [string]        $StepName,
        #[scriptblock]   $Logger,       # Must be a wrapped logger (from Wrap-Logger)
        [object]        $Logger,
        [hashtable]     $Context,
        [scriptblock]   $OnSuccess,
        [scriptblock]   $OnFailure
    )

    $Verbose     = $Context.Verbose
    $Debug       = $Context.Debug
    $WhatIf      = $Context.WhatIf
    $Force       = $Context.Force
    $Confirm     = $Context.Confirm
    $ErrorAction = $Context.ErrorAction
    $Retries     = $Context.RetryCount
    $Delay       = $Context.DelaySeconds

    function Invoke-PhaseFailure {
        param([string]$Msg, [string]$DefaultLevel)

        $effective = switch ($ErrorAction) {
            'SilentlyContinue' { 'Ignore' }
            'Continue'         { 'Warn' }
            default            { $DefaultLevel }
        }

        switch ($effective) {
            'Ignore' {}
            #'Warn'   { & $Logger $Msg 'WARN' }
            #'Strict' {
            #    & $Logger $Msg 'ERROR'
            #    throw $Msg
            #}
            'Warn' {
                $Logger.WrapLog($Msg, "WARN", $Context)
            }
            'Strict' {
                $Logger.WrapLog($Msg, "ERROR", $Context)
                throw $Msg
            }
        }
    }

    $result = [pscustomobject]@{
        Phase     = $PhaseName
        StepName  = if ($StepName) { $StepName } else { $PhaseName }
        Success   = $false
        Skipped   = $false
        Message   = ''
        Attempt   = 0
        MaxRetry  = $Retries
        Caller    = (Get-PSCallStack)[1].FunctionName
        Hint      = $null
        Detail    = $null
    }

    #& $Logger "($($result.StepName)) phase start" 'DEBUG'
    function Normalize-StepLabel {
        param([string]$Label)
        $clean = $Label
        if ($clean -like 'Precondition *') { return $clean -replace '^Precondition\s+', '' }
        if ($clean -like 'Confirmation *') { return $clean -replace '^Confirmation\s+', '' }
        return $clean
    }

    function Format-PhasePrompt {
        param([string]$Phase, [string]$Label)
        $action = Normalize-StepLabel -Label $Label
        switch ($Phase) {
            'PreVerify' { return "PreVerify: Check $action" }
            'Check'     { return "Check: Validate prerequisites for $action" }
            'Run'       { return "Run: Execute $action" }
            'Verify'    { return "Verify: Confirm $action" }
            'Fixup'     { return "Fixup: Apply $action" }
            default     { return "${Phase}: $action" }
        }
    }

    $debugEnabled = ($Debug -eq $true) -or ($Verbose -eq $true)
    if ($debugEnabled) {
        $Logger.WrapLog(
            (Format-PhasePrompt -Phase $PhaseName -Label $result.StepName) + " (start)",
            "DEBUG",
            $Context
        )
        if ($Force) {
            $Logger.WrapLog(
                "${PhaseName}: $($result.StepName) | Force=true",
                "DEBUG",
                $Context
            )
        }
    }


    if ($WhatIf) {
        $result.Skipped = $true
        $result.Success = $true
        $result.Message = 'WhatIf active (simulation only)'
        #& $Logger $result.Message 'INFO'
        $Logger.WrapLog(
            $result.Message,
            "INFO",
            $Context
        )

        return $result
    }

    if ($Confirm) {
        $message = "[$PhaseName] Confirm to proceed: $($result.StepName)?"
        $shouldContinue = $false
        try {
            $shouldContinue = $PSCmdlet.ShouldContinue($message, "Confirm action")
        } catch {
            #& $Logger "$message [non-interactive mode: skipping]" 'WARN'
            $Logger.WrapLog(
                "$message [non-interactive mode: skipping]",
                "WARN",
                $Context
            )
        }

        if (-not $shouldContinue) {
            $result.Skipped = $true
            $result.Message = 'Skipped by user confirmation'
            #& $Logger $result.Message 'INFO'
            $Logger.WrapLog(
                $result.Message,
                "INFO",
                $Context
            )
            return $result
        }
    }

    function ConvertTo-PhaseReturn {
        param([object]$Raw)

        if ($Raw -is [bool]) {
            return @{
                Success = $Raw
                Hint    = $null
                Detail  = $null
            }
        }

        if ($Raw -is [hashtable]) {
            $success = $Raw['Success']
            return @{
                Success = if ($success -is [bool]) { $success } else { [bool]$success }
                Hint    = if ($Raw.ContainsKey('Hint')) { $Raw['Hint'] } else { $null }
                Detail  = if ($Raw.ContainsKey('Detail')) { $Raw['Detail'] } else { $null }
            }
        }

        $successProp = $Raw.PSObject.Properties["Success"]
        if ($successProp -and $successProp.Value -is [bool]) {
            $hintProp = $Raw.PSObject.Properties["Hint"]
            $detailProp = $Raw.PSObject.Properties["Detail"]
            return @{
                Success = [bool]$successProp.Value
                Hint    = if ($hintProp) { $hintProp.Value } else { $null }
                Detail  = if ($detailProp) { $detailProp.Value } else { $null }
            }
        }

        return @{
            Success = [bool]$Raw
            Hint    = $null
            Detail  = $null
        }
    }

    function Format-PhaseOutcome {
        param([string]$Outcome, [int]$Attempt, [string]$Hint, [string]$Detail)
        $line = (Format-PhasePrompt -Phase $PhaseName -Label $result.StepName) + " ($Outcome) | attempt=$Attempt"
        if ($Hint) { $line += " | Hint=$Hint" }
        if ($Detail) { $line += " | Detail=$Detail" }
        return $line
    }

    $execute = {
        for ($i = 1; $i -le $Retries; $i++) {
            $result.Attempt = $i
            try {
                $phaseReturn = ConvertTo-PhaseReturn -Raw (& $Block)
                $result.Hint = $phaseReturn.Hint
                $result.Detail = $phaseReturn.Detail
                if ($phaseReturn.Success) {
                    $result.Success = $true
                    $result.Message = 'OK'
                    if ($debugEnabled -and $i -gt 1) {
                        $Logger.WrapLog((Format-PhaseOutcome -Outcome "success" -Attempt $i -Hint $result.Hint -Detail $result.Detail), "DEBUG", $Context)
                    }
                    if ($OnSuccess) { & $OnSuccess }
                    break
                } else {
                    if ($debugEnabled) {
                        $Logger.WrapLog((Format-PhaseOutcome -Outcome "failure" -Attempt $i -Hint $result.Hint -Detail $result.Detail), "DEBUG", $Context)
                    }
                    if ($PhaseName -in @('PreVerify','Verify')) {
                        # PreVerify/Verify failures are expected control flow, not warnings.
                    } elseif (-not $result.Hint -and -not $result.Detail) {
                        $result.Message = "Logical failure without a specific Hint or Detail"
                        Invoke-PhaseFailure $result.Message 'Strict'
                    }
                    if ($OnFailure) { & $OnFailure }
                }
            } catch {
                $result.Message = "Exception: $($_.Exception.Message)"
                $result.Hint = "exception"
                $result.Detail = $result.Message
                if ($debugEnabled) {
                    $Logger.WrapLog((Format-PhaseOutcome -Outcome "exception" -Attempt $i -Hint $result.Hint -Detail $result.Detail), "DEBUG", $Context)
                }
                Invoke-PhaseFailure $result.Message 'Strict'
                if ($OnFailure) { & $OnFailure }
            }

            if ($i -lt $Retries -and $Delay -gt 0) {
                #& $Logger "Retrying in $Delay seconds..." 'DEBUG'
                if ($debugEnabled) {
                    $Logger.WrapLog(
                        "Retrying in $Delay seconds...",
                        "DEBUG",
                        $Context
                    )
                }
                Start-Sleep -Seconds $Delay
            }
        }
    }

    & $execute
    return $result
}

Export-ModuleMember -Function Invoke-Phase
