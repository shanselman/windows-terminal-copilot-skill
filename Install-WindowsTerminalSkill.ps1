<#
.SYNOPSIS
    Installs the Windows Terminal Skill for GitHub Copilot CLI.

.DESCRIPTION
    Installs all required skill files as a unit, then adds the module import to
    the PowerShell profile if needed. Existing installations are preserved if
    downloading, validation, or replacement fails.

.PARAMETER Force
    Overwrites an existing local installation without prompting.

.PARAMETER Remote
    Downloads the skill files from DownloadBaseUrl instead of copying them from
    the directory containing this script.

.EXAMPLE
    .\Install-WindowsTerminalSkill.ps1

.EXAMPLE
    .\Install-WindowsTerminalSkill.ps1 -Force

.EXAMPLE
    .\Install-WindowsTerminalSkill.ps1 -Remote
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$Remote,
    [string]$SourcePath = $PSScriptRoot,
    [string]$DestinationPath = (Join-Path $env:USERPROFILE '.copilot\skills\windows-terminal'),
    [string]$ProfilePath = $PROFILE,
    [string]$DownloadBaseUrl = 'https://raw.githubusercontent.com/shanselman/windows-terminal-copilot-skill/refs/heads/master'
)

$ErrorActionPreference = 'Stop'

$filesToInstall = @(
    'WindowsTerminalSkill.psm1',
    'WindowsTerminalSkill.psd1',
    'SKILL.md',
    'README.md'
)
$moduleManifest = 'WindowsTerminalSkill.psd1'
$isRemoteInstall = $Remote -or [string]::IsNullOrWhiteSpace($SourcePath)

function Get-NormalizedPath {
    param([Parameter(Mandatory)][string]$Path)

    [System.IO.Path]::GetFullPath($Path).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
}

function Get-TextEncoding {
    param([Parameter(Mandatory)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 4) {
        if ($bytes[0] -eq 0x00 -and $bytes[1] -eq 0x00 -and $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF) {
            return [System.Text.UTF32Encoding]::new($true, $true)
        }
        if ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and $bytes[2] -eq 0x00 -and $bytes[3] -eq 0x00) {
            return [System.Text.UTF32Encoding]::new($false, $true)
        }
    }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [System.Text.UTF8Encoding]::new($true)
    }
    if ($bytes.Length -ge 2) {
        if ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
            return [System.Text.UnicodeEncoding]::new($true, $true)
        }
        if ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
            return [System.Text.UnicodeEncoding]::new($false, $true)
        }
    }

    [System.Text.UTF8Encoding]::new($false)
}

Write-Host 'Windows Terminal Skill Installer' -ForegroundColor Cyan
Write-Host '=================================' -ForegroundColor Cyan
Write-Host ''

Write-Host 'Checking PowerShell version...' -ForegroundColor Yellow
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Warning "PowerShell 7+ is recommended. You are running PowerShell $($PSVersionTable.PSVersion)."
    Write-Warning 'The skill may not work correctly in older versions.'
}
else {
    Write-Host "  PowerShell $($PSVersionTable.PSVersion) detected." -ForegroundColor Green
}

$normalizedDestination = Get-NormalizedPath -Path $DestinationPath
if (-not $isRemoteInstall) {
    if ([string]::IsNullOrWhiteSpace($SourcePath)) {
        throw 'A local installation requires SourcePath.'
    }

    $normalizedSource = Get-NormalizedPath -Path $SourcePath
    if ($normalizedSource -eq $normalizedDestination) {
        throw "SourcePath and DestinationPath resolve to the same directory: '$normalizedDestination'."
    }
}

Write-Host 'Installing skill files...' -ForegroundColor Yellow
if ($isRemoteInstall) {
    Write-Host "  Downloading from $DownloadBaseUrl" -ForegroundColor Yellow
}

$installFiles = $true
if ((Test-Path -LiteralPath $DestinationPath) -and -not $Force -and -not $isRemoteInstall) {
    $response = Read-Host "  Skill directory already exists at '$DestinationPath'. Overwrite? (y/N)"
    if ($response -notmatch '^[Yy]') {
        $installFiles = $false
        Write-Host '  Existing skill files were left unchanged.' -ForegroundColor Gray
    }
}

if ($installFiles) {
    $destinationParent = Split-Path -Path $normalizedDestination -Parent
    $destinationName = Split-Path -Path $normalizedDestination -Leaf
    New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null

    $stagingPath = Join-Path $destinationParent ".$destinationName.stage.$([guid]::NewGuid().ToString('N'))"
    $backupPath = Join-Path $destinationParent ".$destinationName.backup.$([guid]::NewGuid().ToString('N'))"
    $existingInstallationMoved = $false
    $replacementInstalled = $false

    try {
        New-Item -ItemType Directory -Path $stagingPath | Out-Null

        foreach ($file in $filesToInstall) {
            $stagedFile = Join-Path $stagingPath $file
            if ($isRemoteInstall) {
                $fileUrl = "$($DownloadBaseUrl.TrimEnd('/'))/$file"
                Invoke-WebRequest -Uri $fileUrl -OutFile $stagedFile
                Write-Host "  Downloaded $file" -ForegroundColor Green
            }
            else {
                $sourceFile = Join-Path $SourcePath $file
                if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
                    throw "Required source file not found: '$sourceFile'."
                }
                Copy-Item -LiteralPath $sourceFile -Destination $stagedFile
                Write-Host "  Copied $file" -ForegroundColor Green
            }
        }

        $missingFiles = @(
            $filesToInstall | Where-Object {
                -not (Test-Path -LiteralPath (Join-Path $stagingPath $_) -PathType Leaf)
            }
        )
        if ($missingFiles.Count -gt 0) {
            throw "Staging validation failed. Missing files: $($missingFiles -join ', ')."
        }

        if (Test-Path -LiteralPath $DestinationPath) {
            Move-Item -LiteralPath $DestinationPath -Destination $backupPath
            $existingInstallationMoved = $true
        }

        Move-Item -LiteralPath $stagingPath -Destination $DestinationPath
        $replacementInstalled = $true
    }
    catch {
        $installError = $_
        if ($existingInstallationMoved) {
            try {
                if (Test-Path -LiteralPath $DestinationPath) {
                    Remove-Item -LiteralPath $DestinationPath -Recurse -Force
                }
                Move-Item -LiteralPath $backupPath -Destination $DestinationPath
                $existingInstallationMoved = $false
            }
            catch {
                throw "Installation failed, and the prior installation could not be restored. It remains at '$backupPath'. Original error: $($installError.Exception.Message)"
            }
        }

        $preservationMessage = if (Test-Path -LiteralPath $DestinationPath) {
            'The prior installation was left unchanged.'
        }
        else {
            'No existing installation was changed.'
        }
        throw "Installation failed. $preservationMessage $($installError.Exception.Message)"
    }
    finally {
        if (Test-Path -LiteralPath $stagingPath) {
            Remove-Item -LiteralPath $stagingPath -Recurse -Force
        }
    }

    if ($replacementInstalled -and (Test-Path -LiteralPath $backupPath)) {
        try {
            Remove-Item -LiteralPath $backupPath -Recurse -Force
        }
        catch {
            Write-Warning "The new installation succeeded, but the backup could not be removed: '$backupPath'."
        }
    }
}

Write-Host 'Configuring PowerShell profile...' -ForegroundColor Yellow
$profileDirectory = Split-Path -Path $ProfilePath -Parent
if (-not (Test-Path -LiteralPath $profileDirectory)) {
    New-Item -ItemType Directory -Path $profileDirectory -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $ProfilePath)) {
    [System.IO.File]::WriteAllText($ProfilePath, '', [System.Text.UTF8Encoding]::new($false))
    Write-Host "  Profile created: $ProfilePath" -ForegroundColor Green
}
else {
    Write-Host "  Profile exists: $ProfilePath" -ForegroundColor Green
}

try {
    $writeTest = [System.IO.File]::Open(
        $ProfilePath,
        [System.IO.FileMode]::Append,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::Read
    )
    $writeTest.Dispose()
}
catch {
    throw "Cannot write to profile '$ProfilePath'. $($_.Exception.Message)"
}

$profileContent = [System.IO.File]::ReadAllText($ProfilePath)
$importPattern = '(?im)^\s*Import-Module\b[^\r\n]*(WindowsTerminalSkill|windows-terminal)'
if ($profileContent -match $importPattern) {
    Write-Host '  Import statement already exists. No profile changes needed.' -ForegroundColor Green
}
else {
    $lineEnding = if ($profileContent.Contains("`r`n")) { "`r`n" } else { [Environment]::NewLine }
    $leadingLineEnding = if ($profileContent.Length -gt 0 -and -not $profileContent.EndsWith("`n") -and -not $profileContent.EndsWith("`r")) {
        $lineEnding
    }
    else {
        ''
    }
    $importStatement = "Import-Module `"$normalizedDestination\$moduleManifest`""
    $importBlock = "$leadingLineEnding# Windows Terminal Skill for GitHub Copilot CLI$lineEnding$importStatement$lineEnding"
    $profileEncoding = Get-TextEncoding -Path $ProfilePath
    [System.IO.File]::AppendAllText($ProfilePath, $importBlock, $profileEncoding)
    Write-Host '  Import statement appended to profile.' -ForegroundColor Green
}

Write-Host ''
Write-Host 'Installation complete!' -ForegroundColor Green
Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Cyan
Write-Host "  1. Restart your terminal or run: . `"$ProfilePath`"" -ForegroundColor White
Write-Host '  2. Start a Copilot CLI session' -ForegroundColor White
Write-Host '  3. Try: !tab "My Task" blue' -ForegroundColor White
Write-Host ''
