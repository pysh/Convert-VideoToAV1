param(
    [string]$InputDir = 'v:\Сериалы\Отечественные\Заложник\сезон 01\[NOOBDL]Заложник.S01.2160p.WEB-DL.x265.HDR\',
    [string]$Encoder  = "SvtAv1Enc.main",
    [string]$InputFilter = '', #'^(?!.*20250219).*$',
    [PSCustomObject]$CropParameters = @{Left=0;Top=0;Right=0;Bottom=0},
    [string]$CustomTemplatePath,
    [string]$TempDirectory,
    [switch]$CopyAudio,
    [switch]$CopyVideo,
    [switch]$KeepTempFiles
)

Set-Location $PSScriptRoot

$params = @{
    InputDirectory   = if ($InputDir) { $InputDir } else { Read-Host "Input directory" }
    OutputDirectory  = Join-Path -Path $InputDir -ChildPath '.enc'
    Encoder          = $Encoder
    InputFilter      = $InputFilter
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

& ".\Convert-VideoToAV1.ps1" @params -Debug -Verbose
