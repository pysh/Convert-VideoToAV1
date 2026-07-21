param(
    [string]$InputDir = 'v:\Сериалы\Отечественные\Условный мент\сезон 06\Uslovnyj.ment.s06.2025.IPTV.1080p.by.ivandubskoj\',
    [string]$Encoder  = "x265.main",
    [string]$InputFilter = 'e3[0-9]', #'^(?!.*20250219).*$',
    [switch]$CopyAudio,
    [switch]$copyVideo,
    [PSCustomObject]$CropParameters = @{Left=0;Top=0;Right=0;Bottom=0}
)

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptPath

$params = @{
    InputDirectory = if ($InputDir) { $InputDir } else { Read-Host "Input directory" }
    OutputDirectory = (Join-Path -Path $InputDir -ChildPath '.enc')
    Encoder        = $Encoder
    InputFilter    = $InputFilter
    CropParameters = $CropParameters #@{Left=0;Top=196;Right=0;Bottom=196}
    CustomTemplatePath = if(Test-Path -LiteralPath (Join-Path $InputDir -ChildPath 'template.vpy')) {Join-Path $InputDir -ChildPath 'template.vpy'}
    #KeepTempFiles = $false
}

if ($CopyAudio) { $params.CopyAudio = $true }
if ($CopyVideo) { $params.CopyVideo = $true }

& ".\Convert-VideoToAV1.ps1" @params -Debug -Verbose -CopyAudio
