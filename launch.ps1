param(
    [string]$InputDir = 'v:\Сериалы\Зарубежные\Ради всего человечества (For All Mankind)\For All Mankind (Season 5) DV HDR10 WEB-DL 2160p\',
    [string]$Encoder  = "SvtAv1Enc.grain",
    [string]$InputFilter, #'^(?!.*S05e0[1-4]).*$',
    [switch]$CopyAudio,
    [switch]$CopyVideo
)

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptPath

$params = @{
    InputDirectory = if ($InputDir) { $InputDir } else { Read-Host "Input directory" }
    OutputDirectory = (Join-Path -Path $InputDir -ChildPath '.enc')
    Encoder        = $Encoder
    InputFilter    = $InputFilter
    CropParameters = @{Left=0;Top=0;Right=0;Bottom=0}
    CustomTemplatePath = if(Test-Path -LiteralPath (Join-Path $InputDir -ChildPath 'template.vpy')) {Join-Path $InputDir -ChildPath 'template.vpy'}
    #KeepTempFiles = $false
}

if ($CopyAudio) { $params.CopyAudio = $true }
if ($CopyVideo) { $params.CopyVideo = $true }

& ".\Convert-VideoToAV1.ps1" @params -Debug -Verbose
