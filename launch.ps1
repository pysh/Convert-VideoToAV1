param(
    [string]$InputDir = 'g:\Видео\Сериалы\Зарубежные\Джентльмены (The Gentlemen)\The.Gentlemen.S02.NF.DV.HDR.WEB-DL.2160p.by.AKTEP\',
    [string]$Encoder  = "SvtAv1Enc.grain",
    [string]$InputFilter, # = '^(?!.*S05E0[1-6]).*$',
    [PSCustomObject]$CropParameters = @{Left=0;Top=276;Right=0;Bottom=276},
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

Write-Host $params -ForegroundColor DarkMagenta
& ".\Convert-VideoToAV1.ps1" @params -Debug -Verbose
