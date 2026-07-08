<#
.SYNOPSIS
    Shared configuration for the Database Decommission process.
    Dot-source this at the top of every step script:
        . "$PSScriptRoot\00-Decom-Config.ps1"
#>

#region --- EDIT THESE VALUES PER DECOM ---------------------------------------
$Global:DecomConfig = [PSCustomObject]@{
    SourceInstance    = 'SQLPROD01'                      # Instance hosting the DB to decom
    DatabaseName      = 'MyDatabase'                     # DB being decommissioned
    SpecialServer     = 'SPECIALSVR01'                   # "Special" server instance name
    SpecialSharePath  = '\\SPECIALSVR01\DecomBackups'    # UNC path for backup files
    OutputFolder      = "C:\DecomOutput\MyDatabase"      # Where all section text files land
    ChangeTicket      = 'CHG0000000'                     # Normal change ticket number
    SnowRequest       = ''                               # SNOW request # for account removal
}
#endregion --------------------------------------------------------------------

#region --- Module check / install ---------------------------------------------
function Confirm-DecomModules {
    [CmdletBinding()]
    param(
        [string[]]$Modules = @('SqlServer', 'dbatools')
    )

    # Ensure NuGet provider + trusted PSGallery so installs are non-interactive
    if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
        Write-Host "Installing NuGet package provider..." -ForegroundColor Yellow
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
    }
    if ((Get-PSRepository -Name PSGallery).InstallationPolicy -ne 'Trusted') {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    }

    foreach ($m in $Modules) {
        if (-not (Get-Module -ListAvailable -Name $m)) {
            Write-Host "Module '$m' not found. Installing..." -ForegroundColor Yellow
            Install-Module -Name $m -Scope CurrentUser -Force -AllowClobber
        }
        Import-Module $m -ErrorAction Stop
        Write-Host "Module '$m' loaded (v$((Get-Module $m).Version))." -ForegroundColor Green
    }
}
#endregion --------------------------------------------------------------------

#region --- Output helpers ------------------------------------------------------
function Initialize-DecomOutput {
    if (-not (Test-Path $Global:DecomConfig.OutputFolder)) {
        New-Item -Path $Global:DecomConfig.OutputFolder -ItemType Directory -Force | Out-Null
    }
}

function New-DecomLogFile {
    param([Parameter(Mandatory)][string]$SectionName)
    Initialize-DecomOutput
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $path  = Join-Path $Global:DecomConfig.OutputFolder "$SectionName`_$($Global:DecomConfig.DatabaseName)_$stamp.txt"
    "==== $SectionName | DB: $($Global:DecomConfig.DatabaseName) | Instance: $($Global:DecomConfig.SourceInstance) | $(Get-Date) ====" |
        Out-File -FilePath $path -Encoding UTF8
    return $path
}

function Write-DecomLog {
    param(
        [Parameter(Mandatory)][string]$LogFile,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message
    )
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    $line | Tee-Object -FilePath $LogFile -Append
}
#endregion --------------------------------------------------------------------
