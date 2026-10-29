param(
    [string]$InputDir = 'v:\Сериалы\Отечественные\Условный мент\Условный мент.S06.2025.WEB-DL 1080p.Files-x\',
    [string]$Encoder  = "x265.UMent",
    [string]$InputFilter = "^100\.", #'^(?!(0[0-9]|1[0-9]|2[0-6])\.).*$', # = '^(?!.*S05E0[1-6]).*$',
    [PSCustomObject]$CropParameters, # = @{Left=0;Top=264;Right=0;Bottom=264},
    [string]$CustomTemplatePath,
    [string]$TempDirectory,
    [switch]$CopyAudio = $true,
    [switch]$CopyVideo,
    [switch]$KeepTempFiles,
    [switch]$CalculateMetrics,
    [string]$TrimStartSeconds,
    [string]$FilePrefix,
    [string]$FileSuffix
)

Set-Location $PSScriptRoot

$params = @{
    InputDirectory   = if ($InputDir) { $InputDir } else { Read-Host "Input directory" }
    OutputDirectory  = Join-Path -Path $InputDir -ChildPath '.enc'
    Encoder          = $Encoder
    InputFilter      = $InputFilter
    SkipMetrics      = (-not $CalculateMetrics)
    CustomTemplatePath = if (Test-Path -LiteralPath (Join-Path $InputDir 'template.vpy')) {
        Join-Path $InputDir 'template.vpy'
    } else {
        $CustomTemplatePath
    }
}
if ($CopyAudio) { $params.CopyAudio = $true }
if ($CopyVideo) { $params.CopyVideo = $true }
if ($KeepTempFiles) { $params.KeepTempFiles = $true }
if ($TempDirectory) { $params.TempDirectory = $TempDirectory }
if ($TrimStartSeconds) { $params.TrimStartSeconds = $TrimStartSeconds }
if ($CropParameters) { $params.CropParameters = $CropParameters }
if ($FilePrefix) { $params.FilePrefix = $FilePrefix }
if ($FileSuffix) { $params.FileSuffix = $FileSuffix }

Write-Host $params -ForegroundColor DarkMagenta
& ".\Convert-VideoToAV1.ps1" @params -Debug -Verbose
