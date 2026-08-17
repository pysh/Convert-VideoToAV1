param(
    [string]$InputDir = 'g:\Видео\Сериалы\Зарубежные\Шугар (Sugar)\Sugar (Season 2) DV HDR10 WEB-DL 2160p\',
    [string]$Encoder  = "SvtAv1Enc.Sugar",
    [string]$InputFilter = 'S02E01' ,#'^(?!.*S01E10).*$',
    [PSCustomObject]$CropParameters, # = @{Left=0;Top=120;Right=0;Bottom=120},
    [string]$CustomTemplatePath,
    [string]$TempDirectory,
    [switch]$CopyAudio,
    [switch]$CopyVideo,
    [switch]$KeepTempFiles,
    [switch]$CalculateMetrics,
    [string]$TrimStartSeconds
)

Set-Location $PSScriptRoot

$params = @{
    InputDirectory   = if ($InputDir) { $InputDir } else { Read-Host "Input directory" }
    OutputDirectory  = Join-Path -Path $InputDir -ChildPath '.enc'
    Encoder          = $Encoder
    InputFilter      = $InputFilter
    SkipMetrics      = (-not $CalculateMetrics)
    CropParameters   = $CropParameters #@{Left=0;Top=196;Right=0;Bottom=196}
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

& ".\Convert-VideoToAV1.ps1" @params -Debug -Verbose
