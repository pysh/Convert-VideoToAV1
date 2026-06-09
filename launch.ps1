param(
    [string]$InputDir = 'v:\Сериалы\Зарубежные\Ради всего человечества (For All Mankind)\For.All.Mankind.S02.2160p.ATVP.WEB-DL.DDP5.1.Atmos.DoVi.HEVC.by.DVT\',
    [string]$Encoder  = "SvtAv1Enc.grain",
    [switch]$CopyAudio,
    [switch]$CopyVideo
)

$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptPath

$params = @{
    InputDirectory = if ($InputDir) { $InputDir } else { Read-Host "Input directory" }
    OutputDirectory = (Split-Path -LiteralPath $InputDir -Parent)
    Encoder        = $Encoder
    InputFilter    = 'S02\.E02'
    CropParameters = @{Left=0;Top=0;Right=0;Bottom=0}
    CustomTemplatePath = if(Test-Path -LiteralPath (Join-Path $InputDir -ChildPath 'template.vpy')) {Join-Path $InputDir -ChildPath 'template.vpy'}

}

if ($CopyAudio) { $params.CopyAudio = $true }
if ($CopyVideo) { $params.CopyVideo = $true }

& ".\Convert-VideoToAV1.ps1" @params
