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
        if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
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
        $vspInfo = (& vspipe --info $ScriptPath) # 2>&1)
        
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
        
        if (-not $global:Config.AvailableEncoders.ContainsKey($baseEncoder)) {
            throw "Энкодер '$baseEncoder' не найден в AvailableEncoders"
        }
        
        $encoderPathRef = $global:Config.AvailableEncoders[$baseEncoder]
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
        if ($global:Config.EncoderCodes.ContainsKey($EncoderName)) {
            return $global:Config.EncoderCodes[$EncoderName]
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
        Write-Log "Получение статистики видеофайла: $($videoFile.FullName)" -Severity Information -Category 'Video'
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

# function Convert-ChaptersToXML {
#     [CmdletBinding()]
#     param(
#         [Parameter(Mandatory, ParameterSetName = 'Json')]
#         [PSObject]$ChaptersJson,
        
#         [Parameter(Mandatory, ParameterSetName = 'File')]
#         [string]$InputFile,
        
#         [Parameter(Mandatory)]
#         [string]$OutputFile
#     )
    
#     $chapters = if ($PSCmdlet.ParameterSetName -eq 'Json') {
#         $ChaptersJson.chapters
#     } else {
#         $content = Get-Content -LiteralPath $InputFile -Raw
#         if ($content -match '\[CHAPTER\]') {
#             $result = @()
#             $blocks = $content -split '\[CHAPTER\]'
#             foreach ($block in $blocks) {
#                 if ($block -match 'START=(\d+)' -and $block -match 'END=(\d+)') {
#                     $startTick = [int64]$Matches[1]
#                     $endTick = [int64]$Matches[2]
#                     if ($block -match 'TIMEBASE=(\d+)\/(\d+)') {
#                         $tbNum = [int64]$Matches[1]
#                         $tbDen = [int64]$Matches[2]
#                         $startTime = $startTick / ($tbDen / $tbNum)
#                         $endTime = $endTick / ($tbDen / $tbNum)
#                     } else {
#                         $startTime = $startTick / 1000
#                         $endTime = $endTick / 1000
#                     }
#                     $title = if ($block -match 'title=(.+)') { $Matches[1].Trim() } else { "Chapter $($result.Count+1)" }
#                     $result += @{ start_time = $startTime; end_time = $endTime; title = $title }
#                 }
#             }
#             $result
#         }
#     }
    
#     if (-not $chapters -or $chapters.Count -eq 0) {
#         Write-Log "No chapters found" -Severity Warning -Category 'Utils'
#         return $false
#     }
    
#     $settings = [System.Xml.XmlWriterSettings]@{
#         Indent = $true
#         Encoding = [System.Text.Encoding]::UTF8
#         ConformanceLevel = [System.Xml.ConformanceLevel]::Document
#     }
    
#     $writer = [System.Xml.XmlWriter]::Create($OutputFile, $settings)
    
#     $writer.WriteStartDocument()
#     $writer.WriteStartElement('Chapters')
#     $writer.WriteStartElement('EditionEntry')
    
#     $counter = 1
#     foreach ($chapter in $chapters) {
#         $startTime = [TimeSpan]::FromSeconds([double]$chapter.start_time).ToString('hh\:mm\:ss\.fff')
#         $endTime = [TimeSpan]::FromSeconds([double]$chapter.end_time).ToString('hh\:mm\:ss\.fff')
        
#         # Универсальное получение названия главы
#         $chapterTitle = $null
        
#         # Пробуем разные варианты в зависимости от источника данных
#         if ($chapter.tags -and $chapter.tags.title) {
#             # MP4 формат (ffprobe)
#             $chapterTitle = $chapter.tags.title
#         }
#         elseif ($chapter.properties -and $chapter.properties.title) {
#             # MKV формат (mkvmerge)
#             $chapterTitle = $chapter.properties.title
#         }
#         elseif ($chapter.title) {
#             # Прямое свойство title
#             $chapterTitle = $chapter.title
#         }
        
#         # Если название не найдено, используем дефолтное
#         if ([string]::IsNullOrWhiteSpace($chapterTitle)) {
#             $chapterTitle = "Chapter $counter"
#         }
        
#         $writer.WriteStartElement('ChapterAtom')
#         $writer.WriteElementString('ChapterTimeStart', $startTime)
#         $writer.WriteElementString('ChapterTimeEnd', $endTime)
#         $writer.WriteElementString('ChapterFlagHidden', '0')
#         $writer.WriteElementString('ChapterFlagEnabled', '1')
        
#         $writer.WriteStartElement('ChapterDisplay')
#         $writer.WriteElementString('ChapterString', $chapterTitle)
#         $writer.WriteElementString('ChapterLanguage', 'eng')
#         $writer.WriteEndElement()
        
#         $writer.WriteEndElement()
#         $counter++
#     }
    
#     $writer.WriteEndElement() # EditionEntry
#     $writer.WriteEndElement() # Chapters
#     $writer.WriteEndDocument()
#     $writer.Close()
    
#     Write-Log "Chapters converted to XML: $($chapters.Count) chapters" -Severity Success -Category 'Utils'
#     return $true
# }

function Convert-MP4TagsToXml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [PSObject]$Tags,
        
        [Parameter(Mandatory)]
        [string]$OutputFile
    )
    
    # Преобразуем PSObject в Hashtable
    $tagsHash = @{}
    
    if ($Tags -is [hashtable]) {
        $tagsHash = $Tags
    } 
    elseif ($Tags -is [PSCustomObject] -or $Tags -is [PSObject]) {
        foreach ($prop in $Tags.PSObject.Properties) {
            $value = $prop.Value
            if ($value -is [string]) {
                $tagsHash[$prop.Name] = $value
            } elseif ($value) {
                $tagsHash[$prop.Name] = $value.ToString()
            }
        }
    }
    else {
        Write-Log "Invalid tags type: $($Tags.GetType())" -Severity Warning -Category 'Utils'
        return $false
    }
    
    if ($tagsHash.Count -eq 0) {
        Write-Log "No valid tags to convert" -Severity Verbose -Category 'Utils'
        return $false
    }

    # Настройки XML
    $settings = [System.Xml.XmlWriterSettings]@{
        Indent = $true
        Encoding = [System.Text.Encoding]::UTF8
        OmitXmlDeclaration = $false
    }
    
    # Маппинг тегов
    $mapping = @{
        'title' = 'TITLE'
        'artist' = 'ARTIST'
        'album' = 'ALBUM'
        'date' = 'DATE_RELEASED'
        'year' = 'DATE_RELEASED'
        'comment' = 'COMMENT'
        'genre' = 'GENRE'
        'encoder' = 'ENCODER'
        'copyright' = 'COPYRIGHT'
        'description' = 'DESCRIPTION'
        'synopsis' = 'SUMMARY'
        'show' = 'SHOWTITLE'
        'episode_id' = 'PART_NUMBER'
        'season_number' = 'SEASON_NUMBER'
        'episode_number' = 'PART_NUMBER'
    }
    
    # Теги для исключения (регистронезависимый поиск)
    $excludeTags = @('MAJOR_BRAND', 'COMPATIBLE_BRANDS', 'CREATION_TIME', 'MINOR_VERSION', 'ENCODER') | ForEach-Object { $_.ToLower() }
    try {
        $writer = [System.Xml.XmlWriter]::Create($OutputFile, $settings)

        $writer.WriteStartDocument()
        $writer.WriteStartElement('Tags')
        $writer.WriteStartElement('Tag')
        $writer.WriteStartElement('Targets')
        $writer.WriteElementString('TargetTypeValue', '50')
        $writer.WriteEndElement()
        
        foreach ($key in $tagsHash.Keys) {
            $lowerKey = $key.ToLower()

            # Пропускаем исключённые теги
            if ($lowerKey -in $excludeTags) { continue }

            $value = $tagsHash[$key]
            if ([string]::IsNullOrWhiteSpace($value)) { continue }

            # Определяем имя тега
            $tagName = if ($mapping.ContainsKey($lowerKey)) {
                $mapping[$lowerKey]
            } else {
                $key.ToUpper()
            }

            $writer.WriteStartElement('Simple')
            $writer.WriteElementString('Name', $tagName)
            $writer.WriteElementString('String', [System.Security.SecurityElement]::Escape($value))
            $writer.WriteEndElement()
        }
        $writer.WriteEndElement()
        $writer.WriteEndElement()
        $writer.WriteEndDocument()
        $writer.Close()

        Write-Log "Tags converted to XML: $OutputFile" -Severity Verbose -Category 'Utils'
        return $true
    }
    catch {
        Write-Log "Error converting tags to XML: $_" -Severity Error -Category 'Utils'
        return $false
    }
}

function Get-VideoQualityMetrics2 {
<#
.SYNOPSIS
    Calculates VMAF and XPSNR quality metrics for video files with parallel processing.
.EXAMPLE
    Get-VideoQualityMetrics -DistortedPaths @("enc1.mkv", "enc2.mkv") -ReferencePath "source.mkv" -Parallel
.EXAMPLE
    Get-VideoQualityMetrics -DistortedPaths "encoded.mkv" -ReferencePath "source.vpy"
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$DistortedPaths,
        
        [Parameter(Mandatory)]
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

        [int]$TrimStartSeconds = 0,
        [int]$DurationSeconds = 0,

        [string]$ModelVersion = 'vmaf_4k_v0.6.1',

        [int]$Threads = [Environment]::ProcessorCount,
        [int]$Subsample = 1,

        [string]$LogPath,

        [ValidateSet('mean', 'harmonic_mean')]
        [string]$PoolMethod = 'mean',
        
        [switch]$Parallel=$true
    )
    
    # Validate files
    if (-not (Test-Path -LiteralPath $ReferencePath)) {
        throw "Reference file not found: $ReferencePath"
    }
    foreach ($file in $DistortedPaths) {
        if (-not (Test-Path -LiteralPath $file)) {
            throw "File not found: $file"
        }
    }
    
    # Helper function to detect file type
    function Get-FileType {
        param([string]$Path)
        $ext = [IO.Path]::GetExtension($Path).ToLower()
        if ($ext -eq '.vpy') { return 'VapourSynth' }
        if ($ext -eq '.avs') { return 'AviSynth' }
        return 'Video'
    }

    # Helper function to convert frame rate to double
    function Convert-FpsToDouble {
        <#
        .SYNOPSIS
            Конвертирует строковое представление FPS в число с плавающей точкой
        #>
        param ([string]$FpsString)

        if ($FpsString -match '^\d+/\d+$') {
            $numerator, $denominator = $FpsString -split '/'
            return [double]$numerator / [double]$denominator
        }
        elseif ($FpsString -match '^\d+(\.\d+)?$') {
            return [double]$FpsString
        }
        else {
            throw "Некорректный формат FPS: $FpsString"
        }
    }    

    # Helper function to get frame rate
    function Get-FrameRate {
        param([string]$Path, [string]$FileType)
        
        try {
            if ($FileType -eq 'VapourSynth') {
                $output = & vspipe -i $Path --info 2>&1
                $fpsLine = $output | Where-Object { $_ -match 'FPS:\s*([\d\/]+(?:\.\d+)?)' }
                if ($fpsLine) {
                    $fps = [regex]::Match($fpsLine, 'FPS:\s*([\d\/]+(?:\.\d+)?)').Groups[1].Value
                    return [double][Math]::Round((Convert-FpsToDouble -FpsString $fps), 3)
                }
            }
            elseif ($FileType -eq 'AviSynth') {
                $ffprobe = (Get-Command ffprobe -ErrorAction Stop).Source
                $output = & $ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 $Path 2>&1
                if ($LASTEXITCODE -eq 0 -and $output) {
                    $fps = $output.Trim()
                    if ($fps -match '(\d+)/(\d+)') {
                        return [math]::Round([double]$Matches[1] / [double]$Matches[2], 3)
                    }
                    return [double]$fps
                }
            }
            else {
                $ffprobe = (Get-Command ffprobe -ErrorAction Stop).Source
                $output = & $ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 $Path 2>&1
                if ($LASTEXITCODE -eq 0 -and $output) {
                    $fps = $output.Trim()
                    if ($fps -match '(\d+)/(\d+)') {
                        return [math]::Round([double]$Matches[1] / [double]$Matches[2], 3)
                    }
                    return [double]$fps
                }
            }
        }
        catch {}
        return 25.0  # Default fallback
    }
    
    # Detect file types and get frame rates
    $refType = Get-FileType -Path $ReferencePath
    $refFPS = Get-FrameRate -Path $ReferencePath -FileType $refType
    
    $distInfo = @{}
    foreach ($path in $DistortedPaths) {
        $type = Get-FileType -Path $path
        $fps = Get-FrameRate -Path $path -FileType $type
        $distInfo[$path] = @{ Type = $type; FPS = $fps }
    }
    
    # Build filters (once for all videos)
    $cropFilter = ''
    if ($Crop.Left -or $Crop.Right -or $Crop.Top -or $Crop.Bottom) {
        $cropFilter = "crop=w=iw-$($Crop.Left)-$($Crop.Right):h=ih-$($Crop.Top)-$($Crop.Bottom):x=$($Crop.Left):y=$($Crop.Top)"
    }
    
    $trimFilter = ''
    if ($TrimStartSeconds -gt 0 -or $DurationSeconds -gt 0) {
        $trimFilter = if ($DurationSeconds -gt 0) {
            "trim=start=${TrimStartSeconds}:duration=$DurationSeconds"
        }
        else {
            "trim=start=$TrimStartSeconds"
        }
    }
    
    $baseFilter = "settb=AVTB,setpts=PTS-STARTPTS,format=yuv420p"
    $commonFilters = @($trimFilter, $baseFilter) -ne '' -join ','
    
    # Build distorted video filters
    $distFilters = @()
    if ($Crop.CropDistVideo -and $cropFilter) { $distFilters += $cropFilter }
    if ($commonFilters) { $distFilters += $commonFilters }
    $distFilterStr = $distFilters -join ','

    # Build reference video filters
    $refFilters = @()
    if ($cropFilter) { $refFilters += $cropFilter }
    if ($commonFilters) { $refFilters += $commonFilters }
    $refFilterStr = $refFilters -join ','

    $filterTemplate = "[0:v]${distFilterStr}[dist];[1:v]${refFilterStr}[ref];"
    
    # Build VMAF filter
    $vmafParams = @(
        "eof_action=endall",
        "n_threads=$Threads",
        "n_subsample=$Subsample",
        "model=version=$ModelVersion",
        "pool=$PoolMethod"
    )
    if ($LogPath) {
        $vmafParams += "log_path='$($LogPath.Replace('\', '\\'))'"
        $vmafParams += "log_fmt=json"
    }
    $vmafFilter = "[dist][ref]libvmaf=$($vmafParams -join ':')"
    $xpsnrFilter = "[dist][ref]xpsnr=eof_action=endall"
    
    # Header
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "  VIDEO QUALITY METRICS" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Reference: $([IO.Path]::GetFileName($ReferencePath))" -ForegroundColor White
    Write-Host "Reference Type: $refType, FPS: $refFPS" -ForegroundColor Gray
    Write-Host "Files: $($DistortedPaths.Count)" -ForegroundColor White
    Write-Host "Metrics: $Metrics" -ForegroundColor White
    Write-Host "Threads: $(if ($Parallel) { $Threads } else { 'Sequential' })" -ForegroundColor White
    Write-Host "========================================" -ForegroundColor Cyan
    
    # Get ffmpeg path
    $ffmpeg = (Get-Command ffmpeg -ErrorAction Stop).Source
    
    # Prepare job list
    $jobs = @{}
    $counter = 0
    foreach ($path in $DistortedPaths) {
        $counter++
        $jobs["job_$counter"] = @{
            Id             = $counter
            Total          = $DistortedPaths.Count
            DistortedPath  = $path
            DistortedType  = $distInfo[$path].Type
            DistortedFPS   = $distInfo[$path].FPS
            ReferencePath  = $ReferencePath
            ReferenceType  = $refType
            ReferenceFPS   = $refFPS
            FilterTemplate = $filterTemplate
            VmafFilter     = $vmafFilter
            XpsnrFilter    = $xpsnrFilter
            Metrics        = $Metrics
            FFmpegPath     = $ffmpeg
        }
    }
    
    # Process videos
    # $results = if ($Parallel -and $DistortedPaths.Count -gt 1) {
    #     Write-Host "Processing $($DistortedPaths.Count) videos in parallel..." -ForegroundColor Cyan
        
        $jobResults = $jobs.GetEnumerator() | ForEach-Object -Parallel {
            $jobName = $_.Key
            $job = $_.Value
            
            $ffmpeg = $job.FFmpegPath
            
            Write-Host "[$($job.Id)/$($job.Total)] Processing: $([IO.Path]::GetFileName($job.DistortedPath))" -ForegroundColor Yellow
            
            $result = [PSCustomObject]@{ 
                ReferencePath = $job.ReferencePath
                DistortedPath = $job.DistortedPath
                VMAF          = $null
                VMAFTimer     = $null
                VMAFffargs    = $null
                XPSNR         = $null
                XPSNRTimer    = $null
                XPSNRffargs   = $null
                job           = $job
            }
            
            # Build input arguments with proper FPS for each file
            $distArgs = @()
            $distArgs += '-r', ($job.DistortedFPS.ToString().Replace(',', '.'))
            if ($job.DistortedType -eq 'VapourSynth') {
                $distArgs += '-f', 'vapoursynth'
            }
            elseif ($job.DistortedType -eq 'AviSynth') {
                $distArgs += '-f', 'avisynth'
            }
            $distArgs += '-i', $job.DistortedPath
            
            $refArgs = @()
            $refArgs += '-r', ($job.ReferenceFPS.ToString().Replace(',', '.'))
            if ($job.ReferenceType -eq 'VapourSynth') {
                $refArgs += '-f', 'vapoursynth'
            }
            elseif ($job.ReferenceType -eq 'AviSynth') {
                $refArgs += '-f', 'avisynth'
            }
            $refArgs += '-i', $job.ReferencePath
            
            if ($job.Metrics -in ('Both', 'VMAF')) {
                $ffargs = @(
                    "-hide_banner", "-y", "-nostats" #, "-loglevel", "error"
                ) + $distArgs + $refArgs + @(
                    "-filter_complex", "$($job.FilterTemplate)$($job.VmafFilter)"
                    "-f", "null", "-"
                )
                $result.VMAFffargs = $ffargs
                $VMAFTimer = [System.Diagnostics.Stopwatch]::StartNew()
                $output = & $ffmpeg $ffargs 2>&1
                $VMAFTimer.Stop()
                $result.VMAFTimer = $VMAFTimer
                if ($output -join '`n' -match [regex]'(?m).*VMAF score: (?<vmaf>\d+\.+\d+).*') {
                    $result.VMAF = [double]$Matches.vmaf
                    Write-Host "VMAF calculation successful: $($result.VMAF)" -ForegroundColor DarkYellow
                }
                else {
                    Write-Warning "VMAF calculation failed. Output: $($output -join "`n")"
                    # Попробуем найти VMAF в другом формате вывода
                    if ($output -join '`n' -match [regex]'VMAF score:\s*(\d+\.\d+)') {
                        $result.VMAF = [double]$Matches[1]
                        Write-Host "VMAF found (alternative pattern): $($result.VMAF)" -ForegroundColor DarkYellow
                    }
                    else {
                        $result.VMAF = $null
                    }
                }
            }
            
            if ($job.Metrics -in ('Both', 'XPSNR')) {
                $ffargs = @(
                    "-hide_banner", "-y", "-nostats" #, "-loglevel", "error"
                ) + $distArgs + $refArgs + @(
                    "-filter_complex", "$($job.FilterTemplate)$($job.XpsnrFilter)"
                    "-f", "null", "-"
                )
                $XPSNRTimer = [System.Diagnostics.Stopwatch]::StartNew()
                $output = & $ffmpeg $ffargs 2>&1
                $XPSNRTimer.Stop()
                $result.XPSNRTimer = $XPSNRTimer

                # Ищем XPSNR в разных форматах вывода
                # Формат 1: "XPSNR... y: XX.XX u: XX.XX v: XX.XX"
                if ($output -join '`n' -match [regex]'(?m)XPSNR.*y:\s*(?<y>\d+\.\d+).*u:\s*(?<u>\d+\.\d+).*v:\s*(?<v>\d+\.\d+)') {
                    $result.XPSNR = @{
                        Y    = [double]$Matches['y']
                        U    = [double]$Matches['u']
                        V    = [double]$Matches['v']
                        MIN  = (([double]$Matches['y'], [double]$Matches['u'], [double]$Matches['v']) | Measure-Object -Minimum).Minimum
                        AVG  = ([double]$Matches['y'] + [double]$Matches['u'] + [double]$Matches['v']) / 3
                        WSUM = (4 * [double]$Matches['y'] + [double]$Matches['u'] + [double]$Matches['v']) / 6
                    }
                    Write-Verbose "XPSNR calculation successful"
                }
                # # Формат 2: "PSNR y:XX.XX u:XX.XX v:XX.XX *"
                # elseif ($output -join '`n' -match [regex]'(?m)PSNR.*y:\s*(?<y>\d+\.\d+).*u:\s*(?<u>\d+\.\d+).*v:\s*(?<v>\d+\.\d+)') {
                #     $result.XPSNR = @{
                #         Y    = [double]$Matches['y']
                #         U    = [double]$Matches['u']
                #         V    = [double]$Matches['v']
                #         MIN  = (([double]$Matches['y'], [double]$Matches['u'], [double]$Matches['v']) | Measure-Object -Minimum).Minimum
                #         AVG  = ([double]$Matches['y'] + [double]$Matches['u'] + [double]$Matches['v']) / 3
                #         WSUM = (4 * [double]$Matches['y'] + [double]$Matches['u'] + [double]$Matches['v']) / 6
                #     }
                #     Write-Verbose "XPSNR calculation successful (pattern 2)"
                # }
            }
            Write-Host ""
            return $result
        } -ThrottleLimit ([Math]::Min($DistortedPaths.Count, $Threads))
        
        # Конвертируем результаты в массив
        $results = @($jobResults)
    # }
    # else {
    #     $results = @()
    #     $counter = 0
        
    #     foreach ($path in $DistortedPaths) {
    #         $counter++
    #         Write-Progress -Activity "Calculating metrics" `
    #             -Status "[$counter/$($DistortedPaths.Count)] $([IO.Path]::GetFileName($path))" `
    #             -PercentComplete (($counter / $DistortedPaths.Count) * 100) -Id 1
            
    #         Write-Host "[$counter/$($DistortedPaths.Count)] Processing: $([IO.Path]::GetFileName($path))" -ForegroundColor Yellow
            
    #         $result = [PSCustomObject]@{ 
    #             Path  = $path
    #             VMAF  = $null
    #             XPSNR = $null
    #         }
            
    #         $distType = $distInfo[$path].Type
    #         $distFPS = $distInfo[$path].FPS
            
    #         # Build input arguments
    #         $distArgs = @()
    #         $distArgs += '-r', ($distFPS.ToString().Replace(',', '.'))
    #         if ($distType -eq 'VapourSynth') {
    #             $distArgs += '-f', 'vapoursynth'
    #         }
    #         elseif ($distType -eq 'AviSynth') {
    #             $distArgs += '-f', 'avisynth'
    #         }
    #         $distArgs += '-i', $path
            
    #         $refArgs = @()
    #         $refArgs += '-r', ($refFPS.ToString().Replace(',', '.'))
    #         if ($refType -eq 'VapourSynth') {
    #             $refArgs += '-f', 'vapoursynth'
    #         }
    #         elseif ($refType -eq 'AviSynth') {
    #             $refArgs += '-f', 'avisynth'
    #         }
    #         $refArgs += '-i', $ReferencePath
            
    #         if ($Metrics -in ('Both', 'VMAF')) {
    #             Write-Host "  Calculating VMAF..." -ForegroundColor Gray -NoNewline
    #             $ffargs = @(
    #                 "-hide_banner", "-y", "-nostats" #, "-loglevel", "error"
    #             ) + $distArgs + $refArgs + @(
    #                 "-filter_complex", "$filterTemplate$vmafFilter"
    #                 "-f", "null", "-"
    #             )
    #             $output = & $ffmpeg $ffargs 2>&1
    #             if ($output -match 'VMAF score:\s*(\d+\.\d+)') {
    #                 $result.VMAF = [double]$Matches[1]
    #                 Write-Host " $($result.VMAF)" -ForegroundColor Green
    #             }
    #             else {
    #                 Write-Host " FAILED" -ForegroundColor Red
    #             }
    #         }
            
    #         if ($Metrics -in ('Both', 'XPSNR')) {
    #             Write-Host "  Calculating XPSNR..." -ForegroundColor Gray -NoNewline
    #             $ffargs = @(
    #                 "-hide_banner", "-y", "-nostats" #, "-loglevel", "error"
    #             ) + $distArgs + $refArgs + @(
    #                 "-filter_complex", "$filterTemplate$xpsnrFilter"
    #                 "-f", "null", "-"
    #             )
    #             $output = & $ffmpeg $ffargs 2>&1
    #             if ($output -match 'XPSNR.*y:\s*(\d+\.\d+).*u:\s*(\d+\.\d+).*v:\s*(\d+\.\d+)') {
    #                 $result.XPSNR = [PSCustomObject]@{
    #                     Y    = [double]$Matches[1]
    #                     U    = [double]$Matches[2]
    #                     V    = [double]$Matches[3]
    #                     WSUM = (4 * [double]$Matches[1] + [double]$Matches[2] + [double]$Matches[3]) / 6
    #                 }
    #                 Write-Host " $($result.XPSNR.WSUM)" -ForegroundColor Green
    #             }
    #             # elseif ($output -match 'PSNR.*y:\s*(\d+\.\d+).*u:\s*(\d+\.\d+).*v:\s*(\d+\.\d+)') {
    #             #     $result.XPSNR = [PSCustomObject]@{
    #             #         Y    = [double]$Matches[1]
    #             #         U    = [double]$Matches[2]
    #             #         V    = [double]$Matches[3]
    #             #         WSUM = (4 * [double]$Matches[1] + [double]$Matches[2] + [double]$Matches[3]) / 6
    #             #     }
    #             #     Write-Host " $($result.XPSNR.WSUM) (from PSNR)" -ForegroundColor Green
    #             # }
    #             else {
    #                 Write-Host " FAILED" -ForegroundColor Red
    #             }
    #         }
            
    #         $results += $result
    #     }
    #     Write-Progress -Completed -Id 1
    # }
    
    # Show results
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "  RESULTS" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    
    if ($results.Count -eq 0) {
        Write-Host "  No results were calculated" -ForegroundColor Yellow
    }
    
    $sorted = $results | Sort-Object { if ($_.VMAF) { $_.VMAF } else { 0 } } -Descending
    
    foreach ($r in $sorted) {
        $name = [IO.Path]::GetFileName($r.Path)
        $vmaf = if ($r.VMAF) { "{0:N2}" -f $r.VMAF } else { "N/A" }
        $xpsnr = if ($r.XPSNR) { "{0:N2}" -f $r.XPSNR.WSUM } else { "N/A" }
        
        $color = if ($r.VMAF -and $r.VMAF -gt 90) { 'Green' } 
        elseif ($r.VMAF -and $r.VMAF -gt 80) { 'Yellow' } 
        else { 'Gray' }
        
        Write-Host "  $name" -ForegroundColor Gray
        Write-Host "    VMAF : $vmaf" -ForegroundColor $color
        Write-Host "    XPSNR: $xpsnr" -ForegroundColor Gray
        Write-Host ""
    }
    Write-Host "========================================" -ForegroundColor Cyan
    
    return $results
}

function ConvertTo-LatinTranslit {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true)]
        [string]$Text,
        
        [Parameter()]
        [ValidateSet('ISO', 'Scientific', 'BGN', 'Passport')]
        [string]$Standard = 'ISO',
        
        [Parameter()]
        [switch]$KeepDiacritics,
        
        [Parameter()]
        [switch]$UseExtendedMapping,
        
        [Parameter()]
        [switch]$Lowercase,
        
        [Parameter()]
        [switch]$ReplaceSpaces,
        
        [Parameter()]
        [string]$SpaceReplacement = '_',
        
        [Parameter()]
        [switch]$RemoveSpecialChars,
        
        [Parameter()]
        [string]$SpecialCharReplacement = '-',
        
        [Parameter()]
        [switch]$IsFilePath
    )
    
    begin {
        # Функция создания словаря с учетом регистра
        function New-CaseSensitiveDictionary {
            $dict = [System.Collections.Generic.Dictionary[string,string]]::new(
                [System.StringComparer]::InvariantCulture
            )
            return $dict
        }
        
        # Основная таблица транслитерации по стандарту ISO 9:1995
        $isoMap = New-CaseSensitiveDictionary
        $isoMap.Add('А', 'A'); $isoMap.Add('Б', 'B'); $isoMap.Add('В', 'V'); $isoMap.Add('Г', 'G'); $isoMap.Add('Д', 'D')
        $isoMap.Add('Е', 'E'); $isoMap.Add('Ё', 'Ë'); $isoMap.Add('Ж', 'Ž'); $isoMap.Add('З', 'Z'); $isoMap.Add('И', 'I')
        $isoMap.Add('Й', 'J'); $isoMap.Add('К', 'K'); $isoMap.Add('Л', 'L'); $isoMap.Add('М', 'M'); $isoMap.Add('Н', 'N')
        $isoMap.Add('О', 'O'); $isoMap.Add('П', 'P'); $isoMap.Add('Р', 'R'); $isoMap.Add('С', 'S'); $isoMap.Add('Т', 'T')
        $isoMap.Add('У', 'U'); $isoMap.Add('Ф', 'F'); $isoMap.Add('Х', 'H'); $isoMap.Add('Ц', 'C'); $isoMap.Add('Ч', 'Č')
        $isoMap.Add('Ш', 'Š'); $isoMap.Add('Щ', 'Ŝ'); $isoMap.Add('Ъ', 'ʺ'); $isoMap.Add('Ы', 'Y'); $isoMap.Add('Ь', 'ʹ')
        $isoMap.Add('Э', 'È'); $isoMap.Add('Ю', 'Û'); $isoMap.Add('Я', 'Â')
        $isoMap.Add('а', 'a'); $isoMap.Add('б', 'b'); $isoMap.Add('в', 'v'); $isoMap.Add('г', 'g'); $isoMap.Add('д', 'd')
        $isoMap.Add('е', 'e'); $isoMap.Add('ё', 'ë'); $isoMap.Add('ж', 'ž'); $isoMap.Add('з', 'z'); $isoMap.Add('и', 'i')
        $isoMap.Add('й', 'j'); $isoMap.Add('к', 'k'); $isoMap.Add('л', 'l'); $isoMap.Add('м', 'm'); $isoMap.Add('н', 'n')
        $isoMap.Add('о', 'o'); $isoMap.Add('п', 'p'); $isoMap.Add('р', 'r'); $isoMap.Add('с', 's'); $isoMap.Add('т', 't')
        $isoMap.Add('у', 'u'); $isoMap.Add('ф', 'f'); $isoMap.Add('х', 'h'); $isoMap.Add('ц', 'c'); $isoMap.Add('ч', 'č')
        $isoMap.Add('ш', 'š'); $isoMap.Add('щ', 'ŝ'); $isoMap.Add('ъ', 'ʺ'); $isoMap.Add('ы', 'y'); $isoMap.Add('ь', 'ʹ')
        $isoMap.Add('э', 'è'); $isoMap.Add('ю', 'û'); $isoMap.Add('я', 'â')
        
        # Расширенное отображение для имён файлов
        $extendedMap = New-CaseSensitiveDictionary
        $extendedMap.Add('А', 'A'); $extendedMap.Add('Б', 'B'); $extendedMap.Add('В', 'V'); $extendedMap.Add('Г', 'G'); $extendedMap.Add('Д', 'D')
        $extendedMap.Add('Е', 'E'); $extendedMap.Add('Ё', 'E'); $extendedMap.Add('Ж', 'Zh'); $extendedMap.Add('З', 'Z'); $extendedMap.Add('И', 'I')
        $extendedMap.Add('Й', 'Y'); $extendedMap.Add('К', 'K'); $extendedMap.Add('Л', 'L'); $extendedMap.Add('М', 'M'); $extendedMap.Add('Н', 'N')
        $extendedMap.Add('О', 'O'); $extendedMap.Add('П', 'P'); $extendedMap.Add('Р', 'R'); $extendedMap.Add('С', 'S'); $extendedMap.Add('Т', 'T')
        $extendedMap.Add('У', 'U'); $extendedMap.Add('Ф', 'F'); $extendedMap.Add('Х', 'Kh'); $extendedMap.Add('Ц', 'Ts'); $extendedMap.Add('Ч', 'Ch')
        $extendedMap.Add('Ш', 'Sh'); $extendedMap.Add('Щ', 'Sch'); $extendedMap.Add('Ъ', ''); $extendedMap.Add('Ы', 'Y'); $extendedMap.Add('Ь', '')
        $extendedMap.Add('Э', 'E'); $extendedMap.Add('Ю', 'Yu'); $extendedMap.Add('Я', 'Ya')
        $extendedMap.Add('а', 'a'); $extendedMap.Add('б', 'b'); $extendedMap.Add('в', 'v'); $extendedMap.Add('г', 'g'); $extendedMap.Add('д', 'd')
        $extendedMap.Add('е', 'e'); $extendedMap.Add('ё', 'e'); $extendedMap.Add('ж', 'zh'); $extendedMap.Add('з', 'z'); $extendedMap.Add('и', 'i')
        $extendedMap.Add('й', 'y'); $extendedMap.Add('к', 'k'); $extendedMap.Add('л', 'l'); $extendedMap.Add('м', 'm'); $extendedMap.Add('н', 'n')
        $extendedMap.Add('о', 'o'); $extendedMap.Add('п', 'p'); $extendedMap.Add('р', 'r'); $extendedMap.Add('с', 's'); $extendedMap.Add('т', 't')
        $extendedMap.Add('у', 'u'); $extendedMap.Add('ф', 'f'); $extendedMap.Add('х', 'kh'); $extendedMap.Add('ц', 'ts'); $extendedMap.Add('ч', 'ch')
        $extendedMap.Add('ш', 'sh'); $extendedMap.Add('щ', 'sch'); $extendedMap.Add('ъ', ''); $extendedMap.Add('ы', 'y'); $extendedMap.Add('ь', '')
        $extendedMap.Add('э', 'e'); $extendedMap.Add('ю', 'yu'); $extendedMap.Add('я', 'ya')
        
        # Функция клонирования словаря
        function Clone-Dictionary {
            param([System.Collections.Generic.Dictionary[string,string]]$Source)
            $clone = New-CaseSensitiveDictionary
            foreach ($key in $Source.Keys) {
                $clone.Add($key, $Source[$key])
            }
            return $clone
        }
        
        # Создание карты для выбранного стандарта
        $standardMap = Clone-Dictionary -Source $isoMap
        
        switch ($Standard) {
            'Passport' {
                $standardMap['Е'] = 'E'; $standardMap['Ё'] = 'E'; $standardMap['Ж'] = 'Zh'; $standardMap['Й'] = 'Y'
                $standardMap['Х'] = 'Kh'; $standardMap['Ц'] = 'Ts'; $standardMap['Ч'] = 'Ch'; $standardMap['Ш'] = 'Sh'
                $standardMap['Щ'] = 'Shch'; $standardMap['Ы'] = 'Y'; $standardMap['Ю'] = 'Yu'; $standardMap['Я'] = 'Ya'
                $standardMap['е'] = 'e'; $standardMap['ё'] = 'e'; $standardMap['ж'] = 'zh'; $standardMap['й'] = 'y'
                $standardMap['х'] = 'kh'; $standardMap['ц'] = 'ts'; $standardMap['ч'] = 'ch'; $standardMap['ш'] = 'sh'
                $standardMap['щ'] = 'shch'; $standardMap['ы'] = 'y'; $standardMap['ю'] = 'yu'; $standardMap['я'] = 'ya'
                $standardMap['ъ'] = ''; $standardMap['ь'] = ''
            }
            'BGN' {
                $standardMap['Е'] = 'Ye'; $standardMap['Ё'] = 'Yo'; $standardMap['Ж'] = 'Zh'; $standardMap['Й'] = 'Y'
                $standardMap['Х'] = 'Kh'; $standardMap['Ц'] = 'Ts'; $standardMap['Ч'] = 'Ch'; $standardMap['Ш'] = 'Sh'
                $standardMap['Щ'] = 'Shch'; $standardMap['Ы'] = 'Y'; $standardMap['Ю'] = 'Yu'; $standardMap['Я'] = 'Ya'
                $standardMap['е'] = 'ye'; $standardMap['ё'] = 'yo'; $standardMap['ж'] = 'zh'; $standardMap['й'] = 'y'
                $standardMap['х'] = 'kh'; $standardMap['ц'] = 'ts'; $standardMap['ч'] = 'ch'; $standardMap['ш'] = 'sh'
                $standardMap['щ'] = 'shch'; $standardMap['ы'] = 'y'; $standardMap['ю'] = 'yu'; $standardMap['я'] = 'ya'
                $standardMap['ъ'] = ''; $standardMap['ь'] = ''
            }
            'Scientific' {
                $standardMap['Е'] = 'E'; $standardMap['Ё'] = 'Ë'; $standardMap['Ж'] = 'Ž'; $standardMap['Й'] = 'J'
                $standardMap['Х'] = 'H'; $standardMap['Ц'] = 'C'; $standardMap['Ч'] = 'Č'; $standardMap['Ш'] = 'Š'
                $standardMap['Щ'] = 'Šč'; $standardMap['Ы'] = 'Y'; $standardMap['Ю'] = 'Ju'; $standardMap['Я'] = 'Ja'
                $standardMap['е'] = 'e'; $standardMap['ё'] = 'ë'; $standardMap['ж'] = 'ž'; $standardMap['й'] = 'j'
                $standardMap['х'] = 'h'; $standardMap['ц'] = 'c'; $standardMap['ч'] = 'č'; $standardMap['ш'] = 'š'
                $standardMap['щ'] = 'šč'; $standardMap['ы'] = 'y'; $standardMap['ю'] = 'ju'; $standardMap['я'] = 'ja'
            }
        }
        
        # Выбор карты транслитерации
        $map = if ($UseExtendedMapping) { $extendedMap } else { $standardMap }
        
        # Паттерн для русских букв
        $pattern = '[А-Яа-яЁё]'
        
        # Функция транслитерации строки
        function Convert-String {
            param([string]$InputString)
            
            if ([string]::IsNullOrEmpty($InputString)) {
                return $InputString
            }
            
            $result = $InputString -replace $pattern, {
                $char = $_.Value
                if ($map.ContainsKey($char)) {
                    return $map[$char]
                }
                return $char
            }
            
            return $result
        }
        
        # Функция очистки имени
        function Clean-Name {
            param([string]$Name)
            
            if ($RemoveSpecialChars) {
                $Name = $Name -replace '[^a-zA-Z0-9\s\-_.]', $SpecialCharReplacement
            }
            
            if ($ReplaceSpaces) {
                $Name = $Name -replace '\s+', $SpaceReplacement
            }
            
            if ($Lowercase) {
                $Name = $Name.ToLowerInvariant()
            }
            
            if (-not $KeepDiacritics) {
                $Name = $Name.Normalize([System.Text.NormalizationForm]::FormD)
                $Name = $Name -replace '[^\u0000-\u007F]', ''
                $Name = $Name -replace '\p{M}', ''
            }
            
            # Удаление лишних разделителей
            $Name = $Name -replace '_{2,}', '_'
            $Name = $Name -replace '-{2,}', '-'
            $Name = $Name -replace '^[\s_\-]+|[\s_\-]+$', ''
            
            return $Name
        }
    }
    
    process {
        if ([string]::IsNullOrWhiteSpace($Text)) {
            Write-Warning "Входная строка пуста"
            return $Text
        }
        
        $result = $Text
        
        if ($IsFilePath) {
            # Проверяем, является ли путь UNC (начинается с \\)
            $isUnc = $result.StartsWith('\\')
            
            # Разбиваем путь на части
            $parts = $result -split '[\\/]'
            $processedParts = @()
            
            foreach ($part in $parts) {
                if ([string]::IsNullOrEmpty($part)) {
                    # Сохраняем пустые части для UNC путей
                    $processedParts += $part
                    continue
                }
                
                # Проверяем, является ли часть буквой диска (C:, D:, и т.д.)
                if ($part -match '^[A-Za-z]:$') {
                    $processedParts += $part
                    continue
                }
                
                # Транслитерируем часть пути
                $translitPart = Convert-String -InputString $part
                $cleanedPart = Clean-Name -Name $translitPart
                $processedParts += $cleanedPart
            }
            
            # Собираем путь обратно с сохранением разделителей
            if ($isUnc) {
                # Для UNC путей сохраняем двойной слеш в начале
                $result = '\\' + ($processedParts -join '\')
            } else {
                # Определяем исходный разделитель
                if ($result -contains '/') {
                    $result = $processedParts -join '/'
                } else {
                    $result = $processedParts -join '\'
                }
                
                # Восстанавливаем начальный слеш для корневых путей
                if ($result.StartsWith('\')) {
                    $result = '\' + $result.TrimStart('\')
                }
            }
        } else {
            # Обычная транслитерация всего текста
            $result = Convert-String -InputString $Text
            $result = Clean-Name -Name $result
            
            # Очистка от недопустимых символов для имён файлов (только если не путь)
            if (-not $IsFilePath) {
                $result = $result -replace '[<>:"/\\|?*]', ''
            }
        }
        
        return $result
    }
}

# Примеры использования
<#
# 1. Транслитерация простого текста
"Привет мир!" | ConvertTo-LatinTranslit

# 2. Транслитерация имени файла
"Мой файл.txt" | ConvertTo-LatinTranslit -ReplaceSpaces -SpaceReplacement '_'

# 3. Полная транслитерация пути (все папки и файлы)
"C:\Users\Иван\Documents\Мой проект\отчет 2024.pdf" | ConvertTo-LatinTranslit -IsFilePath -ReplaceSpaces -SpaceReplacement '_'
# Результат: C:\Users\Ivan\Documents\Moi_proekt\otchet_2024.pdf

# 4. UNC путь
"\\SERVER\Share\Общая папка\документ.docx" | ConvertTo-LatinTranslit -IsFilePath -ReplaceSpaces -Lowercase
# Результат: \\SERVER\Share\obshaya_papka\dokument.docx

# 5. Путь с сетевым диском
"Z:\Проекты\2024\Отчеты\финальный отчет.xlsx" | ConvertTo-LatinTranslit -IsFilePath -ReplaceSpaces -UseExtendedMapping
# Результат: Z:\Proekty\2024\Otchety\finalnyi_otchet.xlsx

# 6. Пакетная обработка файлов с переименованием
Get-ChildItem -Recurse -Filter *.txt | ForEach-Object {
    $newPath = $_.FullName | ConvertTo-LatinTranslit -IsFilePath -ReplaceSpaces -Lowercase -RemoveSpecialChars
    if ($newPath -ne $_.FullName) {
        Rename-Item -Path $_.FullName -NewName (Split-Path $newPath -Leaf) -WhatIf
    }
}

# 7. Переименование папок (только имя папки, без изменения структуры)
$folder = "C:\Projects\Старый проект"
$newFolderName = (Split-Path $folder -Leaf) | ConvertTo-LatinTranslit -ReplaceSpaces
$newPath = Join-Path (Split-Path $folder -Parent) $newFolderName
Rename-Item -Path $folder -NewName $newFolderName -WhatIf
#>

function Export-AsLossless {
    [CmdletBinding()]
    param(
        [string]$encApp = 'X:\Apps\_VideoEncoding\StaxRip\Apps\Encoders\SvtAv1EncApp-Essential\SvtAv1EncApp.exe',
        [string]$inFile = 'r:\Temp\Lead.Children.S01E01.2160p.HDR.H.265.Master5_EncodingTests\Lead.Children.S01E01.2160p.HDR.H.265.Master5.vpy',
        [string]$outFile = 'g:\.temp\Lead.Children.S01E01.2160p.HDR.H.265.Master5.ivf'
    )

    try {
        $output = & vspipe.exe -c y4m $inFile - | & $encApp --input - --output $outFile --lossless 1 2>&1

        if ($LASTEXITCODE -eq 0) {
            return $outFile
        } else {
            Write-Error "Encoding failed (exit code $LASTEXITCODE): $output"
            return $null
        }
    }
    catch {
        Write-Error "Error during encoding: $_"
        return $null
    }
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
    # Convert-ChaptersToXML, `
    Get-ScriptFrameRate, `
    Convert-MP4TagsToXml, `
    Convert-VideoToAV1, Get-VideoQualityMetrics2, ConvertTo-LatinTranslit, Export-AsLossless