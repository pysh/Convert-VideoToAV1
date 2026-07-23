<#
.SYNOPSIS
    Модуль утилит для анализа качества видео с поддержкой ffmpeg и FFVship
.DESCRIPTION
    Предоставляет функции для расчета метрик качества видео: VMAF, XPSNR, PSNR, SSIM, SSIMULACRA2
.NOTES
    Author: pysh
    Version: 3.0
    Requires: PowerShell 7.5+, ffmpeg, ffprobe, FFVship (опционально)
#>

#region Helper Functions

function ConvertTo-FrameRate {
    <#
    .SYNOPSIS
        Преобразует FPS из строки в число
    #>
    [CmdletBinding()]
    param([string]$FpsString)

    if ($FpsString -match '^\d+/\d+$') {
        $num, $den = $FpsString -split '/'
        return [double]$num / [double]$den
    }
    elseif ($FpsString -match '^\d+(\.\d+)?$') {
        return [double]$FpsString
    }
    throw "Некорректный формат FPS: $FpsString"
}

function Get-VideoFileType {
    <#
    .SYNOPSIS
        Определяет тип видеофайла по расширению
    #>
    [CmdletBinding()]
    param([string]$Path)

    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    switch ($ext) {
        '.vpy' { return 'VapourSynth' }
        '.avs' { return 'AviSynth' }
        default { return 'Video' }
    }
}

function Get-VideoFrameRate {
    <#
    .SYNOPSIS
        Получает FPS видеофайла или скрипта
    #>
    [CmdletBinding()]
    param(
        [string]$Path,
        [string]$FileType
    )
    
    try {
        switch ($FileType) {
            'VapourSynth' {
                $output = & vspipe -i $Path --info 2>&1
                if ($output -match 'FPS:\s*([\d\/]+(?:\.\d+)?)') {
                    return [Math]::Round((ConvertTo-FrameRate $Matches[1]), 3)
                }
            }
            default {
                $ffprobe = if ($global:VideoTools.FFprobe) { $global:VideoTools.FFprobe } else { 'ffprobe' }
                $args = @('-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=r_frame_rate', '-of', 'default=noprint_wrappers=1:nokey=1')
                if ($FileType -eq 'AviSynth') { $args += '-f', 'avisynth' }
                $args += $Path
                
                $output = & $ffprobe $args 2>&1
                if ($LASTEXITCODE -eq 0 -and $output) {
                    $fps = $output.Trim()
                    if ($fps -match '(\d+)/(\d+)') {
                        return [Math]::Round([double]$Matches[1] / [double]$Matches[2], 3)
                    }
                    return [double]$fps
                }
            }
        }
    }
    catch {
        Write-Verbose "Не удалось получить FPS для ${Path}, используется 25.0"
    }
    return 25.0
}

function Build-MetricFilterGraph {
    <#
    .SYNOPSIS
        Строит фильтр для ffmpeg с указанными метриками
    #>
    [CmdletBinding()]
    param(
        [string]$DistFilter,
        [string]$RefFilter,
        [string[]]$MetricList,
        [string]$ModelVersion,
        [int]$ThreadCount,
        [int]$Subsample,
        [string]$PoolMethod,
        [string]$LogPath
    )
    
    # Исключаем SSIMULACRA2 (обрабатывается отдельно)
    $ffmpegMetrics = $MetricList | Where-Object { $_ -ne 'SSIMULACRA2' }
    if (-not $ffmpegMetrics) { return $null }
    
    $splitCount = 0
    $metricFilters = [System.Collections.Generic.List[string]]::new()
    $idx = 0
    
    # VMAF (2 потока: обычный и harmonic)
    if ($ffmpegMetrics -contains 'VMAF') {
        $params = @(
            "eof_action=endall",
            "n_threads=$ThreadCount",
            "n_subsample=$Subsample",
            "model=version=$ModelVersion",
            "pool=$PoolMethod"
        )
        if ($LogPath) {
            $params += "log_path='$($LogPath.Replace('\', '\\'))'"
            $params += "log_fmt=json"
        }
        $metricFilters.Add("[dst${idx}][src${idx}]libvmaf=$($params -join ':')")
        $idx++
        
        $paramsNeg = @(
            "eof_action=endall",
            "n_threads=$ThreadCount",
            "n_subsample=$Subsample",
            "model=version=${ModelVersion}neg",
            "pool=harmonic_mean"
        )
        $metricFilters.Add("[dst${idx}][src${idx}]libvmaf=$($paramsNeg -join ':')")
        $idx++
        $splitCount += 2
    }
    
    # XPSNR
    if ($ffmpegMetrics -contains 'XPSNR') {
        $metricFilters.Add("[dst${idx}][src${idx}]xpsnr=eof_action=endall")
        $idx++; $splitCount++
    }
    
    # PSNR
    if ($ffmpegMetrics -contains 'PSNR') {
        $metricFilters.Add("[dst${idx}][src${idx}]psnr=eof_action=endall")
        $idx++; $splitCount++
    }
    
    # SSIM
    if ($ffmpegMetrics -contains 'SSIM') {
        $metricFilters.Add("[dst${idx}][src${idx}]ssim=eof_action=endall")
        $idx++; $splitCount++
    }
    
    if ($splitCount -eq 0) { return $null }
    
    # Формируем метки
    $dstLabels = (0..($splitCount-1) | ForEach-Object { "[dst$_]" }) -join ''
    $srcLabels = (0..($splitCount-1) | ForEach-Object { "[src$_]" }) -join ''
    
    $distInput = if ($DistFilter) { "[0:v]${DistFilter}" } else { "[0:v]" }
    $refInput = if ($RefFilter) { "[1:v]${RefFilter}" } else { "[1:v]" }
    
    return "${distInput},split=$splitCount$dstLabels;${refInput},split=$splitCount$srcLabels;$($metricFilters -join ';')"
}

#endregion

#region Main Functions

function Get-VideoQualityMetricsX {
    <#
    .SYNOPSIS
        Рассчитывает метрики качества видео
    .DESCRIPTION
        Поддерживает: VMAF, XPSNR, PSNR, SSIM, SSIMULACRA2
        Для SSIMULACRA2 требуется FFVship.exe
    .PARAMETER DistortedPaths
        Массив путей к искаженным видеофайлам
    .PARAMETER ReferencePath
        Путь к эталонному видео
    .PARAMETER Metrics
        Список метрик для расчета (VMAF, XPSNR, PSNR, SSIM, SSIMULACRA2, All)
    .PARAMETER Crop
        Параметры обрезки (Left, Right, Top, Bottom, CropDistVideo)
    .PARAMETER TrimStartSeconds
        Начало обрезки в секундах
    .PARAMETER DurationSeconds
        Длительность в секундах
    .PARAMETER ModelVersion
        Версия модели VMAF
    .PARAMETER Threads
        Количество потоков
    .PARAMETER Subsample
        Частота сэмплирования
    .PARAMETER LogPath
        Путь для сохранения лога VMAF
    .PARAMETER PoolMethod
        Метод пулинга (mean, harmonic_mean)
    .PARAMETER FFVshipPath
        Путь к FFVship.exe
    .PARAMETER SSIMEvery
        Частота расчета SSIMULACRA2 (кадров)
    .PARAMETER SSIMGPUID
        ID GPU для SSIMULACRA2
    .PARAMETER SSIMGPUThreads
        Количество потоков GPU для SSIMULACRA2
    .PARAMETER SSIMCacheIndex
        Кэшировать индексы FFMS2
    .EXAMPLE
        Get-VideoQualityMetrics -DistortedPaths @("enc1.mkv", "enc2.mkv") -ReferencePath "source.mkv" -Metrics All
    .EXAMPLE
        Get-VideoQualityMetrics -DistortedPaths "encoded.mkv" -ReferencePath "source.vpy" -Metrics VMAF,XPSNR
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$DistortedPaths,
        
        [Parameter(Mandatory)]
        [string]$ReferencePath,

        [ValidateSet('VMAF', 'XPSNR', 'PSNR', 'SSIM', 'SSIMULACRA2', 'All')]
        [string[]]$Metrics = @('VMAF'),

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
        
        # SSIMULACRA2 parameters
        [string]$FFVshipPath = 'R:\ffvship\FFVship.exe',
        [int]$SSIMEvery = 5,
        [int]$SSIMGPUID = 0,
        [int]$SSIMGPUThreads = 3,
        [switch]$SSIMCacheIndex
    )

    if ($Metrics -contains 'All') {
        $Metrics = @('VMAF', 'XPSNR', 'PSNR', 'SSIM', 'SSIMULACRA2')
    }
    
    # Проверяем наличие SSIMULACRA2
    $useSSIM = $Metrics -contains 'SSIMULACRA2'
    if ($useSSIM -and -not (Test-Path -LiteralPath $FFVshipPath)) {
        Write-Warning "FFVship.exe не найден: ${FFVshipPath}. SSIMULACRA2 будет пропущен."
        $Metrics = $Metrics | Where-Object { $_ -ne 'SSIMULACRA2' }
        $useSSIM = $false
    }
    
    Write-Verbose "Расчет метрик: $($Metrics -join ', ')"
    
    # Валидация файлов
    foreach ($path in @($ReferencePath) + $DistortedPaths) {
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Файл не найден: ${path}"
        }
    }
    
    # Получаем информацию о файлах
    $refType = Get-VideoFileType -Path $ReferencePath
    $refFPS = Get-VideoFrameRate -Path $ReferencePath -FileType $refType
    Write-Verbose "Референс: $([IO.Path]::GetFileName($ReferencePath)) [$refType, ${refFPS}fps]"
    
    $distInfo = @{}
    foreach ($path in $DistortedPaths) {
        $type = Get-VideoFileType -Path $path
        $fps = Get-VideoFrameRate -Path $path -FileType $type
        $distInfo[$path] = @{ Type = $type; FPS = $fps }
        Write-Verbose "Дисторшн: $([IO.Path]::GetFileName($path)) [$type, ${fps}fps]"
    }
    
    # Формируем фильтры для ffmpeg
    $cropFilter = ''
    if ($Crop.Left -or $Crop.Right -or $Crop.Top -or $Crop.Bottom) {
        $cropFilter = "crop=w=iw-$($Crop.Left)-$($Crop.Right):h=ih-$($Crop.Top)-$($Crop.Bottom):x=$($Crop.Left):y=$($Crop.Top)"
        Write-Verbose "Фильтр обрезки: ${cropFilter}"
    }
    
    $trimFilter = ''
    if ($TrimStartSeconds -gt 0 -or $DurationSeconds -gt 0) {
        $trimFilter = if ($DurationSeconds -gt 0) {
            "trim=start=${TrimStartSeconds}:duration=${DurationSeconds}"
        } else {
            "trim=start=${TrimStartSeconds}"
        }
        Write-Verbose "Фильтр времени: ${trimFilter}"
    }
    
    $baseFilter = "settb=AVTB,setpts=PTS-STARTPTS,format=yuv420p"
    $commonFilters = @($trimFilter, $baseFilter) -ne '' -join ','
    
    # Собираем фильтры для каждого потока
    $distFilters = @()
    if ($Crop.CropDistVideo -and $cropFilter) { $distFilters += $cropFilter }
    if ($commonFilters) { $distFilters += $commonFilters }
    $distFilterStr = $distFilters -join ','
    
    $refFilters = @()
    if ($cropFilter) { $refFilters += $cropFilter }
    if ($commonFilters) { $refFilters += $commonFilters }
    $refFilterStr = $refFilters -join ','
    
    # Строим граф фильтров для ffmpeg
    $filterGraph = Build-MetricFilterGraph `
        -DistFilter $distFilterStr `
        -RefFilter $refFilterStr `
        -MetricList $Metrics `
        -ModelVersion $ModelVersion `
        -ThreadCount $Threads `
        -Subsample $Subsample `
        -PoolMethod $PoolMethod `
        -LogPath $LogPath
    
    if ($filterGraph) {
        Write-Verbose "Граф фильтров: ${filterGraph}"
    }
    
    # Подготавливаем параметры обрезки для SSIMULACRA2
    $ssimCropArgs = @()
    if ($Crop.Left -or $Crop.Right -or $Crop.Top -or $Crop.Bottom) {
        # Для референса используем обрезку всегда
        $ssimCropArgs += "--cropTopSource", $Crop.Top
        $ssimCropArgs += "--cropBottomSource", $Crop.Bottom
        $ssimCropArgs += "--cropLeftSource", $Crop.Left
        $ssimCropArgs += "--cropRightSource", $Crop.Right
        
        # Для дисторшена обрезаем только если указано
        if ($Crop.CropDistVideo) {
            $ssimCropArgs += "--cropTopEncoded", $Crop.Top
            $ssimCropArgs += "--cropBottomEncoded", $Crop.Bottom
            $ssimCropArgs += "--cropLeftEncoded", $Crop.Left
            $ssimCropArgs += "--cropRightEncoded", $Crop.Right
        }
        Write-Verbose "SSIMULACRA2 обрезка: Source [$($Crop.Left),$($Crop.Top),$($Crop.Right),$($Crop.Bottom)] Encoded: $(if ($Crop.CropDistVideo) { 'Да' } else { 'Нет' })"
    }
    
    # Путь к ffmpeg
    $ffmpeg = (Get-Command ffmpeg -ErrorAction Stop).Source
    
    # Заголовок
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "  АНАЛИЗ КАЧЕСТВА ВИДЕО" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Файлов: $($DistortedPaths.Count)" -ForegroundColor White
    Write-Host "Метрики: $($Metrics -join ', ')" -ForegroundColor White
    if ($useSSIM) {
        Write-Host "SSIMULACRA2: GPU ${SSIMGPUID}, every ${SSIMEvery} frames" -ForegroundColor Magenta
        if ($ssimCropArgs) {
            Write-Host "  Crop: Source ($($Crop.Left),$($Crop.Top),$($Crop.Right),$($Crop.Bottom))" -ForegroundColor DarkGray
            if (-not $Crop.CropDistVideo) {
                Write-Host "  Encoded crop: Disabled (use CropDistVideo to enable)" -ForegroundColor DarkGray
            }
        }
    }
    Write-Host "========================================" -ForegroundColor Cyan
    
    $results = [System.Collections.Generic.List[PSObject]]::new()
    $totalFiles = $DistortedPaths.Count
    
    for ($i = 0; $i -lt $totalFiles; $i++) {
        $path = $DistortedPaths[$i]
        $num = $i + 1
        $fileName = [IO.Path]::GetFileName($path)
        
        Write-Progress -Activity "Расчет метрик" -Status "[$num/$totalFiles] ${fileName}" -PercentComplete (($num / $totalFiles) * 100)
        Write-Host "[$num/$totalFiles] ${fileName}" -ForegroundColor Yellow
        
        $result = [PSCustomObject]@{ 
            DistortedPath = $path
            VMAF          = $null
            VMAFNeg       = $null
            XPSNR         = $null
            PSNR          = $null
            SSIM          = $null
            SSIMULACRA2   = $null
            Time          = $null
        }
        
        $distType = $distInfo[$path].Type
        $distFPS = $distInfo[$path].FPS
        
        # Формируем аргументы для ffmpeg
        $distArgs = @('-r', $distFPS.ToString().Replace(',', '.'))
        if ($distType -eq 'VapourSynth') { $distArgs += '-f', 'vapoursynth' }
        elseif ($distType -eq 'AviSynth') { $distArgs += '-f', 'avisynth' }
        $distArgs += '-i', $path
        
        $refArgs = @('-r', $refFPS.ToString().Replace(',', '.'))
        if ($refType -eq 'VapourSynth') { $refArgs += '-f', 'vapoursynth' }
        elseif ($refType -eq 'AviSynth') { $refArgs += '-f', 'avisynth' }
        $refArgs += '-i', $ReferencePath
        
        # Запускаем ffmpeg если есть метрики
        if ($filterGraph) {
            $ffargs = @(
                "-threads", $Threads,
                "-hide_banner", "-y", "-nostats"
            ) + $distArgs + $refArgs + @(
                "-filter_complex", $filterGraph,
                "-f", "null", "-"
            )
            
            Write-Verbose "Запуск ffmpeg для ${fileName}"
            $timer = [System.Diagnostics.Stopwatch]::StartNew()
            $output = & $ffmpeg $ffargs 2>&1
            $timer.Stop()
            $result.Time = $timer
            $outputStr = $output -join "`n"
            
            # Парсим результаты
            if ($Metrics -contains 'VMAF') {
                $matches = [regex]::Matches($outputStr, 'VMAF score:\s*(\d+\.\d+)')
                if ($matches.Count -ge 1) {
                    $result.VMAF = [double]$matches[0].Groups[1].Value
                    Write-Host "  VMAF: $($result.VMAF)" -ForegroundColor Green
                }
                if ($matches.Count -ge 2) {
                    $result.VMAFNeg = [double]$matches[1].Groups[1].Value
                    Write-Host "  VMAF (harm): $($result.VMAFNeg)" -ForegroundColor Cyan
                }
            }
            
            if ($Metrics -contains 'XPSNR' -and $outputStr -match 'XPSNR.*y:\s*(\d+\.\d+).*u:\s*(\d+\.\d+).*v:\s*(\d+\.\d+)') {
                $result.XPSNR = @{
                    Y = [double]$Matches[1]
                    U = [double]$Matches[2]
                    V = [double]$Matches[3]
                    WSUM = (4 * [double]$Matches[1] + [double]$Matches[2] + [double]$Matches[3]) / 6
                }
                Write-Host "  XPSNR: $($result.XPSNR.WSUM.ToString('F2'))" -ForegroundColor Green
            }
            
            if ($Metrics -contains 'PSNR' -and $outputStr -match 'PSNR.*y:\s*(\d+\.\d+).*u:\s*(\d+\.\d+).*v:\s*(\d+\.\d+)') {
                $result.PSNR = @{
                    Y = [double]$Matches[1]
                    U = [double]$Matches[2]
                    V = [double]$Matches[3]
                    WSUM = (4 * [double]$Matches[1] + [double]$Matches[2] + [double]$Matches[3]) / 6
                }
                Write-Host "  PSNR: $($result.PSNR.WSUM.ToString('F2'))" -ForegroundColor Green
            }
            
            if ($Metrics -contains 'SSIM') {
                if ($outputStr -match 'SSIM.*All:\s*(\d+\.\d+)') {
                    $result.SSIM = [double]$Matches[1]
                    Write-Host "  SSIM: $($result.SSIM.ToString('F4'))" -ForegroundColor Green
                }
                elseif ($outputStr -match 'SSIM.*y:\s*(\d+\.\d+).*u:\s*(\d+\.\d+).*v:\s*(\d+\.\d+)') {
                    $result.SSIM = [PSCustomObject]@{
                        Y = [double]$Matches[1]
                        U = [double]$Matches[2]
                        V = [double]$Matches[3]
                        AVG = ([double]$Matches[1] + [double]$Matches[2] + [double]$Matches[3]) / 3
                    }
                    Write-Host "  SSIM: $($result.SSIM.AVG.ToString('F4'))" -ForegroundColor Green
                }
            }
        }
        
        # SSIMULACRA2 (всегда последовательно)
        if ($useSSIM) {
            Write-Host "  SSIMULACRA2..." -ForegroundColor Magenta -NoNewline
            
            # Базовые аргументы
            $ssimArgs = @(
                "--source", $ReferencePath,
                "--encoded", $path,
                "--metric", "SSIMULACRA2",
                "--every", $SSIMEvery,
                "--threads", 2,
                "--gpu-threads", $SSIMGPUThreads,
                "--gpu-id", $SSIMGPUID
            )
            
            # Добавляем параметры обрезки
            if ($ssimCropArgs) {
                $ssimArgs += $ssimCropArgs
            }
            
            # Добавляем кэширование индексов
            if ($SSIMCacheIndex) { 
                $ssimArgs += "--cache-index" 
            }
            
            Write-Verbose "SSIMULACRA2 args: $($ssimArgs -join ' ')"
            
            $timer = [System.Diagnostics.Stopwatch]::StartNew()
            $output = & $FFVshipPath $ssimArgs 2>&1
            $timer.Stop()
            
            if ($LASTEXITCODE -eq 0) {
                $outStr = $output -join "`n"
                $ssimData = @{}
                
                if ($outStr -match 'Average\s*:\s*([\d.]+)') { $ssimData['Average'] = [double]$Matches[1] }
                if ($outStr -match 'Standard Deviation\s*:\s*([\d.]+)') { $ssimData['StdDev'] = [double]$Matches[1] }
                if ($outStr -match 'Median\s*:\s*([\d.]+)') { $ssimData['Median'] = [double]$Matches[1] }
                if ($outStr -match '5th percentile\s*:\s*([\d.]+)') { $ssimData['P5'] = [double]$Matches[1] }
                if ($outStr -match '95th percentile\s*:\s*([\d.]+)') { $ssimData['P95'] = [double]$Matches[1] }
                if ($outStr -match 'Minimum\s*:\s*([\d.]+)') { $ssimData['Min'] = [double]$Matches[1] }
                if ($outStr -match 'Maximum\s*:\s*([\d.]+)') { $ssimData['Max'] = [double]$Matches[1] }
                if ($outStr -match 'Computed (\d+) frames') { $ssimData['Frames'] = [int]$Matches[1] }
                
                if ($ssimData.Count -gt 0) {
                    $result.SSIMULACRA2 = [PSCustomObject]$ssimData
                    Write-Host " $($result.SSIMULACRA2.Average.ToString('F2')) (avg)" -ForegroundColor Green
                    Write-Verbose "SSIMULACRA2: $($result.SSIMULACRA2 | ConvertTo-Json -Compress)"
                } else {
                    Write-Host " FAILED (parse)" -ForegroundColor Red
                }
            } else {
                Write-Host " FAILED (code $LASTEXITCODE)" -ForegroundColor Red
                Write-Verbose "SSIMULACRA2 output: $($output -join "`n")"
            }
        }
        
        $results.Add($result)
    }
    
    Write-Progress -Completed
    
    # Краткая сводка
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "  РЕЗУЛЬТАТЫ" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    
    foreach ($r in $results) {
        $name = [IO.Path]::GetFileName($r.DistortedPath)
        $time = if ($r.Time) { "$([Math]::Round($r.Time.Elapsed.TotalSeconds, 1))s" } else { "N/A" }
        
        Write-Host "  $name [$time]" -ForegroundColor Gray
        if ($r.VMAF) { 
            $color = if ($r.VMAF -gt 90) { 'Green' } elseif ($r.VMAF -gt 80) { 'Yellow' } else { 'Gray' }
            Write-Host "    VMAF: $($r.VMAF.ToString('F2'))" -ForegroundColor $color 
        }
        if ($r.VMAFNeg) { Write-Host "    VMAF(h): $($r.VMAFNeg.ToString('F2'))" -ForegroundColor Cyan }
        if ($r.XPSNR) { Write-Host "    XPSNR: $($r.XPSNR.WSUM.ToString('F2'))" -ForegroundColor Gray }
        if ($r.PSNR) { Write-Host "    PSNR : $($r.PSNR.WSUM.ToString('F2'))" -ForegroundColor Gray }
        if ($r.SSIM) { 
            $ssimVal = if ($r.SSIM -is [double]) { $r.SSIM } else { $r.SSIM.AVG }
            Write-Host "    SSIM : $($ssimVal.ToString('F4'))" -ForegroundColor Gray
        }
        if ($r.SSIMULACRA2) { 
            Write-Host "    SSIM2: $($r.SSIMULACRA2.Average.ToString('F2')) [p5: $($r.SSIMULACRA2.P5.ToString('F2')), p95: $($r.SSIMULACRA2.P95.ToString('F2'))]" -ForegroundColor Magenta
        }
        Write-Host ""
    }
    Write-Host "========================================" -ForegroundColor Cyan
    
    return $results
}

#endregion

# Экспорт функций
# Export-ModuleMember -Function Get-VideoQualityMetricsX



[PSCustomObject]$CropPrm = @{
    Left          = 0
    Right         = 0
    Top           = 0
    Bottom        = 0
    CropDistVideo = $false
}
$ref = 'r:\Temp\e16.mkv'
$dist = @(
'r:\Temp\UM_s06e16_[hevc_crf25].mkv'
'r:\Temp\UM_s06e16_[hevc_crf24].mkv'
'r:\Temp\UM_s06e16_[hevc_crf23].mkv'
'r:\Temp\e16_[av1an_x265-crf95].mkv'
)
$res = Get-VideoQualityMetricsX -DistortedPaths $dist -ReferencePath $ref -Crop $CropPrm -SubSample 3 -Metrics All # -Metrics Both -TrimStartSeconds 0 -DurationSeconds 10
#$res | Format-List
