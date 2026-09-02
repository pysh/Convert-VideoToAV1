<#
.SYNOPSIS
    Конвертирует видеофайлы в AV1/HEVC с сохранением всех метаданных
.DESCRIPTION
    Универсальный конвейер обработки видео:
    1. Demux - извлечение всех потоков в рабочую директорию
    2. Audio - перекодирование аудио в Opus/AAC (или копирование)
    3. Video - кодирование видео выбранным энкодером через VapourSynth
    4. Mux - сборка итогового MKV файла
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, Position = 0, ParameterSetName = 'Directory')]
    [string]$InputDirectory,
    
    [Parameter(Mandatory = $false, Position = 0, ParameterSetName = 'File')]
    [string]$InputFile,
    
    [Parameter(Mandatory = $false)]
    [string[]]$InputFiles,
    
    [Parameter(Mandatory = $false)]
    [string]$OutputDirectory,
    
    [Parameter(Mandatory = $false)]
    [string]$TempDirectory = 'R:\.temp\',
    
    [Parameter(Mandatory = $false)]
    [string]$InputFilter,
    
    [Parameter(Mandatory = $false)]
    [double]$TrimStartSeconds = 0,
    
    [Parameter(Mandatory = $false)]
    [double]$TrimEndSeconds = 0,
    
    [Parameter(Mandatory = $false)]
    [string]$TrimTimecode,
    
    [Parameter(Mandatory = $false)]
    [switch]$CopyAudio,
    
    [Parameter(Mandatory = $false)]
    [switch]$CopyVideo,
    
    [Parameter(Mandatory = $false)]
    [PSCustomObject]$CropParameters,
    
    [Parameter(Mandatory = $false)]
    [string]$Encoder = 'SvtAv1Enc.grain',
    
    [Parameter(Mandatory = $false)]
    [string]$CustomTemplatePath,
    
    [Parameter(Mandatory = $false)]
    [switch]$Force,
    
    [Parameter(Mandatory = $false)]
    [switch]$ListEncoders,
    
    [Parameter(Mandatory = $false)]
    [switch]$KeepTempFiles,

    [Parameter(Mandatory = $false)]
    [switch]$SkipMetrics,
    
    [Parameter(Mandatory = $false)]
    [int]$MaxConcurrentJobs = 1
)

begin {
    Write-Host @'
  ____                          _     __     ___     _          _____       ___     ___ 
 / ___|___  _ ____   _____ _ __| |_   \ \   / (_) __| | ___  __|_   _|__   / \ \   / / |
| |   / _ \| '_ \ \ / / _ \ '__| __|___\ \ / /| |/ _` |/ _ \/ _ \| |/ _ \ / _ \ \ / /| |
| |__| (_) | | | \ V /  __/ |  | |______\ V / | | (_| |  __/ (_) | | (_) / ___ \ V / | |
 \____\___/|_| |_|\_/ \___|_|   \__|     \_/  |_|\__,_|\___|\___/|_|\___/_/   \_\_/  |_|
'@ -ForegroundColor DarkBlue
    $error.Clear()
    # Импорт модулей
    $modulesPath = Join-Path $PSScriptRoot 'Modules'
    $requiredModules = @(
        'Utilities.psm1',
        'ColorProcessor.psm1',
        'DemuxProcessor.psm1',
        'NfoProcessor.psm1',
        'AudioProcessor.psm1',
        'VideoProcessor.psm1',
        'MuxProcessor.psm1',
        'QualityMetrics.psm1'
    )
    
    foreach ($module in $requiredModules) {
        $modulePath = Join-Path $modulesPath $module
        if (-not (Test-Path -LiteralPath $modulePath)) {
            throw "Module not found: $modulePath"
        }
        Import-Module $modulePath -Force -ErrorAction Stop
        Write-Verbose "Imported module: $module"
    }
    
    # Инициализация конфигурации
    $configPath = Join-Path $PSScriptRoot 'config.psd1'
    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "Configuration file not found: $configPath"
    }
    
    $global:Config = Import-PowerShellDataFile -Path $configPath
    $global:VideoTools = $global:Config.Tools
    
    Write-Log "Configuration loaded: $configPath" -Severity Success -Category 'Config'
    
    # Показ списка энкодеров
    if ($ListEncoders) {
        Write-Host "`nAvailable encoders:" -ForegroundColor Cyan
        Write-Host ('=' * 50) -ForegroundColor Cyan
        
        $availableEncoders = Get-AvailableEncoders -Format 'Display'
        foreach ($enc in $availableEncoders) {
            Write-Host "$($enc.FullName)" -ForegroundColor Green -NoNewline
            Write-Host " - $($enc.DisplayName)" -ForegroundColor White
        }
        exit 0
    }
    
    # Переопределение конфигурации параметрами скрипта
    if ($CopyAudio) { $global:Config.Encoding.Audio.CopyAudio = $true }
    if ($CopyVideo) { $global:Config.Encoding.Video.CopyVideo = $true }
    if ($PSBoundParameters.ContainsKey('Encoder')) { $global:Config.Encoding.DefaultEncoder = $Encoder }
    
    # Валидация энкодера
    $encoderCheck = Test-EncoderPreset -EncoderName $Encoder
    if (-not $encoderCheck.IsAvailable) {
        throw "Encoder '$Encoder' not found. Use -ListEncoders to see available options."
    }
    
    # Определение режима работы и установка путей
    $isSingleFileMode = $false
    $filesToProcess = @()
    
    if ($InputFile) {
        # Режим обработки одного файла
        $isSingleFileMode = $true
        if (-not (Test-Path -LiteralPath $InputFile)) {
            throw "Input file not found: $InputFile"
        }
        $filesToProcess = @(Get-Item -LiteralPath $InputFile)
        if (-not $OutputDirectory) {
            $OutputDirectory = [IO.Path]::Combine([IO.Path]::GetDirectoryName($InputFile), '.enc')
        }
    }
    elseif ($InputFiles -and $InputFiles.Count -gt 0) {
        # Режим обработки списка файлов
        $isSingleFileMode = $true
        foreach ($file in $InputFiles) {
            if (Test-Path -LiteralPath $file) {
                $filesToProcess += Get-Item -LiteralPath $file
            } else {
                Write-Log "File not found: $file" -Severity Warning -Category 'Main'
            }
        }
        if ($filesToProcess.Count -eq 0) {
            throw "No valid input files found"
        }
        if (-not $OutputDirectory) {
            $OutputDirectory = [IO.Path]::Combine([IO.Path]::GetDirectoryName($filesToProcess[0].FullName), '.enc')
        }
    }
    elseif ($InputDirectory) {
        # Режим обработки директории (оригинальный режим)
        if (-not (Test-Path -LiteralPath $InputDirectory)) {
            throw "Input directory not found: $InputDirectory"
        }
        if (-not $OutputDirectory) {
            $OutputDirectory = Join-Path $InputDirectory '.enc'
        }
    }
    else {
        # Попытка использовать директорию из конфига
        $InputDirectory = $global:Config.Paths.DefaultInputDirectory
        if (-not $InputDirectory) {
            throw "Input directory not specified and no default in config"
        }
        if (-not $OutputDirectory) {
            $OutputDirectory = Join-Path $InputDirectory '.enc'
        }
    }
    
    # Создание выходной директории
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
    
    # Проверка инструментов
    Write-Log "Checking required tools..." -Severity Information -Category 'Main'
    foreach ($tool in $global:VideoTools.GetEnumerator()) {
        if (-not (Get-Command $tool.Value -ErrorAction SilentlyContinue)) {
            throw "Tool not found: $($tool.Name) -> $($tool.Value)"
        }
        Write-Verbose "$($tool.Name): $($tool.Value)"
    }
    
    Write-Log "Configuration loaded. Encoder: $Encoder" -Severity Information -Category 'Main'
}

process {
    try {
        # Определение списка файлов для обработки
        $supportedFormats = @('.mkv', '.mp4', '.avi', '.mov', '.m4v', '.ts', '.m2ts')
        
        if ($isSingleFileMode -and $filesToProcess.Count -gt 0) {
            # Режим обработки конкретных файлов
            $videoFiles = $filesToProcess | Where-Object {
                $_.Extension.ToLower() -in $supportedFormats
            }
        }
        else {
            # Режим обработки директории (оригинальный режим)
            $videoFiles = Get-ChildItem -LiteralPath $InputDirectory -File | Where-Object {
                $_.Extension.ToLower() -in $supportedFormats -and
                $_.Name -notmatch '_out\.mkv$' -and
                ($_.Name -match $InputFilter -or -not $InputFilter)
            } | Sort-Object $_.FullName
        }
        
        if (-not $videoFiles) {
            Write-Log "No video files found" -Severity Warning -Category 'Main'
            return
        }
        
        Write-Log "Found files: $($videoFiles.Count)" -Severity Information -Category 'Main'
        
        # Обработка файлов с поддержкой многопоточности
        if ($MaxConcurrentJobs -gt 1) {
            Write-Log "Processing with $MaxConcurrentJobs concurrent jobs..." -Severity Information -Category 'Main'
            
            # Создаем скриптблок для обработки одного файла
            $processScriptBlock = {
                param($videoFile, $OutputDirectory, $TempDirectory, $Encoder, $CustomTemplatePath, 
                      $CropParameters, $TrimStartSeconds, $TrimEndSeconds, $TrimTimecode,
                      $CopyAudio, $CopyVideo, $KeepTempFiles, $SkipMetrics, $Force)
                
                # Импортируем конфигурацию и модули в рамках задачи
                $PSScriptRoot = $using:PSScriptRoot
                $modulesPath = Join-Path $PSScriptRoot 'Modules'
                $requiredModules = @(
                    'Utilities.psm1',
                    'ColorProcessor.psm1',
                    'DemuxProcessor.psm1',
                    'NfoProcessor.psm1',
                    'AudioProcessor.psm1',
                    'VideoProcessor.psm1',
                    'MuxProcessor.psm1',
                    'QualityMetrics.psm1'
                )
                
                foreach ($module in $requiredModules) {
                    $modulePath = Join-Path $modulesPath $module
                    Import-Module $modulePath -Force -ErrorAction Stop
                }
                
                $configPath = Join-Path $PSScriptRoot 'config.psd1'
                $global:Config = Import-PowerShellDataFile -Path $configPath
                $global:VideoTools = $global:Config.Tools
                
                # Переопределение конфигурации параметрами
                if ($CopyAudio) { $global:Config.Encoding.Audio.CopyAudio = $true }
                if ($CopyVideo) { $global:Config.Encoding.Video.CopyVideo = $true }
                
                $job = $null
                
                try {
                    Write-Log "`n" -Severity Information -Category 'Main'
                    Write-Log "Processing: $($videoFile.Name)" -Severity Information -Category 'Main'
                    Write-Log ('=' * 60) -Severity Information -Category 'Main'
                    
                    $baseName = [IO.Path]::GetFileNameWithoutExtension($videoFile.Name)
                    $workingDir = Join-Path $TempDirectory ("$baseName.tmp" | ConvertTo-LatinTranslit -Standard Passport)
                    
                    # Очистка и создание рабочей директории
                    if (Test-Path -LiteralPath $workingDir) {
                        Remove-Item -LiteralPath $workingDir -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    New-Item -ItemType Directory -Path $workingDir -Force | Out-Null
                    
                    # Инициализация Job
                    $job = [ordered]@{
                        WorkingDir = $workingDir
                        OriginalPath = $videoFile.FullName
                        BaseName = $baseName
                        TempFiles = [System.Collections.Generic.List[string]]::new()
                        StartTime = Get-Date
                        EncoderName = $Encoder
                        TrimStartSeconds = $TrimStartSeconds
                        TrimDurationSeconds = 0
                        CropParameters = $CropParameters
                    }
                    
                    # Расчет продолжительности при обрезке
                    if ($TrimTimecode) {
                        $job.TrimStartSeconds = ConvertTo-Seconds -TimeString $TrimTimecode
                    }
                    if ($TrimStartSeconds -gt 0 -and $TrimEndSeconds -gt 0) {
                        $job.TrimDurationSeconds = $TrimEndSeconds - $TrimStartSeconds
                    }
                    
                    # Копирование NFO файла
                    $nfoSource = [IO.Path]::ChangeExtension($videoFile.FullName, 'nfo')
                    if (Test-Path -LiteralPath $nfoSource) {
                        $nfoDestination = Join-Path $workingDir "$baseName.nfo"
                        Copy-Item -LiteralPath $nfoSource $nfoDestination -Force
                        $job.NfoPath = $nfoDestination
                        $job.TempFiles.Add($nfoDestination)
                    }
                    
                    # 1. ДЕМУКС - извлечение всех потоков
                    Write-Log "`n[1/6] DEMUX" -Severity Information -Category 'Main'
                    $job = Invoke-Demux -Job $job
                    
                    # Получение FrameRate для обрезки
                    $job.FrameRate = Get-VideoFrameRate -VideoPath $job.VideoSource
                    
                    # 2. ОБРАБОТКА NFO
                    Write-Log "`n[2/6] METADATA" -Severity Information -Category 'Main'
                    $job = Invoke-NfoProcessing -Job $job
                    
                    # 3. ОБРАБОТКА АУДИО
                    Write-Log "`n[3/6] AUDIO" -Severity Information -Category 'Main'
                    $job = ConvertTo-Audio -Job $job
                    
                    # 4. ОБРАБОТКА ВИДЕО
                    Write-Log "`n[4/6] VIDEO" -Severity Information -Category 'Main'
                    $job = ConvertTo-Video -Job $job -TemplatePath $CustomTemplatePath
                    
                    # 5. РАСЧЕТ МЕТРИК
                    if (-not $SkipMetrics) {
                        Write-Log "`n[5/6] CALCULATE METRICS (Crop parameters: $($job.CropParameters))" -Severity Information -Category 'Main'
                        $metrics = Get-VideoQualityMetrics3 `
                            -ReferencePath $job.VideoSource -DistortedPaths $job.VideoEncoded `
                            -Metrics VMAF,SSIMULACRA2 `
                            -Crop $job.CropParameters `
                            -Subsample 9
                        $job.Metrics = $metrics
                        Write-Log $metrics -Severity Information -Category 'Main'
                    }

                    # 6. СБОРКА ФИНАЛЬНОГО ФАЙЛА
                    Write-Log "`n[6/6] MUXING" -Severity Information -Category 'Main'
                    
                    # Формирование имени выходного файла
                    $encoderCode = Get-EncoderCode -EncoderName $job.EncoderName
                    
                    if ($job.NfoFields -and $job.NfoFields.SHOWTITLE) {
                        $showTitle = $job.NfoFields.SHOWTITLE -replace '[\\/*?:"<>|]', '_'
                        $season = [int]($job.NfoFields.SEASON_NUMBER ?? 1)
                        $episode = [int]($job.NfoFields.PART_NUMBER ?? 1)
                        $title = ($job.NfoFields.TITLE -replace '[\\/*?:"<>|]', '_') ?? 'Episode'
                        $airDate = $job.NfoFields.AIR_DATE ?? $job.NfoFields.DATE_RELEASED ?? 'Unknown'
                        
                        # Получение разрешения видео
                        $videoInfo = Get-VideoStats -VideoFilePath $job.VideoSource
                        $width = $videoInfo.ResolutionWidth
                        $height = $videoInfo.ResolutionHeight
                        
                        $resolution = switch ($width) {
                            { $_ -gt 3840 } { "8k"; break }
                            { $_ -gt 2560 } { "4k"; break }
                            { $_ -gt 1920 } { "2k"; break }
                            { $_ -gt 1280 } { "1080p"; break }
                            default { "${height}p" }
                        }
                        
                        $outputFileName = "{0} - s{1:00}e{2:00} - {3} [{4}][{5}][{6}].mkv" -f 
                            $showTitle, $season, $episode, $title, $airDate, $resolution, $encoderCode
                    } else {
                        $outputFileName = "$($job.BaseName)_[$encoderCode].mkv"
                    }
                    
                    $job.FinalOutput = Join-Path $OutputDirectory $outputFileName
                    
                    # Проверка существования выходного файла
                    if (-not $Force -and (Test-Path -LiteralPath $job.FinalOutput)) {
                        throw "Output file already exists: $outputFileName (use -Force to overwrite)"
                    }
                    
                    $job = Invoke-Mux -Job $job
                    
                    $job | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath ("$($job.FinalOutput).json") -Force

                    # Итоговая статистика
                    $duration = [DateTime]::Now - $job.StartTime
                    $outputSize = (Get-Item -LiteralPath $job.FinalOutput).Length / 1MB
                    
                    Write-Log "`n" -Severity Information -Category 'Main'
                    Write-Log "COMPLETED!" -Severity Success -Category 'Main'
                    Write-Log "  File: $([IO.Path]::GetFileName($job.FinalOutput))" -Severity Success -Category 'Main'
                    Write-Log "  Size: $($outputSize.ToString('N2')) MB" -Severity Success -Category 'Main'
                    Write-Log "  Time: $($duration.ToString('hh\:mm\:ss'))" -Severity Success -Category 'Main'
                    Write-Log ('=' * 60) -Severity Information -Category 'Main'

                    # Удаляем временные файлы только если итоговый файл создан
                    if ($job -and -not $KeepTempFiles -and $global:Config.Processing.DeleteTempFiles) {
                        foreach ($file in $job.TempFiles) {
                            if (Test-Path -LiteralPath $file) {
                                Write-Log "Deleting temporary file: $file" -Severity Verbose -Category 'Main'
                                Remove-Item -LiteralPath $file -Recurse -Force -ErrorAction SilentlyContinue
                            }
                        }
                        if (Test-Path -LiteralPath $job.WorkingDir) {
                            if (-not (Get-ChildItem -LiteralPath $job.WorkingDir -Recurse -File)) {
                                Remove-Item -LiteralPath $job.WorkingDir -Recurse -Force -ErrorAction SilentlyContinue
                            }
                        }
                    }
                    
                    return $job
                }
                catch {
                    Write-Log "ERROR processing $($videoFile.Name): $($_.Exception.Message)" -Severity Error -Category 'Main'
                    Write-Log $_.ScriptStackTrace -Severity Debug -Category 'Main'
                    throw
                }
                finally {
                    $global:Job = $job
                }
            }
            
            # Подготовка аргументов для каждой задачи и запуск с ограничением MaxConcurrentJobs
            $runningJobs = @()
            $allResults = @()
            
            Write-Log "Starting parallel processing with max $MaxConcurrentJobs concurrent jobs..." -Severity Information -Category 'Main'
            
            foreach ($videoFile in $videoFiles) {
                # Ждем, если достигнут лимит одновременных задач
                while ($runningJobs.Count -ge $MaxConcurrentJobs) {
                    # Находим завершенные задачи
                    $completed = @()
                    foreach ($job in $runningJobs) {
                        if ($job.State -ne 'Running') {
                            $completed += $job
                        }
                    }
                    
                    # Обрабатываем завершенные задачи
                    foreach ($job in $completed) {
                        try {
                            $result = Receive-Job -Job $job -Wait -AutoRemoveJob
                            if ($result) {
                                $allResults += $result
                                Write-Log "Job completed for: $([IO.Path]::GetFileName($result.FinalOutput))" -Severity Success -Category 'Main'
                            }
                        }
                        catch {
                            Write-Log "Job failed: $($_.Exception.Message)" -Severity Error -Category 'Main'
                        }
                        $runningJobs = $runningJobs | Where-Object { $_ -ne $job }
                    }
                    
                    # Если есть еще-running jobs, ждем немного
                    if ($runningJobs.Count -ge $MaxConcurrentJobs) {
                        Start-Sleep -Milliseconds 500
                    }
                }
                
                # Создаем новую задачу
                $jobArgs = @{
                    videoFile = $videoFile
                    OutputDirectory = $OutputDirectory
                    TempDirectory = $TempDirectory
                    Encoder = $Encoder
                    CustomTemplatePath = $CustomTemplatePath
                    CropParameters = $CropParameters
                    TrimStartSeconds = $TrimStartSeconds
                    TrimEndSeconds = $TrimEndSeconds
                    TrimTimecode = $TrimTimecode
                    CopyAudio = $CopyAudio
                    CopyVideo = $CopyVideo
                    KeepTempFiles = $KeepTempFiles
                    SkipMetrics = $SkipMetrics
                    Force = $Force
                }
                
                $newJob = Start-ThreadJob -ScriptBlock $processScriptBlock -ArgumentList $jobArgs.Values
                $runningJobs += $newJob
                Write-Log "Started job for: $($videoFile.Name) (running: $($runningJobs.Count)/$MaxConcurrentJobs)" -Severity Information -Category 'Main'
            }
            
            # Ожидание завершения всех оставшихся задач
            foreach ($job in $runningJobs) {
                try {
                    $result = Receive-Job -Job $job -Wait -AutoRemoveJob
                    if ($result) {
                        $allResults += $result
                        Write-Log "Job completed for: $([IO.Path]::GetFileName($result.FinalOutput))" -Severity Success -Category 'Main'
                    }
                }
                catch {
                    Write-Log "Job failed: $($_.Exception.Message)" -Severity Error -Category 'Main'
                }
            }
        }
        else {
            # Последовательная обработка (оригинальный режим)
            foreach ($videoFile in $videoFiles) {
                $job = $null
                
                try {
                    Write-Log "`n" -Severity Information -Category 'Main'
                    Write-Log "Processing: $($videoFile.Name)" -Severity Information -Category 'Main'
                    Write-Log ('=' * 60) -Severity Information -Category 'Main'
                    
                    $baseName = [IO.Path]::GetFileNameWithoutExtension($videoFile.Name)
                $workingDir = Join-Path $TempDirectory ("$baseName.tmp" | ConvertTo-LatinTranslit -Standard Passport)
                
                # Очистка и создание рабочей директории
                if (Test-Path -LiteralPath $workingDir) {
                    Remove-Item -LiteralPath $workingDir -Recurse -Force -ErrorAction SilentlyContinue
                }
                New-Item -ItemType Directory -Path $workingDir -Force | Out-Null
                
                # Инициализация Job
                $job = [ordered]@{
                    WorkingDir = $workingDir
                    OriginalPath = $videoFile.FullName
                    BaseName = $baseName
                    TempFiles = [System.Collections.Generic.List[string]]::new()
                    StartTime = Get-Date
                    EncoderName = $Encoder
                    TrimStartSeconds = $TrimStartSeconds
                    TrimDurationSeconds = 0
                    CropParameters = $CropParameters
                }
                
                # Расчет продолжительности при обрезке
                if ($TrimTimecode) {
                    $job.TrimStartSeconds = ConvertTo-Seconds -TimeString $TrimTimecode
                }
                if ($TrimStartSeconds -gt 0 -and $TrimEndSeconds -gt 0) {
                    $job.TrimDurationSeconds = $TrimEndSeconds - $TrimStartSeconds
                }
                
                # Копирование NFO файла
                $nfoSource = [IO.Path]::ChangeExtension($videoFile.FullName, 'nfo')
                if (Test-Path -LiteralPath $nfoSource) {
                    $nfoDestination = Join-Path $workingDir "$baseName.nfo"
                    Copy-Item -LiteralPath $nfoSource $nfoDestination -Force
                    $job.NfoPath = $nfoDestination
                    $job.TempFiles.Add($nfoDestination)
                }
                
                # 1. ДЕМУКС - извлечение всех потоков
                Write-Log "`n[1/6] DEMUX" -Severity Information -Category 'Main'
                $job = Invoke-Demux -Job $job
                
                # Получение FrameRate для обрезки
                $job.FrameRate = Get-VideoFrameRate -VideoPath $job.VideoSource
                
                # 2. ОБРАБОТКА NFO
                Write-Log "`n[2/6] METADATA" -Severity Information -Category 'Main'
                $job = Invoke-NfoProcessing -Job $job
                
                # 3. ОБРАБОТКА АУДИО
                Write-Log "`n[3/6] AUDIO" -Severity Information -Category 'Main'
                $job = ConvertTo-Audio -Job $job
                
                # 4. ОБРАБОТКА ВИДЕО
                Write-Log "`n[4/6] VIDEO" -Severity Information -Category 'Main'
                $job = ConvertTo-Video -Job $job -TemplatePath $CustomTemplatePath
                
                # 5. РАСЧЕТ МЕТРИК
                if (-not $SkipMetrics) {
                    Write-Log "`n[5/6] CALCULATE METRICS (Crop parameters: $($job.CropParameters)" -Severity Information -Category 'Main'
                    $metrics =Get-VideoQualityMetrics3 `
                        -ReferencePath $job.VideoSource -DistortedPaths $job.VideoEncoded `
                        -Metrics VMAF,SSIMULACRA2  `
                        -Crop $job.CropParameters `
                        -Subsample 9
                    $job.Metrics = $metrics
                Write-Log $metrics -Severity Information -Category 'Main'
                }

                # 6. СБОРКА ФИНАЛЬНОГО ФАЙЛА
                Write-Log "`n[6/6] MUXING" -Severity Information -Category 'Main'
                
                # Формирование имени выходного файла
                $encoderCode = Get-EncoderCode -EncoderName $job.EncoderName
                
                if ($job.NfoFields -and $job.NfoFields.SHOWTITLE) {
                    $showTitle = $job.NfoFields.SHOWTITLE -replace '[\\/*?:"<>|]', '_'
                    $season = [int]($job.NfoFields.SEASON_NUMBER ?? 1)
                    $episode = [int]($job.NfoFields.PART_NUMBER ?? 1)
                    $title = ($job.NfoFields.TITLE -replace '[\\/*?:"<>|]', '_') ?? 'Episode'
                    $airDate = $job.NfoFields.AIR_DATE ?? $job.NfoFields.DATE_RELEASED ?? 'Unknown'
                    
                    # Получение разрешения видео
                    $videoInfo = Get-VideoStats -VideoFilePath $job.VideoSource
                    $width = $videoInfo.ResolutionWidth
                    $height = $videoInfo.ResolutionHeight
                    
                    $resolution = switch ($width) {
                        { $_ -gt 3840 } { "8k"; break }
                        { $_ -gt 2560 } { "4k"; break }
                        { $_ -gt 1920 } { "2k"; break }
                        { $_ -gt 1280 } { "1080p"; break }
                        default { "${height}p" }
                    }
                    
                    $outputFileName = "{0} - s{1:00}e{2:00} - {3} [{4}][{5}][{6}].mkv" -f 
                        $showTitle, $season, $episode, $title, $airDate, $resolution, $encoderCode
                } else {
                    $outputFileName = "$($job.BaseName)_[$encoderCode].mkv"
                }
                
                $job.FinalOutput = Join-Path $OutputDirectory $outputFileName
                
                # Проверка существования выходного файла
                if (-not $Force -and (Test-Path -LiteralPath $job.FinalOutput)) {
                    throw "Output file already exists: $outputFileName (use -Force to overwrite)"
                }
                
                $job = Invoke-Mux -Job $job
                
                $job | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath ("$($job.FinalOutput).json") -Force

                # Итоговая статистика
                $duration = [DateTime]::Now - $job.StartTime
                $outputSize = (Get-Item -LiteralPath $job.FinalOutput).Length / 1MB
                
                Write-Log "`n" -Severity Information -Category 'Main'
                Write-Log "COMPLETED!" -Severity Success -Category 'Main'
                Write-Log "  File: $([IO.Path]::GetFileName($job.FinalOutput))" -Severity Success -Category 'Main'
                Write-Log "  Size: $($outputSize.ToString('N2')) MB" -Severity Success -Category 'Main'
                Write-Log "  Time: $($duration.ToString('hh\:mm\:ss'))" -Severity Success -Category 'Main'
                Write-Log ('=' * 60) -Severity Information -Category 'Main'

                # Удаляем временные файлы только если итоговый файл создан
                if ($job -and -not $KeepTempFiles -and $global:Config.Processing.DeleteTempFiles) {
                    foreach ($file in $job.TempFiles) {
                        if (Test-Path -LiteralPath $file) {
                                Write-Log "Deleting temporary file: $file" -Severity Verbose -Category 'Main'
                                Remove-Item -LiteralPath $file -Recurse -Force -ErrorAction SilentlyContinue
                            }
                        }
                    }
                    if (Test-Path -LiteralPath $job.WorkingDir) {
                        if (-not (Get-ChildItem -LiteralPath $job.WorkingDir -Recurse -File)) {
                            Remove-Item -LiteralPath $job.WorkingDir -Recurse -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
            catch {
                Write-Log "ERROR processing $($videoFile.Name): $($_.Exception.Message)" -Severity Error -Category 'Main'
                Write-Log $_.ScriptStackTrace -Severity Debug -Category 'Main'
                throw
            }
            finally {
                $global:Job = $job
            }
        }
    }
    catch {
        Write-Log "Critical error: $($_.Exception.Message)" -Severity Error -Category 'Main'
        throw
    }
}

end {
    Write-Log "Processing completed" -Severity Information -Category 'Main'
}