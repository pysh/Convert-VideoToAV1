<#
.SYNOPSIS
    Вспомогательные функции для обработки видео
#>

$global:Config = $null
$global:VideoTools = $null

function Convert-FpsToDouble {
    <#
    .SYNOPSIS
        Конвертирует строковое представление FPS в число с плавающей точкой
    #>
    param ([string]$FpsString)

    if ($FpsString -match '^\d+/\d+$') {
        $numerator, $denominator = $FpsString -split '/'
        return [double]$numerator / [double]$denominator
    } elseif ($FpsString -match '^\d+(\.\d+)?$') {
        return [double]$FpsString
    } else {
        throw "Некорректный формат FPS: $FpsString"
    }
}

function Initialize-Configuration {
    <#
    .SYNOPSIS
        Инициализирует глобальную конфигурацию
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigPath)
    
    try {
        if (-not (Test-Path -Path $ConfigPath -PathType Leaf)) {
            throw "Файл конфигурации не найден"
        }
        $global:Config = Import-PowerShellDataFile -Path $ConfigPath
        $global:VideoTools = $global:Config.Tools
        Write-Log "Конфигурация успешно загружена" -Severity Success -Category 'Config'
    }
    catch {
        Write-Log "Ошибка загрузки конфигурации: $_" -Severity Error -Category 'Config'
        throw
    }
}

function Get-VideoFrameRate {
    <#
    .SYNOPSIS
        Получает частоту кадров видеофайла или скрипта
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VideoPath)
    
    try {
        $fps = $null
        
        # Проверяем расширение файла
        $extension = [System.IO.Path]::GetExtension($VideoPath).ToLower()
        
        switch ($extension) {
            '.vpy' {
                # Обработка VapourSynth скриптов
                $vspipeApp = if ($global:VideoTools.VSPipe) { $global:VideoTools.VSPipe } else { 'vspipe' }
                $vspipeArgs = @('-i', $VideoPath, '--info')
                $vspipeOutput = & $vspipeApp @vspipeArgs 2>&1
                
                $fpsLine = $vspipeOutput | Where-Object { $_ -match 'FPS:\s*([\d\/]+(?:\.\d+)?)' }
                if ($fpsLine) {
                    $fps = [regex]::Match($fpsLine, 'FPS:\s*([\d\/]+(?:\.\d+)?)').Groups[1].Value
                } else {
                    throw "Не удалось найти информацию о FPS в выводе vspipe"
                }
            }
            '.avs' {
                # Обработка AviSynth скриптов через ffprobe
                $ffprobeApp = if ($global:VideoTools.FFprobe) { $global:VideoTools.FFprobe } else { 'ffprobe' }
                $ffprobeArgs = @(
                    '-v', 'error',
                    '-f', 'avisynth',
                    '-select_streams', 'v:0',
                    '-show_entries', 'stream=r_frame_rate',
                    '-of', 'json',
                    $VideoPath
                )
                
                $ffprobeOutput = & $ffprobeApp @ffprobeArgs
                $fpsJson = $ffprobeOutput | ConvertFrom-Json
                if ($fpsJson.streams -and $fpsJson.streams[0].r_frame_rate) {
                    $fps = $fpsJson.streams[0].r_frame_rate
                } else {
                    throw "Не удалось получить FPS из AviSynth скрипта"
                }
            }
            default {
                # Обработка обычных видеофайлов через ffprobe
                $ffprobeApp = if ($global:VideoTools.FFprobe) { $global:VideoTools.FFprobe } else { 'ffprobe' }
                $ffprobeArgs = @(
                    '-v', 'error',
                    '-select_streams', 'v:0',
                    '-show_entries', 'stream=r_frame_rate',
                    '-of', 'json',
                    $VideoPath
                )
                
                $ffprobeOutput = & $ffprobeApp @ffprobeArgs
                $fpsJson = $ffprobeOutput | ConvertFrom-Json
                $fps = $fpsJson.streams[0].r_frame_rate
            }
        }
        
        # Общая логика обработки FPS
        if ($null -ne $fps) {
            return [double] [Math]::Round((Convert-FpsToDouble -Fps $fps), 2)
        } else {
            throw "Не удалось получить значение FPS"
        }
    }
    catch {
        Write-Log "Ошибка получения framerate: $_" -Severity Error -Category 'UtilModule'
        throw
    }
}

function ConvertTo-Seconds {
    <#
    .SYNOPSIS
        Конвертирует строку времени в секунды
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TimeString,
        [double]$FrameRate
    )
    
    try {
        if ($TimeString -match '^(\d+):(\d+):(\d+)(?:\.(\d+))?$') {
            $hours = [int]$Matches[1]
            $minutes = [int]$Matches[2]
            $seconds = [int]$Matches[3]
            $milliseconds = if ($Matches[4]) { [int]$Matches[4] } else { 0 }
            return $hours * 3600 + $minutes * 60 + $seconds + ($milliseconds / 1000)
        }
        elseif ($TimeString -match '^(\d+)(?:\.(\d+))?s$') {
            $seconds = [int]$Matches[1]
            $milliseconds = if ($Matches[2]) { [int]$Matches[2] } else { 0 }
            return $seconds + ($milliseconds / 1000)
        }
        
        throw "Неверный формат времени: $TimeString"
    }
    catch {
        Write-Log "Ошибка конвертации времени: $_" -Severity Error -Category 'Video'
        throw
    }
}

function Write-Log {
    <#
    .SYNOPSIS
        Записывает сообщение в лог с указанием уровня важности
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('Debug', 'Information', 'Warning', 'Error', 'Success', 'Verbose')]
        [string]$Severity = 'Information',
        [string]$Category,
        [switch]$NoNewLine
    )

    $timestamp = [DateTime]::Now.ToString("yyyy-MM-dd HH:mm:ss.fff")
    $logSeverity = switch ($Severity) {
        'Success' { 'OK!' }
        'Debug' { 'DBG' }
        'Information' { 'INF' }
        'Verbose' { 'VRB' }
        'Warning' { 'WRN' }
        'Error' { 'ERR' }
        default { '---' }
    }
    
    $color = switch ($Severity) {
        'Success' { 'Green' }
        'Debug' { 'DarkGray' }
        'Information' { 'Cyan' }
        'Verbose' { 'DarkYellow' }
        'Warning' { 'DarkMagenta' }
        'Error' { 'Red' }
        default { 'White' }
    }
    
    $logMessage = "[$timestamp] [$logSeverity]$(if($Category){ " [$Category]" })`t$Message"
    Write-Host $logMessage -ForegroundColor $color -NoNewline:$NoNewLine
}

function Get-VideoQualityMetrics {
    <#
    .SYNOPSIS
        Вычисляет метрики качества видео VMAF и XPSNR
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateScript({ $(($_ -match '\.(avs|vpy|mp4|mkv)$') -and (Test-Path -LiteralPath $_ -PathType Leaf)) })]
        [string]$DistortedPath,

        [Parameter(Mandatory = $true)]
        [ValidateScript({ $(($_ -match '\.(avs|vpy|mp4|mkv)$') -and (Test-Path -LiteralPath $_ -PathType Leaf)) })]
        [string]$ReferencePath,

        [ValidateSet('VMAF', 'XPSNR', 'Both')]
        [string]$Metrics = 'VMAF',

        [PSCustomObject]$Crop = @{
            Left          = 0
            Right         = 0
            Top           = 0
            Bottom        = 0
            CropDistVideo = $false
        },

        [ValidateRange(0, [int]::MaxValue)]
        [int]$TrimStartSeconds = 0,

        [ValidateRange(0, [int]::MaxValue)]
        [int]$DurationSeconds = 0,

        [string]$ModelVersion = 'vmaf_4k_v0.6.1',

        [ValidateRange(1, 64)]
        [int]$VMAFThreads = [Environment]::ProcessorCount,

        [ValidateRange(1, 100)]
        [int]$Subsample = 1,

        [string]$VMAFLogPath,

        [ValidateSet('mean', 'harmonic_mean')]
        [string]$VMAFPoolMethod = 'mean'
    )
    
    # Функция для определения типа файла
    function Get-FileType {
        param([string]$Path)
        $extension = [System.IO.Path]::GetExtension($Path).ToLower()
        switch ($extension) {
            '.vpy' { return 'VapourSynth' }
            '.avs' { return 'AviSynth' }
            default { return 'Video' }
        }
    }
    
    # Определяем типы файлов
    $distortedType = Get-FileType -Path $DistortedPath
    $referenceType = Get-FileType -Path $ReferencePath
    
    Write-Verbose "Distorted type: $distortedType, Reference type: $referenceType"

    # Получаем FPS для каждого файла
    $videoRefFrameRate = if ($referenceType -eq 'Video') {
        Get-VideoFrameRate -VideoPath $ReferencePath
    } else {
        Get-ScriptFrameRate -ScriptPath $ReferencePath -ScriptType $referenceType
    }

    $videoDistFrameRate = if ($distortedType -eq 'Video') {
        Get-VideoFrameRate -VideoPath $DistortedPath
    } else {
        Get-ScriptFrameRate -ScriptPath $DistortedPath -ScriptType $distortedType
    }
    
    # Базовые фильтры для временных меток
    $baseFilters = "settb=AVTB,setpts=PTS-STARTPTS,format=yuv420p"

    # Собираем фильтры обрезки
    $cropFilterReference = if ($Crop.Left -or $Crop.Right -or $Crop.Top -or $Crop.Bottom) {
        "crop=w=iw-$($Crop.Left)-$($Crop.Right):h=ih-$($Crop.Top)-$($Crop.Bottom):x=$($Crop.Left):y=$($Crop.Top)"
    }
    
    if ($Crop.CropDistVideo) { 
        $cropFilterDistortion = $cropFilterReference 
    }

    # Фильтры обрезки по времени
    $trimFilter = if ($TrimStartSeconds -gt 0 -or $DurationSeconds -gt 0) {
        "trim=start=${TrimStartSeconds}:duration=${DurationSeconds}"
    }

    # Комбинируем все фильтры
    $commonFilters = (@($trimFilter, $baseFilters) -join ',').Trim(',')

    # Результаты
    $results = @{
        VMAF  = $null
        XPSNR = $null
    }

    # Функция для формирования входных параметров в зависимости от типа файла
    function Get-InputArgs {
        param(
            [string]$Path,
            [string]$FileType, 
            [Parameter(Mandatory = $false)]
            [double]$FrameRate=25
        )
        
        $argsList = @()
        
        switch ($FileType) {
            'VapourSynth' {
                $argsList += '-f', 'vapoursynth'
                $argsList += '-r', ($FrameRate.ToString().Replace(',', '.'))
            }
            'AviSynth' {
                $argsList += '-f', 'avisynth'
                $argsList += '-r', ($FrameRate.ToString().Replace(',', '.'))
            }
            default {
                # Для видеофайлов тоже добавляем
                $argsList += '-r', ($FrameRate.ToString().Replace(',', '.'))
            }
        }
        
        $argsList += '-i', $Path
        return $argsList
    }

    # Общий фильтр для обоих потоков
    $filterChain = @(
        "[0:v]$(if($cropFilterDistortion) { "${cropFilterDistortion}," })$commonFilters[dist];",
        "[1:v]$(if($cropFilterReference) { "${cropFilterReference}," })$commonFilters[ref];"
    ) -join ''

    # Расчет VMAF
    if ($Metrics -in ('Both', 'VMAF')) {
        $vmafParams = @(
            "eof_action=endall",
            "n_threads=$VMAFThreads",
            "n_subsample=$Subsample",
            "model=version=$ModelVersion",
            "pool=$VMAFPoolMethod"
        )
        
        if ($VMAFLogPath) {
            $vmafParams += "log_path='$($VMAFLogPath.Replace('\', '\\'))'"
            $vmafParams += "log_fmt=json"
        }

        $vmafFilter = "[dist][ref]libvmaf=$($vmafParams -join ':')"
        
        # Формируем аргументы FFmpeg
        $ffmpegArgs = @(
            "-hide_banner", "-y"
            # "-nostats"
        )
        
        # Добавляем параметры для искаженного видео
        $ffmpegArgs += Get-InputArgs -Path $DistortedPath -FileType $distortedType -FrameRate $videoDistFrameRate
        
        # Добавляем параметры для эталонного видео
        $ffmpegArgs += Get-InputArgs -Path $ReferencePath -FileType $referenceType -FrameRate $videoRefFrameRate
        
        # Добавляем фильтры и выход
        $ffmpegArgs += @(
            "-filter_complex", "${filterChain}${vmafFilter}",
            "-f", "null", "-"
        )

        Write-Host "Calculating VMAF: ffmpeg $($ffmpegArgs -join ' ')" -ForegroundColor Gray
        $timerVMAF = [System.Diagnostics.Stopwatch]::StartNew()
        $output = & ffmpeg $ffmpegArgs 2>&1
        $timerVMAF.Stop()

        if ($output -join '`n' -match [regex]'(?m).*VMAF score: (?<vmaf>\d+\.+\d+).*') {
            $results.VMAF = [double]$Matches.vmaf
            Write-Verbose "VMAF calculation successful: $($results.VMAF)"
        }
        else {
            Write-Warning "VMAF calculation failed. Output: $($output -join "`n")"
            # Попробуем найти VMAF в другом формате вывода
            if ($output -join '`n' -match [regex]'VMAF score:\s*(\d+\.\d+)') {
                $results.VMAF = [double]$Matches[1]
                Write-Verbose "VMAF found (alternative pattern): $($results.VMAF)"
            }
            else {
                $results.VMAF = $null
            }
        }
    }

    # Расчет XPSNR
    if ($Metrics -in ('Both', 'XPSNR')) {
        $xpsnrFilter = "[dist][ref]xpsnr=eof_action=endall"
        
        # Формируем аргументы FFmpeg
        $ffmpegArgs = @(
            "-hide_banner", "-y", "-nostats"
        )
        
        # Добавляем параметры для искаженного видео
        $ffmpegArgs += Get-InputArgs -Path $DistortedPath -FileType $distortedType -FrameRate $videoDistFrameRate
        
        # Добавляем параметры для эталонного видео
        $ffmpegArgs += Get-InputArgs -Path $ReferencePath -FileType $referenceType -FrameRate $videoRefFrameRate
        
        # Добавляем фильтры и выход
        $ffmpegArgs += @(
            "-filter_complex", "${filterChain}${xpsnrFilter}",
            "-f", "null", "-"
        )

        Write-Verbose "Calculating XPSNR: ffmpeg $($ffmpegArgs -join ' ')"
        $timerXPSNR = [System.Diagnostics.Stopwatch]::StartNew()
        $output = & ffmpeg $ffmpegArgs 2>&1
        $timerXPSNR.Stop()

        # Ищем XPSNR в разных форматах вывода
        $xpsnrFound = $false
        
        # Формат 1: "XPSNR... y: XX.XX u: XX.XX v: XX.XX"
        if ($output -join '`n' -match [regex]'(?m)XPSNR.*y:\s*(?<y>\d+\.\d+).*u:\s*(?<u>\d+\.\d+).*v:\s*(?<v>\d+\.\d+)') {
            $results.XPSNR = @{
                Y    = [double]$Matches['y']
                U    = [double]$Matches['u']
                V    = [double]$Matches['v']
                MIN  = (([double]$Matches['y'], [double]$Matches['u'], [double]$Matches['v']) | Measure-Object -Minimum).Minimum
                AVG  = ([double]$Matches['y'] + [double]$Matches['u'] + [double]$Matches['v']) / 3
                WSUM = (4 * [double]$Matches['y'] + [double]$Matches['u'] + [double]$Matches['v']) / 6
            }
            $xpsnrFound = $true
            Write-Verbose "XPSNR calculation successful (pattern 1)"
        }
        # Формат 2: "PSNR y:XX.XX u:XX.XX v:XX.XX *"
        elseif ($output -join '`n' -match [regex]'(?m)PSNR.*y:\s*(?<y>\d+\.\d+).*u:\s*(?<u>\d+\.\d+).*v:\s*(?<v>\d+\.\d+)') {
            $results.XPSNR = @{
                Y    = [double]$Matches['y']
                U    = [double]$Matches['u']
                V    = [double]$Matches['v']
                MIN  = (([double]$Matches['y'], [double]$Matches['u'], [double]$Matches['v']) | Measure-Object -Minimum).Minimum
                AVG  = ([double]$Matches['y'] + [double]$Matches['u'] + [double]$Matches['v']) / 3
                WSUM = (4 * [double]$Matches['y'] + [double]$Matches['u'] + [double]$Matches['v']) / 6
            }
            $xpsnrFound = $true
            Write-Verbose "XPSNR calculation successful (pattern 2)"
        }
        
        if (-not $xpsnrFound) {
            Write-Warning "XPSNR calculation failed. Output: $($output -join "`n")"
            $results.XPSNR = $null
        }
    }

    # Добавляем информацию о параметрах
    $results['Parameters'] = @{
        DistortedType = $distortedType
        ReferenceType = $referenceType
        DistortedFPS  = $videoDistFrameRate
        ReferenceFPS  = $videoRefFrameRate
        Crop          = $Crop
        TimeRange     = if ($DurationSeconds -gt 0) {
            "$TrimStartSeconds-$($TrimStartSeconds+$DurationSeconds)s"
        }
        else { "Full duration" }
        ModelVersion  = $ModelVersion
        VMAFTimer     = $timerVMAF
        XPSNRTimer    = $timerXPSNR
    }
    
    return [PSCustomObject]$results
}

function Get-VideoScriptInfo {
    <#
    .SYNOPSIS
        Получает информацию о VapourSynth скрипте
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory)][string]$ScriptPath)
    
    try {
        $vspInfo = (& vspipe --info $ScriptPath 2>&1)
        
        if ($LASTEXITCODE -ne 0) {
            throw "Ошибка выполнения vspipe: $vspInfo"
        }

        $infoHash = @{}
        $vspInfo | ForEach-Object {
            if ($_ -match '^(?<name>.*?):\s*(?<value>.*)$') {
                $infoHash[$Matches.name] = $Matches.value
            }
        }

        return [PSCustomObject]$infoHash
    }
    catch {
        Write-Log "Ошибка при получении информации о скрипте VapourSynth: $_" -Severity Error -Category 'Video'
        throw
    }
}

function Get-VideoCropParameters {
    <#
    .SYNOPSIS
        Определяет параметры обрезки черных полей видео
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$InputFile,
        [Parameter(Mandatory = $false)]
        [string]$CacheFile = [string][IO.Path]::ChangeExtension($InputFile, '.lwi')
    )
    
    function RoundToNearestMultiple {
        param([int]$Value, [int]$Multiple)
        if ($Multiple -eq 0) { return $Value }
        return [Math]::Round($Value / $Multiple) * $Multiple
    }

    try {
        # $tmpScriptFile = [IO.Path]::ChangeExtension([IO.Path]::GetTempFileName(), 'vpy')
        $tmpScriptFile = [IO.Path]::ChangeExtension($InputFile, '_autocrop.vpy')
        $templatePath = $global:Config.Templates.VapourSynth.AutoCrop
        
        # Получаем абсолютный путь к шаблону
        $scriptDir = Split-Path -Parent $PSScriptRoot
        $templateFullPath = if (Test-Path -LiteralPath (Join-Path $scriptDir $templatePath) -PathType Leaf) {
            Join-Path $scriptDir $templatePath
        } else {
            'd:\PSScripts\Convert-VideoToAV1\Templates\AutoCropTemplate.py'
        }
        
        if (-not (Test-Path -LiteralPath $templateFullPath -PathType Leaf)) {
            throw "Файл шаблона VapourSynth не найден: $templateFullPath"
        }

        $scriptContent = Get-Content -LiteralPath $templateFullPath -Raw
        $scriptContent = $scriptContent -replace '\{input_file\}', $InputFile
        $scriptContent = $scriptContent -replace '\{cache_file\}', $CacheFile
        Set-Content -LiteralPath $tmpScriptFile -Value $scriptContent -Force

        $AutoCropPath = $global:VideoTools.AutoCrop
        $autocropOutput = & $AutoCropPath $tmpScriptFile 2 400 144 144 $global:Config.Processing.AutoCropThreshold 0
        
        if ($LASTEXITCODE -ne 0) {
            throw "Ошибка выполнения AutoCrop (код $LASTEXITCODE)"
        }
        
        $cropLine = $autocropOutput | Select-Object -Last 1
        $cropParams = $cropLine -split ',' | ForEach-Object { [int]$_ }

        return [PSCustomObject]@{
            Left   = RoundToNearestMultiple -Value $cropParams[0] -Multiple $global:Config.Encoding.Video.CropRound
            Top    = RoundToNearestMultiple -Value $cropParams[1] -Multiple $global:Config.Encoding.Video.CropRound
            Right  = RoundToNearestMultiple -Value $cropParams[2] -Multiple $global:Config.Encoding.Video.CropRound
            Bottom = RoundToNearestMultiple -Value $cropParams[3] -Multiple $global:Config.Encoding.Video.CropRound
        }
    }
    catch {
        Write-Log "Ошибка при определении параметров обрезки: $_" -Severity Error -Category 'Video'
        throw
    }
    finally {
        if (Test-Path -LiteralPath $tmpScriptFile) {
            Remove-Item -LiteralPath $tmpScriptFile -ErrorAction SilentlyContinue
        }
    }
}

function Get-SafeFileName {
    <#
    .SYNOPSIS
        Очищает имя файла от недопустимых символов
    #>
    [CmdletBinding()]
    param([string]$FileName)
    
    if ([string]::IsNullOrWhiteSpace($FileName)) { return [string]::Empty }
    foreach ($char in [IO.Path]::GetInvalidFileNameChars()) {
        $FileName = $FileName.Replace($char, '_')
    }
    return $FileName
}

function Get-EncoderPath {
    <#
    .SYNOPSIS
        Получает путь к исполняемому файлу энкодера
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$EncoderName)
    
    try {
        # Получаем базовое имя энкодера
        $baseEncoder = $EncoderName -split '\.' | Select-Object -First 1
        
        if (-not $global:Config.Encoding.AvailableEncoders.ContainsKey($baseEncoder)) {
            throw "Энкодер '$baseEncoder' не найден в AvailableEncoders"
        }
        
        $encoderPathRef = $global:Config.Encoding.AvailableEncoders[$baseEncoder]
        $pathParts = $encoderPathRef -split '\.'
        
        $current = $global:Config
        foreach ($part in $pathParts) {
            $current = $current[$part]
        }
        
        if (-not (Test-Path -LiteralPath $current -PathType Leaf)) {
            throw "Файл энкодера не найден: $current"
        }
        
        return $current
    }
    catch {
        Write-Log "Ошибка получения пути к энкодеру '$EncoderName': $_" -Severity Error -Category 'Config'
        throw
    }
}

function Get-EncoderConfig {
    <#
    .SYNOPSIS
        Получает конфигурацию для указанного энкодера
    .DESCRIPTION
        Поддерживает форматы: 'encoder' или 'encoder.preset'
        Примеры: 'x265', 'x265.film_grain', 'SvtAv1EncESS.grain_optimized'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$EncoderName
    )
    
    try {
        # Разбираем имя энкодера (может быть 'encoder.preset')
        $encoderParts = $EncoderName -split '\.'
        $baseEncoder = $encoderParts[0]
        $presetName = if ($encoderParts.Count -gt 1) { $encoderParts[1] } else { 'main' }
        
        # Проверяем наличие энкодера в пресетах
        if (-not $global:Config.Encoding.Video.EncoderPresets.ContainsKey($baseEncoder)) {
            throw "Энкодер '$baseEncoder' не найден в конфигурации пресетов"
        }
        
        $encoderPresets = $global:Config.Encoding.Video.EncoderPresets[$baseEncoder]
        
        # Получаем пресет
        if (-not $encoderPresets.ContainsKey($presetName)) {
            # Если указанного пресета нет, берем первый доступный
            $availablePresets = $encoderPresets.Keys
            if ($availablePresets.Count -eq 0) {
                throw "Нет доступных пресетов для энкодера '$baseEncoder'"
            }
            $presetName = $availablePresets[0]
            Write-Log "Пресет '$presetName' не найден, используется '$presetName'" `
                -Severity Warning -Category 'Config'
        }
        
        $presetConfig = $encoderPresets[$presetName].Clone()
        
        # Добавляем информацию о пресете
        $presetConfig['PresetName'] = $presetName
        $presetConfig['BaseEncoder'] = $baseEncoder
        $presetConfig['FullEncoderName'] = $EncoderName
        
        return $presetConfig
    }
    catch {
        Write-Log "Ошибка получения конфигурации энкодера '$EncoderName': $_" `
            -Severity Error -Category 'Config'
        throw
    }
}

function Get-EncoderCode {
    <#
    .SYNOPSIS
        Получает короткий код энкодера для использования в именах файлов
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$EncoderName
    )
    
    try {
        # Сначала проверяем, есть ли код в EncoderCodes
        if ($global:Config.Encoding.EncoderCodes.ContainsKey($EncoderName)) {
            return $global:Config.Encoding.EncoderCodes[$EncoderName]
        }
        
        # Если нет, получаем конфиг и проверяем там
        $encoderConfig = Get-EncoderConfig -EncoderName $EncoderName -ErrorAction SilentlyContinue
        
        if ($encoderConfig -and $encoderConfig.CodecCode) {
            return $encoderConfig.CodecCode
        }
        
        # Определяем код по имени энкодера
        $baseEncoder = $EncoderName -split '\.' | Select-Object -First 1
        
        switch -Wildcard ($baseEncoder) {
            '*265*'   { 'hevc' }
            '*av1*'   { 'av1' }
            '*av1enc*'{ 'av1' }
            '*vp9*'   { 'vp9' }
            '*h264*'  { 'h264' }
            default   { 'enc' }  # fallback
        }
    }
    catch {
        Write-Log "Не удалось определить код энкодера '$EncoderName': $_" `
            -Severity Warning -Category 'Config'
        return 'enc'
    }
}

function Get-EncoderParams {
    <#
    .SYNOPSIS
        Формирует параметры командной строки для энкодера
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EncoderName,
        [hashtable]$EncoderConfig
    )
    
    $baseParams = @()
    
    if ($EncoderConfig.BaseArgs) {
        $baseParams += $EncoderConfig.BaseArgs
    }
    
    # Определяем базовое имя энкодера для свитча
    $baseEncoderName = $EncoderConfig.BaseEncoder ?? ($EncoderName -split '\.' | Select-Object -First 1)

    # Добавляем специфичные параметры для каждого энкодера
    switch ($baseEncoderName) {
        "x265" {
            $baseParams += @('--crf', $EncoderConfig.Quality)
            $baseParams += @('--preset', $EncoderConfig.Preset)
        }
        "SvtAv1Enc" {
            $baseParams += @('--crf', $EncoderConfig.Quality)
            $baseParams += @('--preset', $EncoderConfig.Preset)
        }
        "SvtAv1EncTritium" {
            $baseParams += @('--crf', $EncoderConfig.Quality)
            $baseParams += @('--preset', $EncoderConfig.Preset)
        }
        "SvtAv1EncESS" {
            if ($EncoderConfig.Quality -and (-not ([string]::IsNullOrWhiteSpace($EncoderConfig.Quality)))) {
                $baseParams += @('--quality', $EncoderConfig.Quality)
            }
            if ($EncoderConfig.Speed -and (-not ([string]::IsNullOrWhiteSpace($EncoderConfig.Speed)))) {
                $baseParams += @('--speed', $EncoderConfig.Speed)
            }
        }
        "SvtAv1EncHDR" {
            $baseParams += @('--crf', $EncoderConfig.Quality)
            $baseParams += @('--preset', $EncoderConfig.Preset)
        }
        "SvtAv1EncPSYEX" {
            $baseParams += @('--crf', $EncoderConfig.Quality)
            $baseParams += @('--preset', $EncoderConfig.Preset)
        }
        "Rav1eEnc" {
            $baseParams += @('--quantizer', $EncoderConfig.Quality)
            $baseParams += @('--speed', $EncoderConfig.Speed)
        }
        "AomAv1Enc" {
            $baseParams += @('--cq-level', $EncoderConfig.Quality)
            $baseParams += @('--cpu-used', $EncoderConfig.CpuUsed)
        }
        default {
            Write-Log "Неизвестный базовый энкодер: $baseEncoderName" -Severity Warning -Category 'Config'
        }
    }
    
    # Добавляем дополнительные параметры
    if ($global:Config.Encoding.Video.XtraParams) {
        $baseParams += $global:Config.Encoding.Video.XtraParams
    }
    return $baseParams
}

function Test-EncoderPreset {
    <#
    .SYNOPSIS
        Проверяет доступность и конфигурацию энкодера/пресета
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$EncoderName,
        
        [switch]$VerboseInfo
    )
    
    try {
        # Разбираем имя энкодера
        $encoderParts = $EncoderName -split '\.'
        $baseEncoder = $encoderParts[0]
        $presetName = if ($encoderParts.Count -gt 1) { $encoderParts[1] } else { 'main' }
        
        $result = @{
            EncoderName = $EncoderName
            BaseEncoder = $baseEncoder
            PresetName = $presetName
            IsAvailable = $false
            HasConfig = $false
            Config = $null
        }
        
        # Проверяем наличие базового энкодера
        if ($global:Config.Encoding.Video.EncoderPresets.ContainsKey($baseEncoder)) {
            $encoderPresets = $global:Config.Encoding.Video.EncoderPresets[$baseEncoder]
            $result.IsAvailable = $true
            
            # Проверяем наличие пресета
            if ($encoderPresets.ContainsKey($presetName)) {
                $result.HasConfig = $true
                $result.Config = $encoderPresets[$presetName]
            }
        }
        
        if ($VerboseInfo) {
            Write-Log "Проверка энкодера '$EncoderName':" -Severity Information
            Write-Log "  Базовый энкодер: $($result.BaseEncoder)" -Severity Information
            Write-Log "  Пресет: $($result.PresetName)" -Severity Information
            Write-Log "  Доступен: $($result.IsAvailable)" -Severity Information
            Write-Log "  Есть конфиг: $($result.HasConfig)" -Severity Information
            if ($result.Config) {
                Write-Log "  DisplayName: $($result.Config.DisplayName)" -Severity Information
                Write-Log "  CodecCode: $($result.Config.CodecCode)" -Severity Information
            }
        }
        
        return [PSCustomObject]$result
    }
    catch {
        Write-Log "Ошибка проверки энкодера: $_" -Severity Error
        throw
    }
}

function Get-AvailableEncoders {
    <#
    .SYNOPSIS
        Возвращает список всех доступных энкодеров и пресетов
    .EXAMPLE
        Get-AvailableEncoders
    .EXAMPLE
        Get-AvailableEncoders -Format "Display"
    #>
    [CmdletBinding()]
    param(
        [ValidateSet("Simple", "Display", "Full")]
        [string]$Format = "Simple"
    )
    
    $result = @()
    
    foreach ($encoderKey in $global:Config.Encoding.Video.EncoderPresets.Keys) {
        $encoderPresets = $global:Config.Encoding.Video.EncoderPresets[$encoderKey]
        
        foreach ($presetKey in $encoderPresets.Keys) {
            $preset = $encoderPresets[$presetKey]
            
            switch ($Format) {
                "Simple" {
                    $result += "${encoderKey}.${presetKey}"
                }
                "Display" {
                    $displayName = $preset.DisplayName ?? $presetKey
                    $result += [PSCustomObject]@{
                        FullName = "${encoderKey}.${presetKey}"
                        DisplayName = $displayName
                        Encoder = $encoderKey
                        Preset = $presetKey
                    }
                }
                "Full" {
                    $result += [PSCustomObject]@{
                        FullName = "${encoderKey}.${presetKey}"
                        Encoder = $encoderKey
                        Preset = $presetKey
                        Config = $preset
                    }
                }
            }
        }
    }
    
    return $result
}

function Get-VideoStats {
    <#
    .SYNOPSIS
        Вычисляет статистику видеофайла
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [string]$VideoFilePath
    )
    
    try {
        $videoFile = Get-Item -LiteralPath $VideoFilePath -ErrorAction Stop
        
        # Get all video stream info in one ffprobe call
        $streamMetadata = & ffprobe -v error -select_streams v:0 `
            -show_entries stream `
            -show_entries format=size `
            -of json "$VideoFilePath" | ConvertFrom-Json -AsHashtable
        
        # Calculate FPS from ratio
        $framesPerSecond = if ($streamMetadata.streams[0].r_frame_rate -match '(\d+)/(\d+)') {
            [math]::Round([decimal]$matches[1] / [decimal]$matches[2], 3)
        }
        else {
            [decimal]$streamMetadata.streams[0].r_frame_rate
        }

        # Get detailed packet info in separate call
        $packetMetadata = & ffprobe -v error -select_streams v:0 `
            -count_packets -show_entries packet=dts_time,pts_time,size,flags `
            -of json "$VideoFilePath" | ConvertFrom-Json -AsHashtable
        
        # Calculate frame counts from different sources
        $frameCountFromPackets = $packetMetadata.packets.Count
        $frameCountFromStream = [int]$streamMetadata.streams[0].nb_read_packets
        $frameCountFromNbFrames = if ($streamMetadata.streams[0].nb_frames) {
            [int]$streamMetadata.streams[0].nb_frames
        }
        else {
            $frameCountFromPackets
        }

        # Calculate duration and bitrate from packets
        $durationFromPackets = $videoBitrate = $videoDataSize = 0
        if ($packetMetadata.packets -and $packetMetadata.packets.Count -gt 0) {
            $firstPacketTime = [double]$packetMetadata.packets[0].pts_time
            $lastPacketTime = [double]($packetMetadata.packets | Measure-Object -Property pts_time -Maximum).Maximum
            $durationFromPackets = $lastPacketTime - $firstPacketTime
            $videoDataSize = ($packetMetadata.packets | Measure-Object -Property size -Sum).Sum
            
            if ($durationFromPackets -gt 0) {
                $videoBitrate = [math]::Round(($videoDataSize * 8) / $durationFromPackets / 1Kb, 2)
            }
        }

        # Calculate duration from different sources
        $durationFromFrames = if ($frameCountFromNbFrames -gt 0) {
            [math]::Round($frameCountFromNbFrames / $framesPerSecond, 3)
        }
        else {
            [math]::Round($frameCountFromPackets / $framesPerSecond, 3)
        }

        $durationFromMetadata = if ($streamMetadata.streams[0].duration) {
            [math]::Round([double]$streamMetadata.streams[0].duration, 3)
        }
        else {
            $durationFromFrames
        }
        
        # Build result object
        return [PSCustomObject]@{
            FilePath            = $VideoFilePath
            FileName            = $videoFile.Name
            FileSizeBytes       = $videoFile.Length
            VideoDataSizeBytes  = $videoDataSize
            VideoCodecName      = $streamMetadata.streams[0].codec_name
            ResolutionWidth     = [int]$streamMetadata.streams[0].width
            ResolutionHeight    = [int]$streamMetadata.streams[0].height
            FrameRate           = $framesPerSecond
            FrameRateNum        = [int]($streamMetadata.streams[0].r_frame_rate -split '/')[0]
            FrameRateDen        = [int]($streamMetadata.streams[0].r_frame_rate -split '/')[1]
            FrameCount          = $frameCountFromNbFrames
            FrameCountPackets   = $frameCountFromPackets
            FrameCountStream    = $frameCountFromStream
            DurationSeconds     = $durationFromMetadata
            DurationFromFrames  = $durationFromFrames
            DurationFromPackets = [math]::Round($durationFromPackets, 3)
            FormattedDuration   = "{0:hh\:mm\:ss}" -f [timespan]::fromseconds($durationFromMetadata)
            BitrateKbps         = $videoBitrate
            PixelFormat         = $streamMetadata.streams[0].pix_fmt
            BitDepth            = $streamMetadata.streams[0].bits_per_raw_sample
            StreamMetadata      = $streamMetadata.streams[0]
            PacketMetadata      = $packetMetadata
        }
    }
    catch {
        Write-Error "Error processing video file '$VideoFilePath': $_"
        throw
    }
}

function Copy-VideoFragments {
    <#
    .SYNOPSIS
        Извлекает фрагменты из MKV видео файла
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [string]$InputFile,
        
        [Parameter(Mandatory = $true)]
        [string]$OutputFile,
        
        [ValidateRange(1, 255)]
        [int]$FragmentCount = 10,
        
        [ValidateRange(1, 600)]
        [int]$FragmentDuration = 12,
        
        [ValidateRange(0, [int]::MaxValue)]
        [double]$SkipStartSeconds = 180,
        
        [ValidateRange(0, [int]::MaxValue)]
        [double]$SkipEndSeconds = 180,
        
        [bool]$KeepAudio = $false,
        [bool]$KeepSubtitles = $false,
        [bool]$KeepAttachments = $false,
        
        [bool]$KeepGlobalTags = $false,
        [bool]$KeepChapters = $false
    )

    # Check for mkvmerge
    if (-not (Get-Command mkvmerge -ErrorAction SilentlyContinue)) {
        throw "mkvmerge is required (install MKVToolNix)"
    }

    # Normalize paths
    $InputFile = (Get-Item -LiteralPath $InputFile).FullName
    $OutputFile = [System.IO.Path]::GetFullPath($OutputFile)

    # Get duration
    try {
        $ffprobeResult = & ffprobe -v error -show_entries format=duration -of csv=p=0 -i $InputFile 2>&1
        $totalDuration = [double]($ffprobeResult | Select-Object -Last 1)
    }
    catch {
        throw "Failed to get duration: $_`r`nffprobe output: $ffprobeResult"
    }

    # Validate skip parameters
    if ($SkipStartSeconds + $SkipEndSeconds -ge $totalDuration) {
        throw "Sum of SkipStartSeconds and SkipEndSeconds ($($SkipStartSeconds + $SkipEndSeconds)) is greater than total duration ($totalDuration)"
    }

    # Calculate available duration
    $availableDuration = $totalDuration - $SkipStartSeconds - $SkipEndSeconds

    # Validate fragment duration
    if ($availableDuration -le $FragmentDuration) {
        throw "Available duration ($availableDuration sec) is less than fragment duration ($FragmentDuration sec)"
    }

    # Calculate uniform time ranges (HH:MM:SS.ss format)
    $step = ($availableDuration - $FragmentDuration) / ($FragmentCount - 1)
    $timeParts = foreach ($i in 0..($FragmentCount - 1)) {
        $start = $SkipStartSeconds + [math]::Min($i * $step, $availableDuration - $FragmentDuration)
        $startTime = [TimeSpan]::FromSeconds($start)
        $endTime = [TimeSpan]::FromSeconds($start + $FragmentDuration)
        "$($startTime.ToString('hh\:mm\:ss\.ff'))-$($endTime.ToString('hh\:mm\:ss\.ff'))"
    }
    
    # Join parts with ',+' separator
    $timeRanges = $timeParts -join ',+'

    # Prepare mkvmerge arguments
    $mkvMergeArgs = @(
        "--ui-language", "en",
        "--priority", "lower",
        "--output", $OutputFile,
        "--split", "parts:$timeRanges"
    )
    
    # Add optional parameters
    if (-not $KeepGlobalTags) { $mkvMergeArgs += "--no-global-tags" }
    if (-not $KeepChapters) { $mkvMergeArgs += "--no-chapters" }
    
    # Add stream selection parameters
    if (-not $KeepAudio) { $mkvMergeArgs += "--no-audio" }
    if (-not $KeepSubtitles) { $mkvMergeArgs += "--no-subtitles" }
    if (-not $KeepAttachments) { $mkvMergeArgs += "--no-attachments" }
    
    # Add input file
    $mkvMergeArgs += $InputFile

    # Execute single mkvmerge command
    try {
        Write-Progress -Activity "Processing" -Status "Extracting $FragmentCount fragments"
        
        Write-Verbose "Executing: mkvmerge $($mkvMergeArgs -join ' ')"
        
        & mkvmerge @mkvMergeArgs 2>&1 | Out-Null
        
        if ($LASTEXITCODE -ne 0) {
            throw "mkvmerge failed with exit code $LASTEXITCODE"
        }

        if (-not (Test-Path -LiteralPath $OutputFile)) {
            throw "Output file was not created"
        }

        [PSCustomObject]@{
            OutputFile = $OutputFile
            TimeRanges = $timeParts
            Command    = "mkvmerge $($mkvMergeArgs -join ' ')"
            Parameters = @{
                FragmentCount     = $FragmentCount
                FragmentDuration  = $FragmentDuration
                TotalDuration     = $totalDuration
                AvailableDuration = $availableDuration
                SkipStartSeconds  = $SkipStartSeconds
                SkipEndSeconds    = $SkipEndSeconds
            }
        }
    }
    catch {
        Write-Error "Error: $_"
        if (Test-Path -LiteralPath $OutputFile) {
            Remove-Item -LiteralPath $OutputFile -Force
        }
        throw
    }
    finally {
        Write-Progress -Completed -Activity "Done"
    }
}

# Вспомогательные функции для Get-VideoQualityMetrics
function Get-ScriptFrameRate {
    param([string]$ScriptPath, [string]$ScriptType)
    
    try {
        if ($ScriptType -eq 'VapourSynth') {
            $vspipeApp = if ($global:VideoTools.VSPipe) { $global:VideoTools.VSPipe } else { 'vspipe' }
            $vspipeArgs = @('-i', $ScriptPath, '--info')
            $vspipeOutput = & $vspipeApp @vspipeArgs 2>&1
            
            $fpsLine = $vspipeOutput | Where-Object { $_ -match 'FPS:\s*([\d\/]+(?:\.\d+)?)' }
            if ($fpsLine) {
                $fps = [regex]::Match($fpsLine, 'FPS:\s*([\d\/]+(?:\.\d+)?)').Groups[1].Value
                return [double] [Math]::Round((Convert-FpsToDouble -FpsString $fps), 2)
            }
        }
        elseif ($ScriptType -eq 'AviSynth') {
            # Для AviSynth используем FFmpeg для получения FPS
            $ffprobeApp = if ($global:VideoTools.FFprobe) { $global:VideoTools.FFprobe } else { 'ffprobe' }
            $ffprobeArgs = @(
                '-v', 'error',
                '-f', 'avisynth',
                '-i', $ScriptPath,
                '-show_entries', 'stream=r_frame_rate',
                '-of', 'json'
            )
            
            $ffprobeOutput = & $ffprobeApp @ffprobeArgs
            $fpsJson = $ffprobeOutput | ConvertFrom-Json
            if ($fpsJson.streams -and $fpsJson.streams[0].r_frame_rate) {
                $fps = $fpsJson.streams[0].r_frame_rate
                return [double] [Math]::Round((Convert-FpsToDouble -FpsString $fps), 2)
            }
        }
    }
    catch {
        Write-Verbose "Не удалось получить FPS из скрипта ${ScriptPath}: $_"
    }
    
    # Возвращаем значение по умолчанию
    return 25.0
}

# Онлайн-перевод
function Invoke-MyMemoryTranslate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,
        [string]$SourceLang = "ru",
        [string]$TargetLang = "en"
    )

    $url = "https://api.mymemory.translated.net/get?q=$([System.Web.HttpUtility]::UrlEncode($Text))&langpair=$SourceLang|$TargetLang"
    
    try {
        $response = Invoke-RestMethod -Uri $url -Method Get
        return $response.responseData.translatedText
    }
    catch {
        Write-Error "Ошибка перевода: $_"
        return $null
    }
}

function Invoke-LibreTranslate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,
        [string]$SourceLang = "ru",
        [string]$TargetLang = "en"
    )

    # Русские публичные серверы
    $servers = @(
        "https://translate.terraprint.co",
        "https://libretranslate.opensourcestack.com"
    )

    $body = @{
        q      = $Text
        source = $SourceLang
        target = $TargetLang
    } | ConvertTo-Json

    foreach ($server in $servers) {
        try {
            $url = "$server/translate"
            $response = Invoke-RestMethod -Uri $url -Method Post -Body $body -ContentType "application/json"
            if ($response.translatedText) {
                return $response.translatedText
            }
        }
        catch {
            Write-Warning "Сервер $server недоступен"
            continue
        }
    }
    
    Write-Error "Все серверы недоступны"
    return $null
}

function Invoke-GoogleTranslate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,
        [string]$SourceLang = "auto",
        [string]$TargetLang = "en"
    )

    # Используем альтернативный endpoint
    $url = "https://translate.googleapis.com/translate_a/single?client=dict-chrome-ex&sl=$SourceLang&tl=$TargetLang&dt=t&q=$([System.Web.HttpUtility]::UrlEncode($Text))"
    
    try {
        $response = Invoke-RestMethod -Uri $url -Method Get -Headers @{
            "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        }
        return ($response[0] | ForEach-Object { $_[0] }) -join ""
    }
    catch {
        Write-Error "Ошибка перевода Google: $_"
        return $null
    }
}

function Invoke-FreeTranslate {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,
        [string]$SourceLang = "ru",
        [string]$TargetLang = "en"
    )

    Write-Host "Пробуем MyMemory..." -ForegroundColor Yellow
    $result = Invoke-MyMemoryTranslate -Text $Text -SourceLang $SourceLang -TargetLang $TargetLang
    if ($result) { return $result }

    Write-Host "Пробуем LibreTranslate..." -ForegroundColor Yellow
    $result = Invoke-LibreTranslate -Text $Text -SourceLang $SourceLang -TargetLang $TargetLang
    if ($result) { return $result }

    Write-Host "Пробуем Google Translate..." -ForegroundColor Yellow
    $result = Invoke-GoogleTranslate -Text $Text -SourceLang $SourceLang -TargetLang $TargetLang
    if ($result) { return $result }

    Write-Error "Все переводчики недоступны"
    return $null
}

function Convert-MP4ChaptersToXML {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Json')]
        [PSObject]$ChaptersJson,
        
        [Parameter(Mandatory, ParameterSetName = 'File')]
        [string]$InputFile,
        
        [Parameter(Mandatory)]
        [string]$OutputFile
    )
    
    $chapters = if ($PSCmdlet.ParameterSetName -eq 'Json') {
        $ChaptersJson.chapters
    } else {
        $content = Get-Content $InputFile -Raw
        if ($content -match '\[CHAPTER\]') {
            # Парсинг ffmetadata формата
            $result = @()
            $blocks = $content -split '\[CHAPTER\]'
            foreach ($block in $blocks) {
                if ($block -match 'START=(\d+)' -and $block -match 'END=(\d+)') {
                    $startTick = [int64]$Matches[1]
                    $endTick = [int64]$Matches[2]
                    if ($block -match 'TIMEBASE=(\d+)\/(\d+)') {
                        $tbNum = [int64]$Matches[1]
                        $tbDen = [int64]$Matches[2]
                        $startTime = $startTick / ($tbDen / $tbNum)
                        $endTime = $endTick / ($tbDen / $tbNum)
                    } else {
                        $startTime = $startTick / 1000
                        $endTime = $endTick / 1000
                    }
                    $title = if ($block -match 'title=(.+)') { $Matches[1] } else { "Chapter $($result.Count+1)" }
                    $result += @{ start_time = $startTime; end_time = $endTime; title = $title }
                }
            }
            $result
        }
    }
    
    if (-not $chapters -or $chapters.Count -eq 0) {
        Write-Log "No chapters found" -Severity Warning -Category 'Utils'
        return $false
    }
    
    $settings = [System.Xml.XmlWriterSettings]@{
        Indent = $true
        Encoding = [System.Text.Encoding]::UTF8
        ConformanceLevel = [System.Xml.ConformanceLevel]::Document
    }
    
    $writer = [System.Xml.XmlWriter]::Create($OutputFile, $settings)
    
    $writer.WriteStartDocument()
    $writer.WriteStartElement('Chapters')
    $writer.WriteStartElement('EditionEntry')
    $writer.WriteAttributeString('EditionUID', [System.Guid]::NewGuid().ToString())
    
    $counter = 1
    foreach ($chapter in $chapters) {
        $startTime = [TimeSpan]::FromSeconds([double]$chapter.start_time).ToString('hh\:mm\:ss\.fff')
        $endTime = [TimeSpan]::FromSeconds([double]$chapter.end_time).ToString('hh\:mm\:ss\.fff')
        $title = $chapter.title ?? "Chapter $counter"
        
        $writer.WriteStartElement('ChapterAtom')
        $writer.WriteElementString('ChapterUID', [System.Guid]::NewGuid().ToString())
        $writer.WriteElementString('ChapterTimeStart', $startTime)
        $writer.WriteElementString('ChapterTimeEnd', $endTime)
        $writer.WriteElementString('ChapterFlagHidden', '0')
        $writer.WriteElementString('ChapterFlagEnabled', '1')
        
        $writer.WriteStartElement('ChapterDisplay')
        $writer.WriteElementString('ChapterString', $title)
        $writer.WriteElementString('ChapterLanguage', 'eng')
        $writer.WriteEndElement()
        
        $writer.WriteEndElement()
        $counter++
    }
    
    $writer.WriteEndElement()
    $writer.WriteEndElement()
    $writer.WriteEndDocument()
    $writer.Close()
    
    Write-Log "Chapters converted to XML: $($chapters.Count)" -Severity Success -Category 'Utils'
    return $true
}

<# 
function Convert-MP4ChaptersToXML {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ParameterSetName = 'File')]
        [string]$InputFile,
        
        [Parameter(Mandatory, ParameterSetName = 'Json')]
        [PSObject]$ChaptersJson,
        
        [Parameter(Mandatory)]
        [string]$OutputFile
    )
    
    try {
        $chapters = $null
        
        if ($PSCmdlet.ParameterSetName -eq 'File') {
            # Читаем из файла ffmetadata
            if (-not (Test-Path -LiteralPath $InputFile)) {
                throw "Файл не найден: $InputFile"
            }
            
            $content = Get-Content -LiteralPath $InputFile -Raw -ErrorAction Stop
            
            if ($content -match '\[CHAPTER\]') {
                $chapters = @()
                $blocks = $content -split '\[CHAPTER\]'
                
                foreach ($block in $blocks) {
                    if ($block -match 'TIMEBASE=(\d+)\/(\d+)' -and 
                        $block -match 'START=(\d+)' -and 
                        $block -match 'END=(\d+)') {
                        
                        $timebaseNum = [int64]$Matches[1]
                        $timebaseDen = [int64]$Matches[2]
                        $startTick = [int64]$Matches[3]
                        $endTick = [int64]$Matches[4]
                        
                        $startTime = $startTick / ($timebaseDen / $timebaseNum)
                        $endTime = $endTick / ($timebaseDen / $timebaseNum)
                        
                        $title = if ($block -match 'title=(.+)') { 
                            $Matches[1].Trim() 
                        } else { 
                            "Chapter $($chapters.Count + 1)" 
                        }
                        
                        $chapters += @{
                            start_time = $startTime
                            end_time = $endTime
                            title = $title
                        }
                    }
                }
            }
        }
        else {
            # Используем JSON из ffprobe
            if (-not $ChaptersJson -or -not $ChaptersJson.chapters) {
                throw "Некорректный JSON с главами"
            }
            $chapters = $ChaptersJson.chapters
        }
        
        if (-not $chapters -or $chapters.Count -eq 0) {
            Write-Log "Не найдено глав для конвертации" -Severity Verbose -Category 'Utils'
            return $false
        }
        
        # Создаем XML для mkvmerge
        $settings = [System.Xml.XmlWriterSettings]@{
            Indent = $true
            Encoding = [System.Text.Encoding]::UTF8
            ConformanceLevel = [System.Xml.ConformanceLevel]::Document
        }
        
        $writer = [System.Xml.XmlWriter]::Create($OutputFile, $settings)
        
        try {
            $writer.WriteStartDocument()
            $writer.WriteStartElement("Chapters")
            $writer.WriteStartElement("EditionEntry")
            $writer.WriteAttributeString("EditionUID", [System.Guid]::NewGuid().ToString())
            
            $chapterCounter = 1
            foreach ($chapter in $chapters) {
                $startTime = [TimeSpan]::FromSeconds([double]$chapter.start_time).ToString("hh\:mm\:ss\.fff")
                $endTime = [TimeSpan]::FromSeconds([double]$chapter.end_time).ToString("hh\:mm\:ss\.fff")
                
                $chapterTitle = if ($chapter.title) { $chapter.title } else { "Chapter $chapterCounter" }
                $chapterUID = [System.Guid]::NewGuid().ToString()
                
                $writer.WriteStartElement("ChapterAtom")
                $writer.WriteElementString("ChapterUID", $chapterUID)
                $writer.WriteElementString("ChapterTimeStart", $startTime)
                $writer.WriteElementString("ChapterTimeEnd", $endTime)
                $writer.WriteElementString("ChapterFlagHidden", "0")
                $writer.WriteElementString("ChapterFlagEnabled", "1")
                
                $writer.WriteStartElement("ChapterDisplay")
                $writer.WriteElementString("ChapterString", $chapterTitle)
                $writer.WriteElementString("ChapterLanguage", "eng")
                $writer.WriteEndElement()
                
                $writer.WriteEndElement()
                $chapterCounter++
            }
            
            $writer.WriteEndElement()
            $writer.WriteEndElement()
            $writer.WriteEndDocument()
            
            Write-Log "XML глав создан: $OutputFile ($($chapters.Count) глав)" -Severity Success -Category 'Utils'
            return $true
        }
        finally {
            $writer.Close()
        }
    }
    catch {
        Write-Log "Ошибка конвертации глав в XML: $_" -Severity Warning -Category 'Utils'
        return $false
    }
}
#>
function Convert-MP4TagsToXml {
    [CmdletBinding()]
    param([hashtable]$Tags, [string]$OutputFile)
    
    $settings = [System.Xml.XmlWriterSettings]@{
        Indent = $true
        Encoding = [System.Text.Encoding]::UTF8
    }
    
    $writer = [System.Xml.XmlWriter]::Create($OutputFile, $settings)
    
    $mapping = @{
        'title' = 'TITLE'
        'artist' = 'ARTIST'
        'album' = 'ALBUM'
        'date' = 'DATE_RELEASED'
        'comment' = 'COMMENT'
        'genre' = 'GENRE'
        'encoder' = 'ENCODER'
    }
    
    $writer.WriteStartDocument()
    $writer.WriteStartElement('Tags')
    $writer.WriteStartElement('Tag')
    $writer.WriteStartElement('Targets')
    $writer.WriteElementString('TargetTypeValue', '50')
    $writer.WriteEndElement()
    
    foreach ($key in $Tags.Keys) {
        $value = $Tags[$key]
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        
        $tagName = if ($mapping.ContainsKey($key.ToLower())) { $mapping[$key.ToLower()] } else { $key.ToUpper() }
        
        $writer.WriteStartElement('Simple')
        $writer.WriteElementString('Name', $tagName)
        $writer.WriteElementString('String', $value)
        $writer.WriteEndElement()
    }
    
    $writer.WriteEndElement()
    $writer.WriteEndElement()
    $writer.WriteEndDocument()
    $writer.Close()
}

# Экспорт функций
Export-ModuleMember -Function `
    Initialize-Configuration, `
    Write-Log, `
    Get-VideoFrameRate, `
    ConvertTo-Seconds, `
    Get-SafeFileName, `
    Get-EncoderPath, `
    Get-EncoderParams, `
    Get-EncoderConfig, `
    Get-EncoderCode, `
    Test-EncoderPreset, `
    Get-AvailableEncoders, `
    Get-VideoQualityMetrics, `
    Get-VideoScriptInfo, `
    Get-VideoCropParameters, `
    Convert-FpsToDouble, `
    Copy-VideoFragments, `
    Get-VideoStats, `
    Get-VideoAutoCropParams, `
    Invoke-FreeTranslate, `
    Convert-MP4ChaptersToXML, `
    Get-ScriptFrameRate, 
    Convert-MP4TagsToXml,
    Convert-VideoToAV1