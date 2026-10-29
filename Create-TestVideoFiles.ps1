<#
.SYNOPSIS
    Automated video encoding test suite with parallel VMAF calculation.
.DESCRIPTION
    Tests multiple encoders and quality settings, then calculates VMAF metrics in parallel.
.VERSION
    3.0.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$SourceVideoPath = 'G:\Видео\Сериалы\Зарубежные\Паук-Нуар (Spider-Noir)\Spider-Noir.S01.2160p.AMZN.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265-FLUX\Spider-Noir.S01E01.Step.Into.My.Office.2160p.AMZN.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265-FLUX.mkv',
    
    [Parameter(Mandatory = $false)]
    [string]$TempDir = 'y:\.temp\',

    [Parameter(Mandatory = $false)]
    [string]$TemplatePath = $null,
    
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 10000)]
    [int]$SampleDurationSeconds = 200,

    [Parameter(Mandatory = $false)]
    [ValidateSet('AviSynth', 'VapourSynth')] 
    [string]$FrameServer = 'VapourSynth',

    [Parameter(Mandatory = $false)]
    [hashtable]$CropParameters, # = @{Left = 0; Top = 276; Right = 0; Bottom = 276 },

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 10000)]
    [int]$AutoCropRound = 4,

    [Parameter(Mandatory = $false)]
    [string]$FilePrefix = '',

    [Parameter(Mandatory = $false)]
    [string]$FileSuffix = '',

    [Parameter(Mandatory = $false)]
    [string[]]$TestedEncoders = @(
        # 'x265'
        # 'SvtAv1EncTritium'
        'SvtAv1'
        'SvtAv1_vmaf'
        # 'SvtAv1Essential'
        # 'SvtAv1PSY'
    ),

    [Parameter(Mandatory = $false)]
    [int]$VmafThreads = 2,

    [Parameter(Mandatory = $false)]
    [int]$Subsample = 5,

    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [switch]$CreateLosslessSample=$true
)

#region Banner
Write-Host @"
  ____                _      _____         _   _____ _ _           
 / ___|_ __ ___  __ _| |_ __|_   _|__  ___| |_|  ___(_) | ___  ___ 
| |   | '__/ _ \/ _``` | __/ _ \| |/ _ \/ __| __| |_  | | |/ _ \/ __|
| |___| | |  __/ (_| | ||  __/| |  __/\__ \ |_|  _| | | |  __/\__ \
 \____|_|  \___|\__,_|\__\___||_|\___||___/\__|_|   |_|_|\___||___/ v3.0
"@ -ForegroundColor DarkGreen
#endregion

#region Module Import
$modulePath = 'D:\Sources\Convert-VideoToAV1\Modules\'

$modulesToImport = [ordered]@{
    Utilities      = 'Utilities.psm1'
    QualityMetrics = 'QualityMetrics.psm1'
    VideoInfo      = 'Get-VideoInfo.ps1'
}

foreach ($moduleName in $modulesToImport.Keys) {
    $moduleFilePath = Join-Path -Path $modulePath -ChildPath $modulesToImport[$moduleName]

    if (Test-Path -LiteralPath $moduleFilePath -PathType Leaf) {
        Import-Module -Name $moduleFilePath -Force -ErrorAction Stop
        Write-Log "$moduleName module loaded" -Severity Debug
    }
}
#endregion


#region Tools Configuration
$script:Tools = @{
    FFmpeg   = 'd:\Sources\media-autobuild_suite\local64\bin-video\ffmpeg.exe'
    FFprobe  = 'd:\Sources\media-autobuild_suite\local64\bin-video\ffprobe.exe'
    VSPipe   = 'vspipe.exe'
    MkvMerge = 'mkvmerge.exe'
}

foreach ($tool in $script:Tools.Values) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Error "Required tool not found: $tool"
        exit 1
    }
}
#endregion

#region Encoder Configurations
$svtav1_CommonParams    = @(
    '--progress', '2',
    # '--lp', 4,
    '--rc', '0',
    '--enable-qm', 1,
    '--film-grain-denoise', 0, '--film-grain', '12',
    '--color-range', '0', '--color-primaries', 1, '--transfer-characteristics', 1, '--matrix-coefficients', 1
)

$script:EncoderConfigs = @{
    SvtAv1           = @{
        Name            = 'SvtAv1'
        DisplayName     = 'SVT-AV1'
        Executable      = 'X:\Apps\_VideoEncoding\StaxRip\Apps\Encoders\SvtAv1EncApp\SvtAv1EncApp.exe'
        Type            = 'svt'
        CommonParams    = $svtav1_CommonParams
        TestParams      = @{
            crf    = @(30, 32, 34,36,38)
            preset = @(5)
            tune   = @(1, 4)
        }
        OutputExtension = 'ivf'
    }
    SvtAv1_VMAF      = @{
        Name            = 'SvtAv1_vmaf'
        DisplayName     = 'SVT-AV1_vmaf'
        Executable      = 'X:\Apps\_VideoEncoding\StaxRip\Apps\Encoders\SvtAv1EncApp\SvtAv1EncApp.exe'
        Type            = 'svt'
        CommonParams    = $svtav1_CommonParams
        TestParams      = @{
            crf    = @(35)
            preset = @(5)
            tune   = @(5)
        }
        OutputExtension = 'ivf'
    }
    SvtAv1EncTritium = @{
        Name            = 'SvtAv1_tritium'
        DisplayName     = 'SvtAv1Enc Tritium'
        Executable      = 'X:\Apps\_VideoEncoding\ffmpeg\svt-av1-tritium\SvtAv1EncApp_icelake.exe'
        Type            = 'svt'
        CommonParams    = $svtav1_CommonParams
        TestParams      = @{
            crf    = @(40, 42, 44)
            preset = @(5)
            tune   = @(1, 4, 5)
            # tune = [0 = VQ, 1 = PSNR, 2 = SSIM, 3 = IQ (Image Quality), 4 = MS_SSIM (MS_SSIM and SSIMULACRA2 optimized mode), 5 = Film Grain], default is 1 [0-5]
        }
        OutputExtension = 'ivf'
    }

    SvtAv1Essential  = @{
        Name            = 'SvtAv1Essential'
        DisplayName     = 'SVT-AV1 Essential'
        Executable      = 'X:\Apps\_VideoEncoding\StaxRip\Apps\Encoders\SvtAv1EncApp-Essential\SvtAv1EncApp.exe'
        Type            = 'svt'
        CommonParams    = @(
            '--progress', '2',
            '--rc', '0',
            '--enable-qm', 1,
            # '--tune', 2,
            '--film-grain-denoise', 0, '--film-grain', '10',
            '--color-range', '0', '--color-primaries', 1, '--transfer-characteristics', 1, '--matrix-coefficients', 1
        )
        TestParams      = @{
            quality = @('high', 'medium', 'low', 'lower')
            speed   = @('slow')
        }
        OutputExtension = 'webm'
    }
    SvtAv1PSY        = @{
        Name            = 'SvtAv1PSY'
        DisplayName     = 'SVT-AV1 (Psychovisual)'
        Executable      = 'X:\Apps\_VideoEncoding\StaxRip\Apps\Encoders\SvtAv1EncApp-PSYEX\SvtAv1EncApp.exe'
        Type            = 'svt'
        CommonParams    = @(
            '--progress', '3', '--rc', '0',
            '--film-grain-denoise', 0, '--film-grain', '10',
            '--color-primaries', '1', '--transfer-characteristics', '1', '--matrix-coefficients', '1'
        )
        TestParams      = @{
            crf    = @(38, 36, 34)
            preset = @(4)
        }
        OutputExtension = 'ivf'
    }
    x265             = @{
        Name            = 'x265'
        DisplayName     = 'x265 (HEVC)'
        Executable      = 'X:\Apps\_VideoEncoding\StaxRip\Apps\Encoders\x265\x265.exe'
        Type            = 'x26x'
        CommonParams    = @(
            # '--no-strong-intra-smoothing',
            '--output-depth', '10',
            '--range', 'limited', '--colorprim', 'bt709', '--transfer', 'bt709', '--colormatrix', 'bt709'
        )
        TestParams      = @{
            crf    = @(18, 20, 22, 24, 26, 28)
            preset = @('slower')
        }
        OutputExtension = 'hevc'
    }
    x264             = @{
        Name            = 'x264'
        DisplayName     = 'x264 (AVC)'
        Executable      = 'X:\Apps\_VideoEncoding\av1an\x264.exe'
        Type            = 'x26x'
        CommonParams    = @(
            '--no-progress', '--demuxer', 'y4m', '--output-csp', 'i420', '--tune', 'ssim'
        )
        TestParams      = @{
            crf    = @(18, 20, 22, 24, 26, 28, 30)
            preset = @('medium', 'slow', 'slower', 'veryslow')
        }
        OutputExtension = 'h264'
    }
}
#endregion

#region Helper Functions
function Write-Log {
    <#
    .SYNOPSIS
        Записывает сообщение в лог с указанием уровня важности
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)][string]$Message,
        [ValidateSet('Debug', 'Information', 'Info', 'Warning', 'Warn', 'Error', 'Success', 'Verbose')]
        [string]$Severity = 'Information',
        [string]$Category,
        [switch]$NoNewLine
    )

    $timestamp = [DateTime]::Now.ToString("yyyy-MM-dd HH:mm:ss.fff")

    $SeverityConfig = @{
        'Success'     = @{ Abbrev = 'OK!'; Color = 'Green' }
        'Debug'       = @{ Abbrev = 'DBG'; Color = 'DarkGray' }
        'Information' = @{ Abbrev = 'INF'; Color = 'Cyan' }
        'Info'        = @{ Abbrev = 'INF'; Color = 'Cyan' }
        'Verbose'     = @{ Abbrev = 'VRB'; Color = 'DarkYellow' }
        'Warning'     = @{ Abbrev = 'WRN'; Color = 'DarkMagenta' }
        'Warn'        = @{ Abbrev = 'WRN'; Color = 'DarkMagenta' }
        'Error'       = @{ Abbrev = 'ERR'; Color = 'Red' }
    }

    $config = $SeverityConfig[$Severity]
    $logSeverity = $config.Abbrev
    $color = $config.Color

    $categoryStr = if ($Category) { " [$Category]" } else { '' }
    $logMessage = "[$timestamp] [$logSeverity]$categoryStr`t$Message"
    Write-Host $logMessage -ForegroundColor $color -NoNewline:$NoNewLine
}

function Get-TestCombinations {
    [CmdletBinding()]
    param([hashtable]$EncoderConfig)
    
    $paramNames = $EncoderConfig.TestParams.Keys | Sort-Object
    $combinations = @(@{})
    
    foreach ($paramName in $paramNames) {
        $values = $EncoderConfig.TestParams[$paramName]
        $newCombinations = @()
        
        foreach ($combo in $combinations) {
            foreach ($value in $values) {
                $newCombo = $combo.Clone()
                $newCombo[$paramName] = $value
                $newCombinations += $newCombo
            }
        }
        $combinations = $newCombinations
    }
    
    return $combinations
}

function Get-EncoderVersion {
    [CmdletBinding()]
    param([hashtable]$EncoderConfig)
    
    try {
        $versionLine = & $EncoderConfig.Executable --version 2>&1 | Select-Object -First 1
        switch -Wildcard ($EncoderConfig.Name) {
            'SvtAv1*' {
                if ($versionLine -match 'SVT-AV1(?:-PSY|-HDR|-Essential|-Tritium)? (v[\d\.]+(?:-[^-]+)?)') {
                    return $Matches[1]
                }
            }
            'x265' {
                if ($versionLine -match 'HEVC encoder version (.+)$') {
                    return $Matches[1].Trim()
                }
            }
            'x264' {
                if ($versionLine -match 'x264 ([\d\.]+)') {
                    return $Matches[1]
                }
            }
        }
        return 'Unknown'
    }
    catch {
        return 'Unknown'
    }
}

function Get-ParametersString {
    [CmdletBinding()]
    param(
        [hashtable]$EncoderConfig,
        [hashtable]$TestParams
    )
    
    $parts = @()
    foreach ($key in ($TestParams.Keys | Sort-Object)) {
        $parts += "$key=$($TestParams[$key])"
    }
    return $parts -join ' '
}

function Get-OutputFileName {
    [CmdletBinding()]
    param(
        [hashtable]$EncoderConfig,
        [hashtable]$TestParams
    )
    
    $paramStr = ($TestParams.Keys | Sort-Object | ForEach-Object { "$_=$($TestParams[$_])" }) -join '_'
    $OutputFileName = "${FilePrefix}$($EncoderConfig.Name)$(if ($paramStr) {"_$paramStr"})${FileSuffix}.mkv"
    return $OutputFileName
}

function New-FrameServerScript {
    [CmdletBinding()]
    param(
        [string]$ScriptPath,
        [string]$VideoPath,
        [PSCustomObject]$CropParams
    )
    
    $indexFileName = "${VideoPath}.lwi"
    $scriptDir = Split-Path -LiteralPath $ScriptPath
    if ($scriptDir -and -not (Test-Path -LiteralPath $scriptDir)) {
        New-Item -Path $scriptDir -ItemType Directory -Force | Out-Null
    }
    
    # VapourSynth script
    $vpyPath = [IO.Path]::ChangeExtension($ScriptPath, 'vpy')
    $sourceDir = Split-Path -LiteralPath $SourceVideoPath
    $localTemplate = Join-Path $sourceDir 'template.vpy'
    
    if ($TemplatePath -and (Test-Path -LiteralPath $TemplatePath)) {
        $vpyTemplatePath = $TemplatePath
    }
    elseif (Test-Path -LiteralPath $localTemplate) {
        $vpyTemplatePath = $localTemplate
    }
    else {
        $vpyTemplatePath = 'd:\PSScripts\Convert-VideoToAV1\Templates\VapourSynth\universal_v2_DoVi.vpy'
    }
    
    if (Test-Path -LiteralPath $vpyTemplatePath) {
        $vpyContent = Get-Content -LiteralPath $vpyTemplatePath -Raw -Encoding UTF8
        $vpyContent = $vpyContent -replace '{VideoPath}', $VideoPath
        $vpyContent = $vpyContent -replace '{CacheFile}', $indexFileName
        $vpyContent = $vpyContent -replace '{CropLeft}', $CropParams.Left
        $vpyContent = $vpyContent -replace '{CropRight}', $CropParams.Right
        $vpyContent = $vpyContent -replace '{CropTop}', $CropParams.Top
        $vpyContent = $vpyContent -replace '{CropBottom}', $CropParams.Bottom
    }
    else {
        $vpyContent = @"
import vapoursynth as vs
core = vs.core
clip = core.lsmas.LWLibavSource(source=r"$VideoPath", cachefile=r"$indexFileName", prefer_hw=4, threads=1)
clip = core.std.Crop(clip, $($CropParams.Left), $($CropParams.Right), $($CropParams.Top), $($CropParams.Bottom))
clip = core.fmtc.bitdepth(clip, bits=10)
clip.set_output()
"@
    }
    Set-Content -LiteralPath $vpyPath -Value $vpyContent -Encoding UTF8
    
    # AviSynth script
    $avsPath = [IO.Path]::ChangeExtension($ScriptPath, 'avs')
    $avsContent = @"
AddAutoloadDir("X:\Apps\_VideoEncoding\StaxRip\Apps\FrameServer\AviSynth\plugins\")
LoadPlugin("X:\Apps\_VideoEncoding\StaxRip\Apps\Plugins\Dual\L-Smash-Works\LSMASHSource.dll")
LWLibavVideoSource("$VideoPath")
Crop($($CropParams.Left), $($CropParams.Top), -$($CropParams.Right), -$($CropParams.Bottom))
"@
    Set-Content -LiteralPath $avsPath -Value $avsContent -Encoding UTF8
}

function Get-VideoAutoCropParams {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$InputFile,
        
        [int]$LuminanceThreshold = 1000,
        [int]$Round = 2
    )
    
    function RoundToNearestMultiple {
        param([int]$Value, [int]$Multiple)
        if ($Multiple -eq 0) { return $Value }
        return [Math]::Round($Value / $Multiple) * $Multiple
    }
    
    $tmpScriptFile = [IO.Path]::ChangeExtension([IO.Path]::GetTempFileName(), 'vpy')
    $cacheFile = "${InputFile}.lwi"
    
    $vpyContent = @"
import vapoursynth as vs
core = vs.core
clip = core.lsmas.LWLibavSource(source=r"$InputFile", cachefile=r"$cacheFile", prefer_hw=4, threads=1)
props = clip.get_frame(0).props

MATRIX = {'RGB': 0, 'BT709': 1, 'UNSPEC': 2, 'BT470BG': 5, 'BT2020_NCL': 9}
TRANSFER = {'BT709': 1, 'BT470BG': 5, 'ST2084': 16}
PRIMARIES = {'BT709': 1, 'BT470BG': 5, 'BT2020': 9}

matrix = props.get('_Matrix', MATRIX['UNSPEC'])
if matrix == MATRIX['UNSPEC'] or matrix >= 15:
    matrix = MATRIX['RGB'] if clip.format.id == vs.RGB24 else (MATRIX['BT709'] if clip.height > 576 else MATRIX['BT470BG'])

transfer = props.get('_Transfer', TRANSFER['BT709'])
if transfer <= 0 or transfer >= 19:
    transfer = TRANSFER['BT470BG'] if matrix == MATRIX['BT470BG'] else (TRANSFER['ST2084'] if matrix == MATRIX['BT2020_NCL'] else TRANSFER['BT709'])

primaries = props.get('_Primaries', PRIMARIES['BT709'])
if primaries <= 0 or primaries >= 23:
    primaries = PRIMARIES['BT470BG'] if matrix == MATRIX['BT470BG'] else (PRIMARIES['BT2020'] if matrix == MATRIX['BT2020_NCL'] else PRIMARIES['BT709'])

clip = clip.resize.Bicubic(matrix_in=matrix, transfer_in=transfer, primaries_in=primaries, format=vs.RGB24)
clip = clip.libp2p.Pack()
clip.set_output()
"@
    Set-Content -LiteralPath $tmpScriptFile -Value $vpyContent -Encoding UTF8
    
    $autoCropPath = 'd:\PSScripts\Convert-VideoToAV1\Tools\AutoCrop.exe'
    #X:\Apps\_VideoEncoding\StaxRip\Apps\Support\AutoCrop\AutoCrop.exe "g:\Видео\Сериалы\Зарубежные\Я тебя отыщу (I Will Find You)\I.Will.Find.You.S01.2160p.NF.WEB-DL.SDR.4xRus.Ukr.Eng.Subs-alekartem\I.Will.Find.You.S01E01.2160p.NF.WEB-DL.SDR.4xRus.Ukr.Eng.Subs-alekartem.mkv_temp\I.Will.Find.You.S01E01.2160p.NF.WEB-DL.SDR.4xRus.Ukr.Eng.Subs-alekartem_new_source.vpy" 3 15 3399 3399 1400 0
    try {
        $output = & $autoCropPath $tmpScriptFile 2 400 144 144 $LuminanceThreshold 0 2>&1
        $cropLine = $output | Select-Object -Last 1
        $cropParams = $cropLine -split ',' | ForEach-Object { [int]$_ }
        Write-Host "autocrop output: $cropLine" -ForgroundColor Magenta
        return [PSCustomObject]@{
            Left   = RoundToNearestMultiple -Value $cropParams[0] -Multiple $Round
            Top    = RoundToNearestMultiple -Value $cropParams[1] -Multiple $Round
            Right  = RoundToNearestMultiple -Value $cropParams[2] -Multiple $Round
            Bottom = RoundToNearestMultiple -Value $cropParams[3] -Multiple $Round
        }
    }
    catch {
        return [PSCustomObject]@{
            Left   = 0
            Top    = 0
            Right  = 0
            Bottom = 0
        }
    }
    finally {
        if (Test-Path -LiteralPath $tmpScriptFile) {
            Remove-Item -LiteralPath $tmpScriptFile -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-EncoderProcess {
    [CmdletBinding()]
    param(
        [hashtable]$EncoderConfig,
        [hashtable]$TestParams,
        [string]$InputScript,
        [string]$OutputFile,
        [string]$ServerType,
        [int]$FrameCount
    )
    
    $tempDir = Split-Path -LiteralPath $OutputFile
    $tempOutput = Join-Path $tempDir "temp_$([IO.Path]::GetFileNameWithoutExtension($OutputFile)).$($EncoderConfig.OutputExtension)"
    
    $cmdParams = @()
    foreach ($key in $TestParams.Keys) {
        if ($EncoderConfig.Type -eq 'aom') {
            $cmdParams += "--$key=$($TestParams[$key])"
        }
        else {
            $cmdParams += "--$key", $TestParams[$key]
        }
    }
    $allParams = $EncoderConfig.CommonParams + $cmdParams
    
    try {
        if ($EncoderConfig.Type -eq 'x26x') {
            $vspipeParams = @('-c', 'y4m', $InputScript, '-')
            $x26xParams = @('--y4m', '--input', '-', '--output', $tempOutput)
            # $allParams += @('--input', $InputScript, '--output', $tempOutput, '--frames', $FrameCount)
            # & $EncoderConfig.Executable @allParams
            & $script:Tools.VSPipe $vspipeParams | & $EncoderConfig.Executable @allParams $x26xParams
        }
        else {
            $av1Params = @('--frames', $FrameCount, '--input', '-', '--output', $tempOutput)
            
            if ($ServerType -eq 'VapourSynth') {
                Write-Host "$($script:Tools.VSPipe) -c y4m ${InputScript} - | $($EncoderConfig.Executable) $($allParams -join ' ') $($av1Params -join ' ')" -ForegroundColor Gray
                & $script:Tools.VSPipe -c y4m $InputScript - | & $EncoderConfig.Executable @allParams @av1Params
            }
            else {
                $ffmpegParams = @(
                    '-y', '-hide_banner', '-v', 'error', '-nostats'
                    '-i', $InputScript
                    '-f', 'yuv4mpegpipe'
                    '-strict', '-1'
                    '-'
                )
                Write-Host "$($ffmpegParams -join ' ') | $($EncoderConfig.Executable) $($allParams -join ' ') $($av1Params -join ' ')" -ForegroundColor Gray
                & $script:Tools.FFmpeg @ffmpegParams | & $EncoderConfig.Executable @allParams @av1Params
            }
        }
        
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
            throw "Encoder failed with exit code: $LASTEXITCODE"
        }
        
        # Wait for file and validate
        $retryCount = 0
        while ($retryCount -lt 5 -and -not (Test-Path -LiteralPath $tempOutput)) {
            Start-Sleep -Milliseconds 500
            $retryCount++
        }
        
        if (-not (Test-Path -LiteralPath $tempOutput)) {
            throw "Output file not created: $tempOutput"
        }
        
        $fileSize = (Get-Item -LiteralPath $tempOutput).Length
        if ($fileSize -eq 0) {
            throw "Output file is empty: $tempOutput"
        }
        
        # Pack into MKV
        & $script:Tools.MkvMerge --ui-language en --priority lower --output $OutputFile $tempOutput 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "mkvmerge failed with exit code: $LASTEXITCODE"
        }
        
        Remove-Item -LiteralPath $tempOutput -Force -ErrorAction SilentlyContinue
        return $OutputFile
    }
    catch {
        throw "Encoding failed: $_"
    }
}

function Get-LosslessSample {
    [CmdletBinding()]
    param(
        [string]$InputScript,
        [string]$OutputFile,
        [int]$FrameCount
    )

    $OutputFile = [IO.Path]::ChangeExtension($OutputFile, '.x265')

    $nvenccApp = 'X:\Apps\_VideoEncoding\StaxRip\Apps\Encoders\NVEncC\NVEncC64.exe'

    $vspipeParams = @('-c', 'y4m', $InputScript, '-')
    $svtParams = @(
        '--input', 'stdin',
        '--output', $OutputFile,
        '--progress', 2,
        '--lossless', 1
        if ($frameCount -and $frameCount -gt 0) { '--frames', $frameCount }
    )
    $x265Params = @(
        if ($frameCount -and $frameCount -gt 0) { '--frames', $frameCount }
        '--reader-options', 'library=C:\Python313\Lib\site-packages\vapoursynth\vsscript.dll',
        '--output-depth', 10,
        '--video-signal-type-preset', 'BT709_YCC',
        '--lossless',
        '--input', $InputScript,
        '--output', ([IO.Path]::ChangeExtension($OutputFile, '.x265'))
    )
    $nvenccParams = @(
        '--y4m',
        '--codec', 'hevc',
        '--preset', 'quality',
        '--tune', 'lossless',
        '--aq', '--aq-temporal',
        '--lookahead', 32,
        '--ref', 7,
        '--bframes', 7,
        '--gop-len', 600
        '--output-depth', 10
        '--colormatrix', 'bt709',
        '--colorprim', 'bt709',
        '--transfer', 'bt709',
        '--colorrange', 'limited',
        '-i', '-',
        '-o', ([IO.Path]::ChangeExtension($OutputFile, '.hevc'))
    )

    # Write-Log "& $($script:Tools.VSPipe) $($vspipeParams -join ' ') | & $($script:encoder.Executable) $($svtParams -join ' ')" -Severity Info
    # & $script:Tools.VSPipe @vspipeParams | & $script:encoder.Executable @svtParams

    # Write-Log "& $($script:Tools.VSPipe) $($vspipeParams -join ' ') | & $nvenccApp $($nvenccParams -join ' ')" -Severity Info
    # & $script:Tools.VSPipe @vspipeParams | & $nvenccApp @nvenccParams

    Write-Log "& x265.exe $($x265Params -join ' ')" -Severity Info
    & x265.exe @x265Params | Out-Null

    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
        throw "Encoder failed with exit code: $LASTEXITCODE"
    }
    if (Test-Path -LiteralPath $OutputFile -PathType Leaf) {
        return (Get-Item -LiteralPath $OutputFile).FullName
    }
}

#endregion

#region Main Script
try {
    # Validate available encoders
    $availableEncoders = @()
    foreach ($encoderName in $TestedEncoders) {
        if ($script:EncoderConfigs.ContainsKey($encoderName)) {
            $encoder = $script:EncoderConfigs[$encoderName]
            if (Test-Path -LiteralPath $encoder.Executable) {
                $availableEncoders += $encoder
                Write-Log "Found encoder: $($encoder.DisplayName) - $(Get-EncoderVersion $encoder)" -Severity Info
            }
            else {
                Write-Log "Encoder not found: $($encoder.Executable)" -Severity Warning
            }
        }
    }
    
    if ($availableEncoders.Count -eq 0) {
        throw "No available encoders found"
    }
    
    # Prepare working directory
    $sourceFile = Get-Item -LiteralPath $SourceVideoPath
    $workingDir = if (Test-Path -LiteralPath $TempDir) {
        Join-Path $TempDir "$($sourceFile.BaseName)_EncodingTests" | ConvertTo-LatinTranslit -Standard ISO -IsFilePath
    }
    else {
        Join-Path $sourceFile.DirectoryName "$($sourceFile.BaseName)_EncodingTests" | ConvertTo-LatinTranslit -Standard ISO -IsFilePath
    }
    New-Item -Path $workingDir -ItemType Directory -Force | Out-Null
    Write-Log "Working directory: $workingDir" -Severity Info
    
    # Create sample
    $sourceFileInfo = Get-VideoScriptInfo -ScriptPath $sourceFile
    # $sourceFileInfo = Get-VideoInfo $sourceFile -Verbose -Debug
    $fragmentCount = 20
    $frameDuration = 15
    $sampleDurationSeconds = $fragmentCount * $frameDuration
    if (($sourceFileInfo.Duration / $sampleDurationSeconds) -gt 1.1) {
        $sampleFile = Join-Path $workingDir "$($sourceFile.BaseName)_sample$($sourceFile.Extension)" | ConvertTo-LatinTranslit -Standard ISO -IsFilePath
        if (-not (Test-Path -LiteralPath $sampleFile) -or $Force) {
            Write-Log "Creating sample (duration: ${SampleDurationSeconds}s)..." -Severity Info
            $sampleResult = Copy-VideoFragments -InputFile $sourceFile.FullName -OutputFile $sampleFile `
                -FragmentCount $fragmentCount -FragmentDuration $frameDuration
            $sampleFile = $sampleResult.OutputFile
        }
        else {
            Write-Log "Using existing sample: $sampleFile" -Severity Info
        }
        $sampleFile = Get-Item -LiteralPath $sampleFile
    }
    else {
        Write-Log "Using source file as sample: $sampleFile" -Severity Info
        $sampleFile = $sourceFile
    }

    # Get video info
    $videoInfo = Get-VideoStats -VideoFilePath $sampleFile
    Write-Log "Video: $($videoInfo.ResolutionWidth)x$($videoInfo.ResolutionHeight), $($videoInfo.FrameRate) fps" -Severity Info
    
    # Get crop parameters
    $cropParams = $CropParameters
    if (-not ($cropParams.Left -or $cropParams.Right -or $cropParams.Top -or $cropParams.Bottom)) {
        Write-Log "Auto-detecting crop parameters..." -Severity Info
        $cropParams = Get-VideoAutoCropParams -InputFile $sampleFile -Round $AutoCropRound
    }
    Write-Log "Crop: L=$($cropParams.Left) R=$($cropParams.Right) T=$($cropParams.Top) B=$($cropParams.Bottom)" -Severity Info
    
    # Generate frame server script
    $scriptBasePath = Join-Path $workingDir $sampleFile.BaseName
    $serverScript = if ($FrameServer -eq 'VapourSynth') { 
        "${scriptBasePath}.vpy" 
    }
    else { 
        "${scriptBasePath}.avs" 
    }
    New-FrameServerScript -ScriptPath $serverScript -VideoPath $sampleFile -CropParams $cropParams
    Write-Log "Using script: $serverScript" -Severity Info
    
    # Generate test configurations
    $testConfigs = [System.Collections.Generic.List[PSObject]]::new()
    $totalTests = 0
    
    foreach ($encoder in $availableEncoders) {
        $combinations = Get-TestCombinations $encoder
        $testConfigs.Add(@{
                Encoder      = $encoder
                Combinations = $combinations
                Count        = $combinations.Count
            })
        $totalTests += $combinations.Count
        Write-Log "Encoder $($encoder.DisplayName): $($combinations.Count) tests" -Severity Info
    }
    
    Write-Log "Total tests: $totalTests" -Severity Success
    
    # ============================================
    # PHASE 1: ENCODING
    # ============================================
    Write-Log "`n" -Severity Info
    Write-Log "======================= PHASE 1: ENCODING =======================" -Severity Success
    
    $encodedFiles = [System.Collections.Generic.List[PSObject]]::new()
    $testNumber = 0
    $originalFileSize = (Get-Item -LiteralPath $sourceFile.FullName).Length
    $reportPath = Join-Path $workingDir 'encoding_report.csv'


    #region Create lossless sample

    if ($CreateLosslessSample) {
        $losslessSampleFile = Join-Path 'Y:\.temp\' -ChildPath "$([IO.Path]::GetFileNameWithoutExtension($serverScript))[LL].x265"
        $losslessSampleScript = [IO.Path]::ChangeExtension($losslessSampleFile, '.vpy')
        $frameCount = $videoInfo.FrameCount
        if (Test-Path -LiteralPath $losslessSampleFile) {
            Write-Log "Using existing lossless sample: $losslessSampleFile" -Severity Info
        }
        else {
            Write-Log "Creating lossless sample..." -Severity Info
            $losslessSampleFile = Get-LosslessSample -InputScript $serverScript -OutputFile $losslessSampleFile -FrameCount $frameCount
        }
        Write-Log "Using script: $losslessSampleScript" -Severity Info
        $losslessSampleScriptText = @"
import vapoursynth as vs
core = vs.core
clip = core.lsmas.LWLibavSource(source=r"${losslessSampleFile}", prefer_hw=4, threads=1)
clip.set_output()
"@
        $losslessSampleScriptText | Out-File -LiteralPath $losslessSampleScript -Encoding UTF-8
        $serverScript = $losslessSampleScript
    }

    #endregion

    foreach ($config in $testConfigs) {
        $encoder = $config.Encoder
        $combinations = $config.Combinations
        
        foreach ($testParams in $combinations) {
            $testNumber++
            $outputFile = Get-OutputFileName -EncoderConfig $encoder -TestParams $testParams
            $outputPath = Join-Path $workingDir $outputFile
            $paramString = Get-ParametersString -EncoderConfig $encoder -TestParams $testParams
            
            $percentComplete = [math]::Round(($testNumber / $totalTests) * 100, 1)
            Write-Log "[$testNumber/$totalTests] ($percentComplete%) $($encoder.DisplayName): $outputFile" -Severity Info
            
            # Check for existing file
            $baseName = [IO.Path]::GetFileNameWithoutExtension($outputFile)
            $existingFile = Get-ChildItem -LiteralPath $workingDir -Filter "${baseName}_*.mkv" -ErrorAction SilentlyContinue | Select-Object -First 1
            
            if ($existingFile -and -not $Force) {
                Write-Log "  Skipping (already exists): $($existingFile.Name)" -Severity Warning
                $encodedFiles.Add(@{
                        Path        = $existingFile.FullName
                        Name        = $existingFile.Name
                        Size        = (Get-Item -LiteralPath existingFile.FullName).Length
                        Encoder     = $encoder
                        TestParams  = $testParams
                        ParamString = $paramString
                        Status      = 'Skipped'
                        VMAF        = if ($existingFile.Name -match '\[(\d+\.?\d*)\]') { [double]$Matches[1] } else { $null }
                        SSIMU2      = $null
                    })
                continue
            }
            
            # Encode
            $timer = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $encodedFile = Invoke-EncoderProcess -EncoderConfig $encoder -TestParams $testParams `
                    -InputScript $serverScript -OutputFile $outputPath -ServerType $FrameServer -FrameCount $videoInfo.FrameCount
                
                $timer.Stop()
                
                $encodedFiles.Add(@{
                        Path         = $encodedFile
                        Name         = $outputFile
                        Size         = (Get-Item -LiteralPath $encodedFile).Length
                        Encoder      = $encoder
                        TestParams   = $testParams
                        ParamString  = $paramString
                        Status       = 'Success'
                        VMAF         = $null
                        SSIMU2       = $null
                        EncodingTime = $timer.Elapsed
                    })
                
                Write-Log "  Done: $([math]::Round((Get-Item -LiteralPath $encodedFile).Length / 1MB, 2)) MB, $([math]::Round($timer.Elapsed.TotalSeconds, 1))s" -Severity Success
            }
            catch {
                $timer.Stop()
                Write-Log "  Error: $_" -Severity Error
                $encodedFiles.Add(@{
                        Path         = $null
                        Name         = $outputFile
                        Size         = -1
                        Encoder      = $encoder
                        TestParams   = $testParams
                        ParamString  = $paramString
                        Status       = "Error: $_"
                        VMAF         = $null
                        SSIMU2       = $null
                        EncodingTime = $timer.Elapsed
                    })
            }
        }
    }
    
    # ============================================
    # PHASE 2: VMAF CALCULATION (Parallel)
    # ============================================
    Write-Log "`n" -Severity Info
    Write-Log "======================= PHASE 2: VMAF CALCULATION =======================" -Severity Success
    
    $successfulFiles = $encodedFiles | Where-Object { $_.Status -eq 'Success' -and $_.Path -and (Test-Path -LiteralPath $_.Path) }
    if ($successfulFiles.Count -eq 0) {
        Write-Log "No successful encodings to analyze" -Severity Warning
    }
    else {
        Write-Log "Calculating VMAF for $($successfulFiles.Count) files ($VmafThreads threads)..." -Severity Info
        $vmafModel = if ($videoInfo.ResolutionHeight -le 1080) { 'vmaf_v0.6.1' } else { 'vmaf_4k_v0.6.1' }
        $distortedPaths = $successfulFiles | ForEach-Object { $_.Path }
        
        try {
            Write-Log "Calculating VMAF metrics..." -Severity Info
            $vmafResults = Get-VideoQualityMetrics2 `
                -ReferencePath $(if ($CreateLosslessSample) {$losslesssamplefile} else {$serverScript}) `
                -DistortedPaths $distortedPaths `
                -Metrics 'VMAF' `
                -ModelVersion $vmafModel `
                -Subsample $Subsample `
                -Threads $VmafThreads `
                -Parallel

            if ($CreateLosslessSample) {
                Write-Log "Calculating SSIMULACRA2 metrics..." -Severity Info
                $ssimu2Results = Get-VideoQualityMetrics3 `
                    -ReferencePath $(if ($CreateLosslessSample) {$losslesssamplefile} else {$sampleFile}) `
                    -DistortedPaths $distortedPaths `
                    -Metrics SSIMULACRA2 `
                    -SSIMGPUThreads 2 `
                    -SSIMEvery 1 `
                    -Threads 2 `
                    -Debug -Verbose -Parallel:$false
                    # -Crop $CropParams
            } else {
                Write-Log "Пропускаем расчёт SSIMULACRA2, т.к. не используется lossless sample..." -Severity Info
            }
            # Build lookup dictionaries for efficient merging
            $vmafMap = @{}
            $vmafNegMap = @{}
            $ssimu2Map = @{}
            
            if ($vmafResults) {
                foreach ($res in $vmafResults) {
                    if ($res.DistortedPath -and $null -ne $res.VMAF) {
                        $vmafMap[$res.DistortedPath] = $res.VMAF
                    }
                }
            }
            if ($vmafNegResults) {
                foreach ($res in $vmafNegResults) {
                    if ($res.DistortedPath -and $null -ne $res.VMAFNeg) {
                        $vmafNegMap[$res.DistortedPath] = $res.VMAFNeg
                    }
                }
            }
            if ($ssimu2Results) {
                foreach ($res in $ssimu2Results) {
                    if ($res.DistortedPath -and $null -ne $res.SSIMULACRA2) {
                        $ssimu2Map[$res.DistortedPath] = $res.SSIMULACRA2
                    }
                }
            }

            # Apply metrics to successful encodings
            foreach ($file in $successfulFiles) {
                if ($vmafMap.ContainsKey($file.Path)) { $file.VMAF = $vmafMap[$file.Path] }
                if ($vmafNegMap.ContainsKey($file.Path)) { $file.VMAFNeg = $vmafNegMap[$file.Path] }
                if ($ssimu2Map.ContainsKey($file.Path)) { $file.SSIMULACRA2 = $ssimu2Map[$file.Path] }
            }
            
            Write-Log "Metrics calculation completed successfully." -Severity Success
        }
        catch {
            Write-Log "VMAF/SSIMULACRA2 calculation failed: $_" -Severity Error
            if ($_.ScriptStackTrace) { Write-Log $_.ScriptStackTrace -Severity Debug }
        }
    }
    
    # ============================================
    # Generate Report
    # ============================================
    Write-Log "`n" -Severity Info
    Write-Log "======================= RESULTS =======================" -Severity Success
    
    $reportData = [System.Collections.Generic.List[PSObject]]::new()
    $sampleFileSize = (Get-Item -LiteralPath $sampleFile).Length
    foreach ($file in $encodedFiles) {
        $fileInfo = $null
        if ($file.Path -and (Test-Path -LiteralPath $file.Path)) {
            try { $fileInfo = Get-VideoStats -VideoFilePath $file.Path -ErrorAction SilentlyContinue } catch { }
        }
        else { $null }
        
        $reportData += [PSCustomObject]@{
            FileName         = $file.Name
            Encoder          = $file.Encoder.DisplayName
            EncoderVersion   = Get-EncoderVersion $file.Encoder
            Parameters       = $file.ParamString
            EncodedSizeMB    = if ($fileInfo) { [math]::Round($fileInfo.VideoDataSizeBytes / 1MB, 3) } else { 0 }
            VMAF             = $file.VMAF
            SSIMU2           = $file.SSIMULACRA2?.Average
            EncodingTime     = if ($file.EncodingTime) { "{0:hh\:mm\:ss}" -f $file.EncodingTime } else { 'N/A' }
            EncodingFPS      = if ($file.EncodingTime -and $file.EncodingTime.TotalSeconds -gt 0) { 
                [math]::Round($videoInfo.FrameCount / $file.EncodingTime.TotalSeconds, 2) 
            }
            else { 0 }
            CompressionRatio = if ($fileInfo -and $fileInfo.VideoDataSizeBytes -gt 0) {
                [math]::Round($originalFileSize / $fileInfo.VideoDataSizeBytes, 2)
            }
            else { 0 }
            EstSize          = if ($fileInfo -and $sampleFileSize -gt 0) {
                [math]::Round($originalFileSize / $sampleFileSize * $fileInfo.VideoDataSizeBytes / 1MB, 2)
            }
            else { 0 }
            Status           = $file.Status
        }
    }
    
    # Save report
    $reportData | Export-Csv -LiteralPath $reportPath -UseQuotes AsNeeded -Delimiter "`t" -NoTypeInformation -Force -Append
    Write-Log "Report saved: $reportPath" -Severity Success
    
    # Display results
    $sortedResults = $reportData | Where-Object { $_.VMAF -and $_.VMAF -ne '' } | Sort-Object { [double]$_.VMAF } -Descending
    
    if ($sortedResults.Count -gt 0) {
        $sortedResults | Format-Table Encoder, Parameters,
        @{Name = 'VMAF'; Expression = { $_.VMAF } }, 
        @{Name = 'SSIMU2'; Expression = { $_.SSIMU2 } }, 
        @{Name = 'SizeMB'; Expression = { $_.EncodedSizeMB } }, 
        @{Name = 'FPS'; Expression = { $_.EncodingFPS } },
        EstSize,
        Status -AutoSize
    }
    else {
        Write-Log "No VMAF results available" -Severity Warning
        $reportData | Format-Table Encoder, Parameters, Status -AutoSize
    }
    
    Write-Log "Working directory: $workingDir" -Severity Success
    Write-Log "Total tests: $($reportData.Count)" -Severity Success
}
catch {
    Write-Log "Critical error: $_" -Severity Error
    Write-Log $_.ScriptStackTrace -Severity Debug
    exit 1
}
#endregion