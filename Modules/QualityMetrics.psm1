<#
.SYNOPSIS
    Модуль утилит для анализа качества видео с поддержкой ffmpeg и FFVship
.DESCRIPTION
    Предоставляет функции для расчета метрик качества видео: VMAF, XPSNR, PSNR, SSIM, SSIMULACRA2
    Поддерживает аппаратное декодирование через CUDA и тонмаппинг HDR->SDR через libplacebo на GPU
.NOTES
    Author: pysh
    Version: 4.1
    Requires: PowerShell 7.5+, ffmpeg (с поддержкой cuda, vulkan, libplacebo), ffprobe, FFVship (опционально)
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
                $ffargs = @('-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=r_frame_rate', '-of', 'default=noprint_wrappers=1:nokey=1')
                if ($FileType -eq 'AviSynth') { $ffargs += '-f', 'avisynth' }
                $ffargs += $Path
                
                $output = & $ffprobe $ffargs 2>&1
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

function Test-GPUSupport {
    <#
    .SYNOPSIS
        Проверяет поддержку GPU-ускорения в FFmpeg
    #>
    [CmdletBinding()]
    param()

    $ffmpeg = (Get-Command ffmpeg9.exe -ErrorAction Stop).Source
    
    # Проверяем поддержку CUDA
    $hwaccels = & $ffmpeg -hwaccels 2>&1
    $hasCUDA = $hwaccels -match 'cuda'
    
    # Проверяем поддержку libplacebo
    $filters = & $ffmpeg -filters 2>&1
    $hasLibplacebo = $filters -match 'libplacebo'
    
    # Проверяем поддержку Vulkan
    $hasVulkan = $hwaccels -match 'vulkan'
    
    return @{
        CUDA = $hasCUDA
        Libplacebo = $hasLibplacebo
        Vulkan = $hasVulkan
        FullSupport = $hasCUDA -and $hasLibplacebo -and $hasVulkan
    }
}

function Build-MetricFilterGraph {
    <#
    .SYNOPSIS
        Строит фильтр для ffmpeg с указанными метриками и GPU-ускорением
    #>
    [CmdletBinding()]
    param(
        [string]$DistFilter,
        [string]$RefFilter,
        [string]$RefToneMapping,
        [string[]]$MetricList,
        [string]$ModelVersion,
        [int]$ThreadCount,
        [int]$Subsample,
        [string]$PoolMethod,
        [string]$LogPath,
        [bool]$UseGPU = $true
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
    
    # Формируем фильтры с поддержкой GPU
    if ($UseGPU) {
        # Distorted (SDR) - загрузка в Vulkan + базовые фильтры + конвертация в yuv420p через libplacebo
        $distFilterChain = @()
        $distFilterChain += "hwupload=derive_device=vulkan"
        
        # Добавляем пользовательские фильтры (trim, settb, setpts)
        if ($DistFilter -and $DistFilter -ne '') {
            $distFilterChain += $DistFilter
        }
        
        # Конвертация в yuv420p через libplacebo
        $distFilterChain += "libplacebo=format=yuv420p"
        
        $distInput = "[0:v]$($distFilterChain -join ',')"
        
        # Reference (HDR) - загрузка в Vulkan + тонмаппинг + конвертация
        $refFilterChain = @()
        $refFilterChain += "hwupload=derive_device=vulkan"
        
        # Добавляем пользовательские фильтры (trim, settb, setpts)
        if ($RefFilter -and $RefFilter -ne '') {
            $refFilterChain += $RefFilter
        }
        
        # Тонмаппинг HDR->SDR если указан
        if ($RefToneMapping -and $RefToneMapping -ne '') {
            # ВАЖНО: используем ${RefToneMapping} для правильной подстановки
            if ($RefToneMapping -notmatch 'format=') {
                $refFilterChain += "libplacebo=${RefToneMapping}:format=yuv420p"
            } else {
                $refFilterChain += "libplacebo=${RefToneMapping}"
            }
        } else {
            # Если тонмаппинга нет, просто конвертируем в yuv420p
            $refFilterChain += "libplacebo=format=yuv420p"
        }
        
        $refInput = "[1:v]$($refFilterChain -join ',')"
    } else {
        # CPU-режим (fallback)
        $distInput = if ($DistFilter -and $DistFilter -ne '') { "[0:v]${DistFilter}" } else { "[0:v]" }
        
        $refFilterChain = @()
        if ($RefFilter -and $RefFilter -ne '') { $refFilterChain += $RefFilter }
        if ($RefToneMapping -and $RefToneMapping -ne '') {
            if ($RefToneMapping -notmatch 'format=') {
                $refFilterChain += "libplacebo=${RefToneMapping}:format=yuv420p"
            } else {
                $refFilterChain += "libplacebo=${RefToneMapping}"
            }
        }
        $refInput = if ($refFilterChain) { 
            "[1:v]$($refFilterChain -join ',')" 
        } else { 
            "[1:v]" 
        }
    }
    
    return "${distInput},split=$splitCount$dstLabels;${refInput},split=$splitCount$srcLabels;$($metricFilters -join ';')"
}

#endregion

#region Main Functions

function Get-VideoQualityMetrics3 {
    <#
    .SYNOPSIS
    Рассчитывает метрики качества видео с GPU-ускорением и параллельной обработкой файлов.
    .DESCRIPTION
    Объединённая функция: функционал Get-VideoQualityMetrics3 (GPU, все метрики за один проход,
    VMAFNeg, SSIMULACRA2 через FFVship, тонмаппинг HDR->SDR) + параллельная обработка файлов
    через ForEach-Object -Parallel (из Get-VideoQualityMetrics2).
    .PARAMETER Parallel
    Включить параллельную обработку файлов.
    .PARAMETER ThrottleLimit
    Максимальное число одновременно обрабатываемых файлов.
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
            Left = 0; Right = 0; Top = 0; Bottom = 0; CropDistVideo = $false
        },

        [int]$TrimStartSeconds = 0,
        [int]$DurationSeconds = 0,
        [string]$ModelVersion = 'vmaf_4k_v0.6.1',
        [int]$Threads = [Environment]::ProcessorCount,
        [int]$Subsample = 3,
        [string]$LogPath,
        [ValidateSet('mean', 'harmonic_mean')]
        [string]$PoolMethod = 'mean',
        [string]$RefToneMapping = '',
        [bool]$UseGPU = $true,

        # --- НОВЫЕ ПАРАМЕТРЫ ПАРАЛЛЕЛЬНОСТИ (из Metrics2) ---
        [switch]$Parallel,
        [int]$ThrottleLimit,

        # --- Пути к инструментам ---
        [string]$FFmpegPath = 'ffmpeg9.exe',
        [string]$FFVshipPath = 'FFVship.exe',

        # --- Параметры SSIMULACRA2 ---
        [int]$SSIMEvery = 1,
        [int]$SSIMGPUID = 0,
        [int]$SSIMGPUThreads = 3,
        [switch]$SSIMCacheIndex
    )

    if ($Metrics -contains 'All') {
        $Metrics = @('VMAF', 'XPSNR', 'PSNR', 'SSIM', 'SSIMULACRA2')
    }

    # ---------- GPU support check ----------
    if ($UseGPU) {
        $gpuSupport = Test-GPUSupport
        if (-not $gpuSupport.FullSupport) {
            Write-Warning "GPU-ускорение недоступно (CUDA: $($gpuSupport.CUDA), Vulkan: $($gpuSupport.Vulkan), Libplacebo: $($gpuSupport.Libplacebo)). Переключаюсь на CPU-режим."
            $UseGPU = $false
        }
    }

    # ---------- SSIMULACRA2 availability ----------
    $useSSIM = $Metrics -contains 'SSIMULACRA2'
    if ($useSSIM -and -not (Get-Command -Name $FFVshipPath -ErrorAction SilentlyContinue)) {
        Write-Warning "FFVship.exe не найден: ${FFVshipPath}. SSIMULACRA2 будет пропущен."
        $Metrics = $Metrics | Where-Object { $_ -ne 'SSIMULACRA2' }
        $useSSIM = $false
    }

    # ---------- Resolve executable paths (ОДИН раз, снаружи parallel) ----------
    $ffmpeg = (Get-Command $FFmpegPath -ErrorAction Stop).Source
    $ffvship = if ($useSSIM) { (Get-Command $FFVshipPath -ErrorAction Stop).Source } else { $null }

    # ---------- Validate files ----------
    foreach ($path in @($ReferencePath) + $DistortedPaths) {
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Файл не найден: ${path}"
        }
    }

    # ---------- Получаем тип и FPS для всех файлов (СНАРУЖИ parallel) ----------
    $refType = Get-VideoFileType -Path $ReferencePath
    $refFPS  = Get-VideoFrameRate -Path $ReferencePath -FileType $refType
    Write-Verbose "Референс: $([IO.Path]::GetFileName($ReferencePath)) [$refType, ${refFPS}fps]"

    $distInfo = @{}
    foreach ($path in $DistortedPaths) {
        $type = Get-VideoFileType -Path $path
        $fps  = Get-VideoFrameRate -Path $path -FileType $type
        $distInfo[$path] = @{ Type = $type; FPS = $fps }
        Write-Verbose "Дисторшн: $([IO.Path]::GetFileName($path)) [$type, ${fps}fps]"
    }

    # ---------- Строим фильтры и граф ОДИН раз (общий для всех файлов) ----------
    $cropFilter = ''
    if ($Crop.Left -or $Crop.Right -or $Crop.Top -or $Crop.Bottom) {
        $cropFilter = "crop=w=iw-$($Crop.Left)-$($Crop.Right):h=ih-$($Crop.Top)-$($Crop.Bottom):x=$($Crop.Left):y=$($Crop.Top)"
    }

    $trimFilter = ''
    if ($TrimStartSeconds -gt 0 -or $DurationSeconds -gt 0) {
        $trimFilter = if ($DurationSeconds -gt 0) {
            "trim=start=${TrimStartSeconds}:duration=${DurationSeconds}"
        } else {
            "trim=start=${TrimStartSeconds}"
        }
    }

    $baseFilter = "settb=AVTB,setpts=PTS-STARTPTS"
    $commonFilters = @($trimFilter, $baseFilter) -ne '' -join ','

    $distFilters = @()
    if ($Crop.CropDistVideo -and $cropFilter) { $distFilters += $cropFilter }
    if ($commonFilters) { $distFilters += $commonFilters }
    $distFilterStr = $distFilters -join ','

    $refFilters = @()
    if ($cropFilter) { $refFilters += $cropFilter }
    if ($commonFilters) { $refFilters += $commonFilters }
    $refFilterStr = $refFilters -join ','

    $filterGraph = Build-MetricFilterGraph `
        -DistFilter $distFilterStr `
        -RefFilter $refFilterStr `
        -RefToneMapping $RefToneMapping `
        -MetricList $Metrics `
        -ModelVersion $ModelVersion `
        -ThreadCount $Threads `
        -Subsample $Subsample `
        -PoolMethod $PoolMethod `
        -LogPath $LogPath `
        -UseGPU $UseGPU

    # ---------- SSIMULACRA2 crop args (общие) ----------
    $ssimCropArgs = @()
    if ($Crop.Left -or $Crop.Right -or $Crop.Top -or $Crop.Bottom) {
        $ssimCropArgs += @(
            "--cropTopSource",    $Crop.Top,
            "--cropBottomSource", $Crop.Bottom,
            "--cropLeftSource",   $Crop.Left,
            "--cropRightSource",  $Crop.Right
        )
        if ($Crop.CropDistVideo) {
            $ssimCropArgs += @(
                "--cropTopEncoded",    $Crop.Top,
                "--cropBottomEncoded", $Crop.Bottom,
                "--cropLeftEncoded",   $Crop.Left,
                "--cropRightEncoded",  $Crop.Right
            )
        }
    }

    if ($useSSIM -and $RefToneMapping) {
        Write-Warning "SSIMULACRA2 НЕ использует тонмаппинг reference видео. Тонмаппинг применяется ТОЛЬКО для ffmpeg метрик."
    }

    # ---------- GPU args и threads ----------
    $gpuArgs = @()
    if ($UseGPU) {
        $gpuArgs = @(
            '-init_hw_device', 'cuda=cu:0',
            '-init_hw_device', 'vulkan=vk@cu',
            '-hwaccel', 'cuda',
            '-hwaccel_output_format', 'cuda'
        )
        $threadsToUse = [Math]::Min(4, $Threads)
    } else {
        $threadsToUse = $Threads
    }

    # ---------- Заголовок ----------
    $effectiveThrottle = [Math]::Max(1, [Math]::Min($ThrottleLimit, $DistortedPaths.Count))
    $parallelMode = $Parallel -and $DistortedPaths.Count -gt 1

    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "  АНАЛИЗ КАЧЕСТВА ВИДЕО" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Файлов: $($DistortedPaths.Count)" -ForegroundColor White
    Write-Host "Метрики: $($Metrics -join ', ')" -ForegroundColor White
    Write-Host "Режим: $(if ($parallelMode) { "Параллельный (ThrottleLimit=$effectiveThrottle)" } else { 'Последовательный' })" -ForegroundColor $(if ($parallelMode) { 'Green' } else { 'Gray' })
    Write-Host "GPU-ускорение: $(if ($UseGPU) { 'Включено (CUDA+Vulkan)' } else { 'Выключено' })" -ForegroundColor $(if ($UseGPU) { 'Green' } else { 'Yellow' })
    if ($RefToneMapping) {
        Write-Host "Тонмаппинг HDR->SDR: libplacebo=$RefToneMapping" -ForegroundColor Yellow
    }
    if ($parallelMode -and $UseGPU -and $effectiveThrottle -gt 1) {
        Write-Host "  Внимание: параллельный GPU-декодинг может перегрузить GPU при ThrottleLimit > 1" -ForegroundColor DarkYellow
    }
    Write-Host "========================================" -ForegroundColor Cyan

    # ---------- Формируем jobs (вся подготовка уже сделана) ----------
    $jobs = [System.Collections.Generic.List[object]]::new()
    $counter = 0
    foreach ($path in $DistortedPaths) {
        $counter++
        $jobs.Add(@{
            Id               = $counter
            Total            = $DistortedPaths.Count
            DistortedPath    = $path
            DistortedType    = $distInfo[$path].Type
            DistortedFPS     = $distInfo[$path].FPS
            ReferencePath    = $ReferencePath
            ReferenceType    = $refType
            ReferenceFPS     = $refFPS
            FilterGraph      = $filterGraph
            Metrics          = @($Metrics)
            FFmpegPath       = $ffmpeg
            FFVshipPath      = $ffvship
            UseSSIM          = $useSSIM
            GpuArgs          = $gpuArgs
            ThreadsToUse     = $threadsToUse
            SSIMEvery        = $SSIMEvery
            SSIMGPUID        = $SSIMGPUID
            SSIMGPUThreads   = $SSIMGPUThreads
            SSIMCacheIndex   = [bool]$SSIMCacheIndex
            SSIMCropArgs     = $ssimCropArgs
        })
    }

    # ---------- Единый script block обработки одного job'а ----------
    # ВАЖНО: внутри НЕ используются helper-функции модуля — только нативные вызовы и парсинг,
    # т.к. ForEach-Object -Parallel выполняет блок в отдельных runspace'ах.
    $processJob = {
        $job = $_
        $fileName = [IO.Path]::GetFileName($job.DistortedPath)
        Write-Host "[$($job.Id)/$($job.Total)] $fileName" -ForegroundColor Yellow

        $result = [PSCustomObject]@{
            Id            = $job.Id
            DistortedPath = $job.DistortedPath
            VMAF          = $null
            VMAFNeg       = $null
            XPSNR         = $null
            PSNR          = $null
            SSIM          = $null
            SSIMULACRA2   = $null
            Time          = $null
            Error         = $null
        }

        try {
            # Входные аргументы (FPS/format для каждого файла свои)
            $distArgs = @('-r', $job.DistortedFPS.ToString().Replace(',', '.'))
            if ($job.DistortedType -eq 'VapourSynth') { $distArgs += '-f', 'vapoursynth' }
            elseif ($job.DistortedType -eq 'AviSynth') { $distArgs += '-f', 'avisynth' }
            $distArgs += '-i', $job.DistortedPath

            $refArgs = @('-r', $job.ReferenceFPS.ToString().Replace(',', '.'))
            if ($job.ReferenceType -eq 'VapourSynth') { $refArgs += '-f', 'vapoursynth' }
            elseif ($job.ReferenceType -eq 'AviSynth') { $refArgs += '-f', 'avisynth' }
            $refArgs += '-i', $job.ReferencePath

            # ---------- ffmpeg-метрики ----------
            if ($job.FilterGraph) {
                $ffargs = @(
                    "-threads", $job.ThreadsToUse,
                    "-hide_banner", "-y", "-nostats"
                ) + $job.GpuArgs + $distArgs + $refArgs + @(
                    "-filter_complex", $job.FilterGraph,
                    "-f", "null", "-"
                )

                $timer = [System.Diagnostics.Stopwatch]::StartNew()
                $output = & $job.FFmpegPath $ffargs 2>&1
                $timer.Stop()
                $result.Time = $timer

                $outputStr = $output -join "`n"

                # VMAF: первое совпадение = обычный, второе = neg (harmonic_mean)
                if ($job.Metrics -contains 'VMAF') {
                    $vmafMatches = [regex]::Matches($outputStr, 'VMAF score:\s*(\d+\.\d+)')
                    if ($vmafMatches.Count -ge 1) { $result.VMAF = [double]$vmafMatches[0].Groups[1].Value }
                    if ($vmafMatches.Count -ge 2) { $result.VMAFNeg = [double]$vmafMatches[1].Groups[1].Value }
                }

                if ($job.Metrics -contains 'XPSNR' -and $outputStr -match 'XPSNR.*y:\s*(\d+\.\d+).*u:\s*(\d+\.\d+).*v:\s*(\d+\.\d+)') {
                    $result.XPSNR = @{
                        Y = [double]$Matches[1]; U = [double]$Matches[2]; V = [double]$Matches[3]
                        WSUM = (4 * [double]$Matches[1] + [double]$Matches[2] + [double]$Matches[3]) / 6
                    }
                }

                if ($job.Metrics -contains 'PSNR' -and $outputStr -match 'PSNR.*y:\s*(\d+\.\d+).*u:\s*(\d+\.\d+).*v:\s*(\d+\.\d+)') {
                    $result.PSNR = @{
                        Y = [double]$Matches[1]; U = [double]$Matches[2]; V = [double]$Matches[3]
                        WSUM = (4 * [double]$Matches[1] + [double]$Matches[2] + [double]$Matches[3]) / 6
                    }
                }

                if ($job.Metrics -contains 'SSIM') {
                    if ($outputStr -match 'SSIM.*All:\s*(\d+\.\d+)') {
                        $result.SSIM = [double]$Matches[1]
                    }
                    elseif ($outputStr -match 'SSIM.*y:\s*(\d+\.\d+).*u:\s*(\d+\.\d+).*v:\s*(\d+\.\d+)') {
                        $result.SSIM = [PSCustomObject]@{
                            Y = [double]$Matches[1]; U = [double]$Matches[2]; V = [double]$Matches[3]
                            AVG = ([double]$Matches[1] + [double]$Matches[2] + [double]$Matches[3]) / 3
                        }
                    }
                }
            }

            # ---------- SSIMULACRA2 ----------
            if ($job.UseSSIM) {
                $ssimArgs = @(
                    "--source",      $job.ReferencePath,
                    "--encoded",     $job.DistortedPath,
                    "--metric",      "SSIMULACRA2",
                    "--every",       $job.SSIMEvery,
                    "--threads",     2,
                    "--gpu-threads", $job.SSIMGPUThreads,
                    "--gpu-id",      $job.SSIMGPUID
                )
                if ($job.SSIMCropArgs) { $ssimArgs += $job.SSIMCropArgs }
                if ($job.SSIMCacheIndex) { $ssimArgs += "--cache-index" }

                $output = & $job.FFVshipPath $ssimArgs 2>&1
                if ($LASTEXITCODE -eq 0) {
                    $outStr = $output -join "`n"
                    $ssimData = @{}
                    if ($outStr -match 'Average\s*:\s*(-?[\d.]+)')         { $ssimData['Average'] = [double]$Matches[1] }
                    if ($outStr -match 'Standard Deviation\s*:\s*(-?[\d.]+)') { $ssimData['StdDev']  = [double]$Matches[1] }
                    if ($outStr -match 'Median\s*:\s*(-?[\d.]+)')           { $ssimData['Median']  = [double]$Matches[1] }
                    if ($outStr -match '5th percentile\s*:\s*(-?[\d.]+)')   { $ssimData['P5']      = [double]$Matches[1] }
                    if ($outStr -match '95th percentile\s*:\s*(-?[\d.]+)')  { $ssimData['P95']     = [double]$Matches[1] }
                    if ($outStr -match 'Minimum\s*:\s*(-?[\d.]+)')          { $ssimData['Min']     = [double]$Matches[1] }
                    if ($outStr -match 'Maximum\s*:\s*(-?[\d.]+)')          { $ssimData['Max']     = [double]$Matches[1] }
                    if ($outStr -match 'Computed (\d+) frames')             { $ssimData['Frames']  = [int]$Matches[1] }
                    if ($ssimData.Count -gt 0) {
                        $result.SSIMULACRA2 = [PSCustomObject]$ssimData
                    }
                }
                else {
                    $result.Error = "SSIMULACRA2 failed with exit code $LASTEXITCODE"
                }
            }
        }
        catch {
            $result.Error = "$_"
        }

        # Краткий вывод по завершению job'а
        # if ($result.VMAF)          { Write-Host "  VMAF: $($result.VMAF.ToString('F2'))" -ForegroundColor Green }
        # if ($result.VMAFNeg)       { Write-Host "  VMAF(h): $($result.VMAFNeg.ToString('F2'))" -ForegroundColor Cyan }
        # if ($result.XPSNR)         { Write-Host "  XPSNR: $($result.XPSNR.WSUM.ToString('F2'))" -ForegroundColor Gray }
        # if ($result.PSNR)          { Write-Host "  PSNR: $($result.PSNR.WSUM.ToString('F2'))" -ForegroundColor Gray }
        # if ($result.SSIM)          { $v = if ($result.SSIM -is [double]) { $result.SSIM } else { $result.SSIM.AVG }; Write-Host "  SSIM: $($v.ToString('F4'))" -ForegroundColor Gray }
        # if ($result.SSIMULACRA2)   { Write-Host "  SSIM2: $($result.SSIMULACRA2.Average.ToString('F2')) (avg)" -ForegroundColor Magenta }
        # if ($result.Error)         { Write-Host "  ERROR: $($result.Error)" -ForegroundColor Red }

        return $result
    }

    # ---------- Запуск: параллельно или последовательно ----------
    if ($parallelMode) {
        $jobResults = $jobs | ForEach-Object -Parallel $processJob -ThrottleLimit $effectiveThrottle
    }
    else {
        $jobResults = $jobs | ForEach-Object -Process $processJob
    }

    # ---------- Сортировка по исходному порядку ----------
    $results = @($jobResults) | Sort-Object { $_.Id }

    # ---------- Итоговая сводка ----------
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
        if ($r.XPSNR)   { Write-Host "    XPSNR  : $($r.XPSNR.WSUM.ToString('F2'))" -ForegroundColor Gray }
        if ($r.PSNR)    { Write-Host "    PSNR   : $($r.PSNR.WSUM.ToString('F2'))" -ForegroundColor Gray }
        if ($r.SSIM) {
            $ssimVal = if ($r.SSIM -is [double]) { $r.SSIM } else { $r.SSIM.AVG }
            Write-Host "    SSIM : $($ssimVal.ToString('F4'))" -ForegroundColor Gray
        }
        if ($r.SSIMULACRA2) {
            Write-Host "    SSIM2: $($r.SSIMULACRA2.Average.ToString('F2')) [p5: $($r.SSIMULACRA2.P5.ToString('F2')), p95: $($r.SSIMULACRA2.P95.ToString('F2'))]" -ForegroundColor Magenta
        }
        if ($r.Error) { Write-Host "    ERROR: $($r.Error)" -ForegroundColor Red }
        Write-Host ""
    }
    Write-Host "========================================" -ForegroundColor Cyan

    return $results
}








#region Предыдущая версия Get-VideoQualityMetrics3
# function Get-VideoQualityMetrics3 {
#     <#
#     .SYNOPSIS
#         Рассчитывает метрики качества видео с поддержкой GPU
#     .DESCRIPTION
#         Поддерживает: VMAF, XPSNR, PSNR, SSIM, SSIMULACRA2
#         Для SSIMULACRA2 требуется FFVship.exe
#         Для GPU-ускорения требуется ffmpeg с поддержкой cuda, vulkan, libplacebo
#     .PARAMETER DistortedPaths
#         Массив путей к искаженным видеофайлам
#     .PARAMETER ReferencePath
#         Путь к эталонному видео
#     .PARAMETER Metrics
#         Список метрик для расчета (VMAF, XPSNR, PSNR, SSIM, SSIMULACRA2, All)
#     .PARAMETER Crop
#         Параметры обрезки (Left, Right, Top, Bottom, CropDistVideo)
#     .PARAMETER TrimStartSeconds
#         Начало обрезки в секундах
#     .PARAMETER DurationSeconds
#         Длительность в секундах
#     .PARAMETER ModelVersion
#         Версия модели VMAF
#     .PARAMETER Threads
#         Количество потоков CPU (для VMAF и управления фильтрами)
#     .PARAMETER Subsample
#         Частота сэмплирования
#     .PARAMETER LogPath
#         Путь для сохранения лога VMAF
#     .PARAMETER PoolMethod
#         Метод пулинга (mean, harmonic_mean)
#     .PARAMETER RefToneMapping
#         Параметры тонмаппинга для reference видео (через libplacebo)
#         Примеры:
#         - "tonemapping=bt.2390:peak_detect=false:desat=0"
#         - "tonemapping=hable:peak_detect=false:desat=0:contrast_recovery=0.3"
#         - "tonemapping=mobius:peak_detect=false:desat=0"
#         НЕ ДОБАВЛЯЙТЕ format= в этот параметр - он будет добавлен автоматически
#     .PARAMETER UseGPU
#         Включить аппаратное ускорение (CUDA + Vulkan)
#     .PARAMETER FFVshipPath
#         Путь к FFVship.exe
#     .PARAMETER SSIMEvery
#         Частота расчета SSIMULACRA2 (кадров)
#     .PARAMETER SSIMGPUID
#         ID GPU для SSIMULACRA2
#     .PARAMETER SSIMGPUThreads
#         Количество потоков GPU для SSIMULACRA2
#     .PARAMETER SSIMCacheIndex
#         Кэшировать индексы FFMS2
#     .EXAMPLE
#         Get-VideoQualityMetrics3 -DistortedPaths @("enc1.mkv", "enc2.mkv") -ReferencePath "source.mkv" -Metrics All
#     .EXAMPLE
#         Get-VideoQualityMetrics3 -DistortedPaths "encoded.mkv" -ReferencePath "source.vpy" -Metrics VMAF -RefToneMapping "tonemapping=bt.2390:peak_detect=false:desat=0"
#     .EXAMPLE
#         Get-VideoQualityMetrics3 -DistortedPaths "sdr_enc.mkv" -ReferencePath "hdr_source.mkv" -Metrics VMAF,PSNR,SSIM -RefToneMapping "tonemapping=hable:peak_detect=false:desat=0:contrast_recovery=0.3" -UseGPU $true
#     #>
#     [CmdletBinding()]
#     param(
#         [Parameter(Mandatory)]
#         [string[]]$DistortedPaths,
        
#         [Parameter(Mandatory)]
#         [string]$ReferencePath,

#         [ValidateSet('VMAF', 'XPSNR', 'PSNR', 'SSIM', 'SSIMULACRA2', 'All')]
#         [string[]]$Metrics = @('VMAF'),

#         [PSCustomObject]$Crop = @{
#             Left          = 0
#             Right         = 0
#             Top           = 0
#             Bottom        = 0
#             CropDistVideo = $false
#         },

#         [int]$TrimStartSeconds = 0,
#         [int]$DurationSeconds = 0,

#         [string]$ModelVersion = 'vmaf_4k_v0.6.1',
#         [int]$Threads = [Environment]::ProcessorCount,
#         [int]$Subsample = 3,
#         [string]$LogPath,

#         [ValidateSet('mean', 'harmonic_mean')]
#         [string]$PoolMethod = 'mean',
        
#         # Tone mapping parameter (HDR->SDR) - НЕ ДОБАВЛЯЙТЕ format= сюда!
#         [string]$RefToneMapping = '',
        
#         # GPU acceleration
#         [bool]$UseGPU = $true,
        
#         # SSIMULACRA2 parameters
#         [string]$FFVshipPath = 'FFVship.exe',
#         [int]$SSIMEvery = 1,
#         [int]$SSIMGPUID = 0,
#         [int]$SSIMGPUThreads = 3,
#         [switch]$SSIMCacheIndex
#     )

#     if ($Metrics -contains 'All') {
#         $Metrics = @('VMAF', 'XPSNR', 'PSNR', 'SSIM', 'SSIMULACRA2')
#     }
    
#     # Проверяем поддержку GPU если включена
#     if ($UseGPU) {
#         $gpuSupport = Test-GPUSupport
#         if (-not $gpuSupport.FullSupport) {
#             Write-Warning "GPU-ускорение недоступно (CUDA: $($gpuSupport.CUDA), Vulkan: $($gpuSupport.Vulkan), Libplacebo: $($gpuSupport.Libplacebo)). Переключаюсь на CPU-режим."
#             $UseGPU = $false
#         } else {
#             Write-Verbose "GPU-ускорение включено (CUDA + Vulkan + libplacebo)"
#         }
#     }
    
#     # Проверяем наличие SSIMULACRA2
#     $useSSIM = $Metrics -contains 'SSIMULACRA2'
#     if ($useSSIM -and -not (Get-Command -Name $FFVshipPath -ErrorAction SilentlyContinue)) {
#         Write-Warning "FFVship.exe не найден: ${FFVshipPath}. SSIMULACRA2 будет пропущен."
#         $Metrics = $Metrics | Where-Object { $_ -ne 'SSIMULACRA2' }
#         $useSSIM = $false
#     }
    
#     Write-Verbose "Расчет метрик: $($Metrics -join ', ')"
#     if ($RefToneMapping) {
#         Write-Verbose "Тонмаппинг HDR->SDR для reference: libplacebo=$RefToneMapping"
#     }
#     Write-Verbose "Режим GPU: $UseGPU"
    
#     # Валидация файлов
#     foreach ($path in @($ReferencePath) + $DistortedPaths) {
#         if (-not (Test-Path -LiteralPath $path)) {
#             throw "Файл не найден: ${path}"
#         }
#     }
    
#     # Получаем информацию о файлах
#     $refType = Get-VideoFileType -Path $ReferencePath
#     $refFPS = Get-VideoFrameRate -Path $ReferencePath -FileType $refType
#     Write-Verbose "Референс: $([IO.Path]::GetFileName($ReferencePath)) [$refType, ${refFPS}fps]"
    
#     $distInfo = @{}
#     foreach ($path in $DistortedPaths) {
#         $type = Get-VideoFileType -Path $path
#         $fps = Get-VideoFrameRate -Path $path -FileType $type
#         $distInfo[$path] = @{ Type = $type; FPS = $fps }
#         Write-Verbose "Дисторшн: $([IO.Path]::GetFileName($path)) [$type, ${fps}fps]"
#     }
    
#     # Формируем фильтры для ffmpeg
#     # В GPU-режиме фильтры format и hwupload обрабатываются внутри Build-MetricFilterGraph
#     $cropFilter = ''
#     if ($Crop.Left -or $Crop.Right -or $Crop.Top -or $Crop.Bottom) {
#         $cropFilter = "crop=w=iw-$($Crop.Left)-$($Crop.Right):h=ih-$($Crop.Top)-$($Crop.Bottom):x=$($Crop.Left):y=$($Crop.Top)"
#         Write-Verbose "Фильтр обрезки: ${cropFilter}"
#     }
    
#     $trimFilter = ''
#     if ($TrimStartSeconds -gt 0 -or $DurationSeconds -gt 0) {
#         $trimFilter = if ($DurationSeconds -gt 0) {
#             "trim=start=${TrimStartSeconds}:duration=${DurationSeconds}"
#         } else {
#             "trim=start=${TrimStartSeconds}"
#         }
#         Write-Verbose "Фильтр времени: ${trimFilter}"
#     }
    
#     # Базовые фильтры для таймингов (без format - он добавляется в Build-MetricFilterGraph)
#     $baseFilter = "settb=AVTB,setpts=PTS-STARTPTS"
#     $commonFilters = @($trimFilter, $baseFilter) -ne '' -join ','
    
#     # Собираем фильтры для каждого потока (только CPU-фильтры, которые должны быть ДО hwupload)
#     $distFilters = @()
#     if ($Crop.CropDistVideo -and $cropFilter) { $distFilters += $cropFilter }
#     if ($commonFilters) { $distFilters += $commonFilters }
#     $distFilterStr = $distFilters -join ','
    
#     $refFilters = @()
#     if ($cropFilter) { $refFilters += $cropFilter }
#     if ($commonFilters) { $refFilters += $commonFilters }
#     $refFilterStr = $refFilters -join ','
    
#     # Строим граф фильтров для ffmpeg с поддержкой GPU
#     $filterGraph = Build-MetricFilterGraph `
#         -DistFilter $distFilterStr `
#         -RefFilter $refFilterStr `
#         -RefToneMapping $RefToneMapping `
#         -MetricList $Metrics `
#         -ModelVersion $ModelVersion `
#         -ThreadCount $Threads `
#         -Subsample $Subsample `
#         -PoolMethod $PoolMethod `
#         -LogPath $LogPath `
#         -UseGPU $UseGPU
    
#     if ($filterGraph) {
#         Write-Verbose "Граф фильтров: ${filterGraph}"
#     }
    
#     # Подготавливаем параметры обрезки для SSIMULACRA2
#     $ssimCropArgs = @()
#     if ($Crop.Left -or $Crop.Right -or $Crop.Top -or $Crop.Bottom) {
#         # Для референса используем обрезку всегда
#         $ssimCropArgs += "--cropTopSource", $Crop.Top
#         $ssimCropArgs += "--cropBottomSource", $Crop.Bottom
#         $ssimCropArgs += "--cropLeftSource", $Crop.Left
#         $ssimCropArgs += "--cropRightSource", $Crop.Right
        
#         # Для дисторшена обрезаем только если указано
#         if ($Crop.CropDistVideo) {
#             $ssimCropArgs += "--cropTopEncoded", $Crop.Top
#             $ssimCropArgs += "--cropBottomEncoded", $Crop.Bottom
#             $ssimCropArgs += "--cropLeftEncoded", $Crop.Left
#             $ssimCropArgs += "--cropRightEncoded", $Crop.Right
#         }
#         Write-Verbose "SSIMULACRA2 обрезка: Source [$($Crop.Left),$($Crop.Top),$($Crop.Right),$($Crop.Bottom)] Encoded: $(if ($Crop.CropDistVideo) { 'Да' } else { 'Нет' })"
#     }
    
#     # Предупреждение о тонмаппинге для SSIMULACRA2
#     if ($useSSIM -and $RefToneMapping) {
#         Write-Warning "SSIMULACRA2 НЕ использует тонмаппинг reference видео. Тонмаппинг применяется ТОЛЬКО для ffmpeg метрик."
#     }
    
#     # Путь к ffmpeg
#     $ffmpeg = (Get-Command ffmpeg9.exe -ErrorAction Stop).Source
    
#     # Заголовок
#     Write-Host "`n========================================" -ForegroundColor Cyan
#     Write-Host "  АНАЛИЗ КАЧЕСТВА ВИДЕО" -ForegroundColor Cyan
#     Write-Host "========================================" -ForegroundColor Cyan
#     Write-Host "Файлов: $($DistortedPaths.Count)" -ForegroundColor White
#     Write-Host "Метрики: $($Metrics -join ', ')" -ForegroundColor White
#     Write-Host "GPU-ускорение: $(if ($UseGPU) { 'Включено (CUDA+Vulkan)' } else { 'Выключено' })" -ForegroundColor $(if ($UseGPU) { 'Green' } else { 'Yellow' })
#     if ($RefToneMapping) {
#         Write-Host "Тонмаппинг HDR->SDR: libplacebo=$RefToneMapping" -ForegroundColor Yellow
#         Write-Host "  Применяется ТОЛЬКО к reference видео" -ForegroundColor DarkGray
#     }
#     if ($useSSIM) {
#         Write-Host "SSIMULACRA2: GPU ${SSIMGPUID}, every ${SSIMEvery} frames" -ForegroundColor Magenta
#         if ($ssimCropArgs) {
#             Write-Host "  Crop: Source ($($Crop.Left),$($Crop.Top),$($Crop.Right),$($Crop.Bottom))" -ForegroundColor DarkGray
#             if (-not $Crop.CropDistVideo) {
#                 Write-Host "  Encoded crop: Disabled (use CropDistVideo to enable)" -ForegroundColor DarkGray
#             }
#         }
#     }
#     Write-Host "========================================" -ForegroundColor Cyan
    
#     $results = [System.Collections.Generic.List[PSObject]]::new()
#     $totalFiles = $DistortedPaths.Count
    
#     for ($i = 0; $i -lt $totalFiles; $i++) {
#         $path = $DistortedPaths[$i]
#         $num = $i + 1
#         $fileName = [IO.Path]::GetFileName($path)
        
#         Write-Progress -Activity "Расчет метрик" -Status "[$num/$totalFiles] ${fileName}" -PercentComplete (($num / $totalFiles) * 100)
#         Write-Host "[$num/$totalFiles] ${fileName}" -ForegroundColor Yellow
        
#         $result = [PSCustomObject]@{ 
#             DistortedPath = $path
#             VMAF          = $null
#             VMAFNeg       = $null
#             XPSNR         = $null
#             PSNR          = $null
#             SSIM          = $null
#             SSIMULACRA2   = $null
#             Time          = $null
#         }
        
#         $distType = $distInfo[$path].Type
#         $distFPS = $distInfo[$path].FPS
        
#         # Формируем аргументы для ffmpeg с поддержкой GPU
#         $distArgs = @('-r', $distFPS.ToString().Replace(',', '.'))
#         if ($distType -eq 'VapourSynth') { $distArgs += '-f', 'vapoursynth' }
#         elseif ($distType -eq 'AviSynth') { $distArgs += '-f', 'avisynth' }
#         $distArgs += '-i', $path
        
#         $refArgs = @('-r', $refFPS.ToString().Replace(',', '.'))
#         if ($refType -eq 'VapourSynth') { $refArgs += '-f', 'vapoursynth' }
#         elseif ($refType -eq 'AviSynth') { $refArgs += '-f', 'avisynth' }
#         $refArgs += '-i', $ReferencePath
        
#         # Добавляем GPU-параметры если включено
#         $gpuArgs = @()
#         if ($UseGPU) {
#             $gpuArgs = @(
#                 '-init_hw_device', 'cuda=cu:0',
#                 '-init_hw_device', 'vulkan=vk@cu',
#                 '-hwaccel', 'cuda',
#                 '-hwaccel_output_format', 'cuda'
#             )
#             # Уменьшаем потоки CPU при GPU-ускорении
#             $threadsToUse = [Math]::Min(4, $Threads)
#         } else {
#             $threadsToUse = $Threads
#         }
        
#         # Запускаем ffmpeg если есть метрики
#         if ($filterGraph) {
#             $ffargs = @(
#                 "-threads", $threadsToUse,
#                 "-hide_banner", "-y", "-nostats"
#             ) + $gpuArgs + $distArgs + $refArgs + @(
#                 "-filter_complex", $filterGraph,
#                 "-f", "null", "-"
#             )
            
#             Write-Verbose "Запуск ffmpeg для ${fileName}"
#             Write-Verbose "FFmpeg args: $($ffargs -join ' ')"
            
#             $timer = [System.Diagnostics.Stopwatch]::StartNew()
#             $output = & $ffmpeg $ffargs 2>&1
#             $timer.Stop()
#             $result.Time = $timer
#             $outputStr = $output -join "`n"
            
#             # Парсим результаты
#             if ($Metrics -contains 'VMAF') {
#                 $vmafMatches = [regex]::Matches($outputStr, 'VMAF score:\s*(\d+\.\d+)')
#                 if ($vmafMatches.Count -ge 1) {
#                     $result.VMAF = [double]$vmafMatches[0].Groups[1].Value
#                     Write-Host "  VMAF: $($result.VMAF)" -ForegroundColor Green
#                 }
#                 if ($vmafMatches.Count -ge 2) {
#                     $result.VMAFNeg = [double]$vmafMatches[1].Groups[1].Value
#                     Write-Host "  VMAF (harm): $($result.VMAFNeg)" -ForegroundColor Cyan
#                 }
#             }
            
#             if ($Metrics -contains 'XPSNR' -and $outputStr -match 'XPSNR.*y:\s*(\d+\.\d+).*u:\s*(\d+\.\d+).*v:\s*(\d+\.\d+)') {
#                 $result.XPSNR = @{
#                     Y = [double]$Matches[1]
#                     U = [double]$Matches[2]
#                     V = [double]$Matches[3]
#                     WSUM = (4 * [double]$Matches[1] + [double]$Matches[2] + [double]$Matches[3]) / 6
#                 }
#                 Write-Host "  XPSNR: $($result.XPSNR.WSUM.ToString('F2'))" -ForegroundColor Green
#             }
            
#             if ($Metrics -contains 'PSNR' -and $outputStr -match 'PSNR.*y:\s*(\d+\.\d+).*u:\s*(\d+\.\d+).*v:\s*(\d+\.\d+)') {
#                 $result.PSNR = @{
#                     Y = [double]$Matches[1]
#                     U = [double]$Matches[2]
#                     V = [double]$Matches[3]
#                     WSUM = (4 * [double]$Matches[1] + [double]$Matches[2] + [double]$Matches[3]) / 6
#                 }
#                 Write-Host "  PSNR: $($result.PSNR.WSUM.ToString('F2'))" -ForegroundColor Green
#             }
            
#             if ($Metrics -contains 'SSIM') {
#                 if ($outputStr -match 'SSIM.*All:\s*(\d+\.\d+)') {
#                     $result.SSIM = [double]$Matches[1]
#                     Write-Host "  SSIM: $($result.SSIM.ToString('F4'))" -ForegroundColor Green
#                 }
#                 elseif ($outputStr -match 'SSIM.*y:\s*(\d+\.\d+).*u:\s*(\d+\.\d+).*v:\s*(\d+\.\d+)') {
#                     $result.SSIM = [PSCustomObject]@{
#                         Y = [double]$Matches[1]
#                         U = [double]$Matches[2]
#                         V = [double]$Matches[3]
#                         AVG = ([double]$Matches[1] + [double]$Matches[2] + [double]$Matches[3]) / 3
#                     }
#                     Write-Host "  SSIM: $($result.SSIM.AVG.ToString('F4'))" -ForegroundColor Green
#                 }
#             }
#         }
        
#         # SSIMULACRA2 (всегда последовательно)
#         if ($useSSIM) {
#             Write-Host "  SSIMULACRA2..." -ForegroundColor Magenta -NoNewline
            
#             # Базовые аргументы
#             $ssimArgs = @(
#                 "--source", $ReferencePath,
#                 "--encoded", $path,
#                 "--metric", "SSIMULACRA2",
#                 "--every", $SSIMEvery,
#                 "--threads", 2,
#                 "--gpu-threads", $SSIMGPUThreads,
#                 "--gpu-id", $SSIMGPUID
#                 if ($SSIMCacheIndex) {'--cache-index'}
#             )
            
#             # Добавляем параметры обрезки
#             if ($ssimCropArgs) {
#                 $ssimArgs += $ssimCropArgs
#             }
            
#             # Добавляем кэширование индексов
#             if ($SSIMCacheIndex) { 
#                 $ssimArgs += "--cache-index" 
#             }
            
#             Write-Verbose "SSIMULACRA2 args: $($ssimArgs -join ' ')"
            
#             $timer = [System.Diagnostics.Stopwatch]::StartNew()
#             $output = & $FFVshipPath $ssimArgs 2>&1
#             $timer.Stop()
            
#             if ($LASTEXITCODE -eq 0) {
#                 $outStr = $output -join "`n"
#                 $ssimData = @{}
                
#                 if ($outStr -match 'Average\s*:\s*(-?[\d.]+)') { $ssimData['Average'] = [double]$Matches[1] }
#                 if ($outStr -match 'Standard Deviation\s*:\s*(-?[\d.]+)') { $ssimData['StdDev'] = [double]$Matches[1] }
#                 if ($outStr -match 'Median\s*:\s*(-?[\d.]+)') { $ssimData['Median'] = [double]$Matches[1] }
#                 if ($outStr -match '5th percentile\s*:\s*(-?[\d.]+)') { $ssimData['P5'] = [double]$Matches[1] }
#                 if ($outStr -match '95th percentile\s*:\s*(-?[\d.]+)') { $ssimData['P95'] = [double]$Matches[1] }
#                 if ($outStr -match 'Minimum\s*:\s*(-?[\d.]+)') { $ssimData['Min'] = [double]$Matches[1] }
#                 if ($outStr -match 'Maximum\s*:\s*(-?[\d.]+)') { $ssimData['Max'] = [double]$Matches[1] }
#                 if ($outStr -match 'Computed (\d+) frames') { $ssimData['Frames'] = [int]$Matches[1] }
                
#                 if ($ssimData.Count -gt 0) {
#                     $result.SSIMULACRA2 = [PSCustomObject]$ssimData
#                     Write-Host " $($result.SSIMULACRA2.Average.ToString('F2')) (avg)" -ForegroundColor Green
#                     Write-Verbose "SSIMULACRA2: $($result.SSIMULACRA2 | ConvertTo-Json -Compress)"
#                 } else {
#                     Write-Host " FAILED (parse)" -ForegroundColor Red
#                 }
#             } else {
#                 Write-Host " FAILED (code $LASTEXITCODE)" -ForegroundColor Red
#                 Write-Verbose "SSIMULACRA2 output: $($output -join "`n")"
#             }
#         }
        
#         $results.Add($result)
#     }
    
#     Write-Progress -Completed    
#     # Краткая сводка
#     Write-Host "`n========================================" -ForegroundColor Cyan
#     Write-Host "  РЕЗУЛЬТАТЫ" -ForegroundColor Cyan
#     Write-Host "========================================" -ForegroundColor Cyan
    
#     foreach ($r in $results) {
#         $name = [IO.Path]::GetFileName($r.DistortedPath)
#         $time = if ($r.Time) { "$([Math]::Round($r.Time.Elapsed.TotalSeconds, 1))s" } else { "N/A" }
        
#         Write-Host "  $name [$time]" -ForegroundColor Gray
#         if ($r.VMAF) { 
#             $color = if ($r.VMAF -gt 90) { 'Green' } elseif ($r.VMAF -gt 80) { 'Yellow' } else { 'Gray' }
#             Write-Host "    VMAF: $($r.VMAF.ToString('F2'))" -ForegroundColor $color 
#         }
#         if ($r.VMAFNeg) { Write-Host "    VMAF(h): $($r.VMAFNeg.ToString('F2'))" -ForegroundColor Cyan }
#         if ($r.XPSNR)   { Write-Host "    XPSNR  : $($r.XPSNR.WSUM.ToString('F2'))" -ForegroundColor Gray }
#         if ($r.PSNR)    { Write-Host "    PSNR   : $($r.PSNR.WSUM.ToString('F2'))" -ForegroundColor Gray }
#         if ($r.SSIM) { 
#             $ssimVal = if ($r.SSIM -is [double]) { $r.SSIM } else { $r.SSIM.AVG }
#             Write-Host "    SSIM : $($ssimVal.ToString('F4'))" -ForegroundColor Gray
#         }
#         if ($r.SSIMULACRA2) { 
#             Write-Host "    SSIM2: $($r.SSIMULACRA2.Average.ToString('F2')) [p5: $($r.SSIMULACRA2.P5.ToString('F2')), p95: $($r.SSIMULACRA2.P95.ToString('F2'))]" -ForegroundColor Magenta
#         }
#         Write-Host ""
#     }
#     Write-Host "========================================" -ForegroundColor Cyan
    
#     return $results
# }
#endregon


#endregion

# Экспорт функций
Export-ModuleMember -Function Get-VideoQualityMetrics3

#region Using Examples
<# 
# Пример 1: HDR->SDR сравнение с GPU (только VMAF)
[PSCustomObject]$CropPrm = @{
    Left          = 0
    Right         = 0
    Top           = 0
    Bottom        = 0
    CropDistVideo = $false
}

$ref = "hdr_source.mkv"
$dist = "sdr_encoded.mkv"

# Базовый тонмаппинг bt.2390
$res = Get-VideoQualityMetrics3 -DistortedPaths $dist -ReferencePath $ref -Metrics VMAF -RefToneMapping "tonemapping=bt.2390:peak_detect=false:desat=0" -UseGPU $true

# Тонмаппинг hable (более мягкий)
$res = Get-VideoQualityMetrics3 -DistortedPaths $dist -ReferencePath $ref -Metrics VMAF,PSNR,SSIM -RefToneMapping "tonemapping=hable:peak_detect=false:desat=0:contrast_recovery=0.3" -UseGPU $true

# Пример 2: Сравнение с SSIMULACRA2 (предупреждение о тонмаппинге)
$res = Get-VideoQualityMetrics3 -DistortedPaths $dist -ReferencePath $ref -Metrics All -RefToneMapping "tonemapping=bt.2390:peak_detect=false:desat=0" -UseGPU $true

# Пример 3: CPU-режим (если GPU недоступен)
$res = Get-VideoQualityMetrics3 -DistortedPaths $dist -ReferencePath $ref -Metrics VMAF -UseGPU $false

# Примечание: 
# - Тонмаппинг применяется ТОЛЬКО к reference видео для ffmpeg метрик
# - SSIMULACRA2 работает напрямую с исходными файлами (без тонмаппинга)
# - Для GPU требуется ffmpeg с поддержкой cuda, vulkan, libplacebo
# - НЕ ДОБАВЛЯЙТЕ format= в RefToneMapping - он добавляется автоматически
#>
#endregion