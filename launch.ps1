param(
    [string]$InputDir,
    [string]$Encoder = "SvtAv1EncESS.grain_optimized",
    [switch]$CopyAudio,
    [switch]$CopyVideo
)

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptPath

$params = @{
    InputDirectory = if ($InputDir) { $InputDir } else { Read-Host "Input directory" }
    Encoder = $Encoder
}

if ($CopyAudio) { $params.CopyAudio = $true }
if ($CopyVideo) { $params.CopyVideo = $true }

& ".\Convert-VideoToAV1.ps1" @params
