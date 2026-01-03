function New-Logger {
    param (
        [string]$LogFilePath,
        [bool]$Console = $false,
        [string]$MinLevel = "NOTICE",
        [int]$MaxSizeMB = 5,
        [int]$MaxArchives = 5
    )

    $LoggerLevels = @("DEBUG", "INFO", "NOTICE", "WARN", "ERROR")
    $LogColorMap = @{
        "DEBUG"  = "DarkGray"
        "INFO"   = "White"
        "NOTICE" = "Cyan"
        "WARN"   = "Yellow"
        "ERROR"  = "Red"
    }

    if (-not $LoggerLevels -contains $MinLevel) {
        throw "Invalid MinLevel. Valid values: $LoggerLevels"
    }

    $LogDir = Split-Path $LogFilePath -Parent
    if (-not (Test-Path $LogDir)) {
        New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
    }

    $logger = New-Object PSObject -Property @{
        Path        = $LogFilePath
        Console     = $Console
        MinLevel    = $MinLevel
        MaxBytes    = [long]$MaxSizeMB * 1024 * 1024
        MaxArchives = $MaxArchives
        Levels      = $LoggerLevels
        Colors      = $LogColorMap
    }

    # .Log("Message", "Level")
    $logger | Add-Member -MemberType ScriptMethod -Name Log -Value {
        param (
            [string]$Message,
            [string]$Level = "INFO"
        )

        $minIndex = $this.Levels.IndexOf($this.MinLevel)
        $msgIndex = $this.Levels.IndexOf($Level)
        if ($msgIndex -lt $minIndex) { return }

        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $line = "$timestamp [$Level] $Message"

        $rotate = (Test-Path $this.Path) -and ((Get-Item $this.Path).Length -gt $this.MaxBytes)
        if ($rotate) {
            $ts = Get-Date -Format 'yyyyMMddHHmmss'
            $archive = "$($this.Path).$ts.log"
            Rename-Item -Path $this.Path -NewName $archive -Force

            $dir = Split-Path $this.Path -Parent
            $base = Split-Path $this.Path -Leaf
            $pattern = "$base.*.log"
            $archives = Get-ChildItem -Path $dir -Filter $pattern | Sort-Object LastWriteTime -Descending
            if ($archives.Count -gt $this.MaxArchives) {
                $archives | Select-Object -Skip $this.MaxArchives | Remove-Item -Force
            }
        }

        if (-not (Test-Path $this.Path)) {
            New-Item -Path $this.Path -ItemType File -Force | Out-Null
        }

        Add-Content -Path $this.Path -Value $line

        if ($this.Console) {
            $color = $this.Colors[$Level]
            Write-Host $line -ForegroundColor $color
        }
    }

    # .WrapLog("Message", "Level", $Context)
    $logger | Add-Member -MemberType ScriptMethod -Name WrapLog -Value {
        param (
            [string]$Message,
            [string]$Level = "INFO",
            [hashtable]$Context
        )

        if ($Context.WhatIf) { $Message = "[SIMULATION] $Message" }
        if ($Context.Phase)  { $Message = "[$($Context.Phase)] $Message" }

        $this.Log($Message, $Level)
    }

    # .WriteTargetNotice("Type", "Id", $Result, $Context, "completed")
    $logger | Add-Member -MemberType ScriptMethod -Name WriteTargetNotice -Value {
        param (
            [string]$TargetType,
            [string]$TargetId,
            [hashtable]$Result,
            [hashtable]$Context = @{},
            [string]$State = "completed"
        )

        $this.WrapLog(
            "$TargetType $TargetId $State | Reason=$($Result.Reason) | " +
            "observed=$($Result.Observed) applied=$($Result.Applied) changed=$($Result.Changed) " +
            "failed=$($Result.Failed) skipped=$($Result.Skipped)",
            "NOTICE",
            $Context
        )
    }

    return $logger
}

Export-ModuleMember -Function New-Logger
