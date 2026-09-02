<#
.SYNOPSIS
    Обрабатывает видео (кодирование или копирование)
    Поддерживает VapourSynth (.vpy) и AviSynth (.avs) фреймсерверы
#>

function ConvertTo-Video {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Job, [string]$TemplatePath)
    
    $copyVideo = $global:Config.Encoding.Video.CopyVideo
    
    if ($copyVideo) {
        Write-Log "Копирование видео без перекодирования" -Severity Information -Category 'Video'
        $Job.VideoEncoded = $Job.VideoSource
        return $Job
    }
    
    Write-Log "Кодирование видео: $($Job.EncoderName)" -Severity Information -Category 'Video'
    
    # Получение конфигурации энкодера
    $encoderConfig = Get-EncoderConfig -EncoderName $Job.EncoderName
    $Job.EncoderPath = Get-EncoderPath -EncoderName $encoderConfig.BaseEncoder
    $Job.EncoderParams = Get-EncoderParams -EncoderName $Job.EncoderName -EncoderConfig $encoderConfig
    
    # Определение выходного расширения
    $isAV1 = $Job.EncoderName -match 'Av1Enc|Rav1eEnc|AomAv1Enc'
    $isHEVC = $Job.EncoderName -match 'x265'
    
    $extension = if ($isAV1) { 'ivf' } elseif ($isHEVC) { 'hevc' } else { 'h264' }
    $Job.VideoEncoded = Join-Path $Job.WorkingDir "encoded_video.$extension"
    
    # Определение движка скриптов из конфигурации
    $scriptEngine = $global:Config.Processing.ScriptEngine ?? 'VapourSynth'
    $Job.ScriptEngine = $scriptEngine
    
    # Создание скрипта в зависимости от движка
    if ($scriptEngine -eq 'AviSynth') {
        $Job.ScriptFile = Join-Path $Job.WorkingDir "$($Job.BaseName).avs"
        $Job.CacheFile = Join-Path $Job.WorkingDir "$($Job.BaseName).dgi"
    } else {
        $Job.ScriptFile = Join-Path $Job.WorkingDir "$($Job.BaseName).vpy"
        $Job.CacheFile = Join-Path $Job.WorkingDir "$($Job.BaseName).lwi"
    }
    
    # Выбор шаблона
    $selectedTemplate = Select-Template -Job $Job -CustomPath $TemplatePath
    
    # Создание скрипта
    $scriptContent = New-VideoScript -Job $Job -TemplatePath $selectedTemplate -Engine $scriptEngine
    Set-Content -LiteralPath $Job.ScriptFile -Value $scriptContent -Force -Encoding UTF8
    $Job.TempFiles.Add($Job.ScriptFile)
    $Job.TempFiles.Add($Job.CacheFile)
    $Job.TempFiles.Add(("$($Job.VideoSource).0.bsindex"))
    $Job.TempFiles.Add(([IO.Path]::ChangeExtension($Job.VideoSource,'dgi')))
    $Job.TempFiles.Add(([IO.Path]::ChangeExtension($Job.VideoSource,'log')))
    $Job.TempFiles.Add(([IO.Path]::ChangeExtension($Job.VideoSource,'lwi')))
    
    # ============================================
    # ПОЛУЧАЕМ ИНФОРМАЦИЮ О СКРИПТЕ ДО КОДИРОВАНИЯ
    # ============================================
    try {
        $scriptInfo = Get-VideoScriptInfo -ScriptPath $Job.ScriptFile -Engine $scriptEngine
        $Job.ScriptInfo = $scriptInfo
        Write-Log "Информация о $scriptEngine скрипте: $($scriptInfo.Frames) кадров, FPS: $($scriptInfo.FPS)" -Severity Information -Category 'Video'
    }
    catch {
        Write-Log "Не удалось получить информацию о $scriptEngine скрипте: $_" -Severity Warning -Category 'Video'
        $Job.ScriptInfo = $null
    }
    
    # Запуск кодирования
    Invoke-Encoder -Job $Job
    
    # Проверка количества кадров (если есть информация для сравнения)
    if ($Job.ScriptInfo -and $Job.ScriptInfo.Frames -gt 0) {
        try {
            $encodedInfo = Get-VideoStats -VideoFilePath $Job.VideoEncoded
            if ($encodedInfo.FrameCount -ne $Job.ScriptInfo.Frames) {
                Write-Log "Предупреждение: несоответствие кадров (скрипт: $($Job.ScriptInfo.Frames), видео: $($encodedInfo.FrameCount))" `
                    -Severity Warning -Category 'Video'
            } else {
                Write-Log "Проверка кадров: OK ($($Job.ScriptInfo.Frames) кадров)" -Severity Success -Category 'Video'
            }
        }
        catch {
            Write-Log "Не удалось проверить количество кадров в закодированном видео: $_" -Severity Warning -Category 'Video'
        }
    }
    
    $Job.TempFiles.Add($Job.VideoEncoded)
    Write-Log "Кодирование завершено: $([IO.Path]::GetFileName($Job.VideoEncoded))" -Severity Success -Category 'Video'
    
    return $Job
}

function Select-Template {
    [CmdletBinding()]
    param([hashtable]$Job, [string]$CustomPath)
    
    if ($CustomPath -and (Test-Path -LiteralPath $CustomPath)) {
        Write-Log "Использование пользовательского шаблона: $CustomPath" -Severity Information -Category 'Video'
        return $CustomPath
    }
    
    $videoDir = [IO.Path]::GetDirectoryName($Job.VideoSource)
    
    # Определение движка и имени локального шаблона
    $scriptEngine = $Job.ScriptEngine ?? 'VapourSynth'
    $localTemplateName = if ($scriptEngine -eq 'AviSynth') { 'template.avs' } else { 'template.vpy' }
    $localTemplate = Join-Path $videoDir $localTemplateName
    
    if (Test-Path -LiteralPath $localTemplate) {
        Write-Log "Использование локального шаблона: $localTemplate" -Severity Information -Category 'Video'
        return $localTemplate
    }
    
    $isHDR = Test-VideoHDR -VideoPath $Job.VideoSource
    $isHEVC = $Job.EncoderName -match 'x265'
    
    $templateName = if ($isHDR) { 'HDRtoSDRScript' } 
                    elseif ($isHEVC) { 'MainHDScript' }
                    else { 'MainScript' }
    
    # Выбор секции конфигурации в зависимости от движка
    $templateSection = if ($scriptEngine -eq 'AviSynth') { 'AviSynth' } else { 'VapourSynth' }
    $relativePath = $global:Config.Templates.$templateSection[$templateName]
    
    if (-not $relativePath) {
        throw "Template path not found in config for $templateName ($templateSection)"
    }
    
    $scriptDir = Split-Path -Parent $PSScriptRoot
    $templatePath = Join-Path $scriptDir $relativePath
    
    if (-not (Test-Path -LiteralPath $templatePath)) {
        throw "Template not found: $templatePath"
    }
    
    Write-Log "Использование шаблона: $templateName ($templateSection)" -Severity Information -Category 'Video'
    return $templatePath
}

function New-VideoScript {
    [CmdletBinding()]
    param(
        [hashtable]$Job, 
        [string]$TemplatePath,
        [ValidateSet('VapourSynth', 'AviSynth')]
        [string]$Engine = 'VapourSynth'
    )
    
    $templateContent = Get-Content -LiteralPath $TemplatePath -Raw -Encoding UTF8
    
    # Параметры обрезки
    if ($Job.CropParameters) {
        $cropLeft = $Job.CropParameters.Left ?? 0
        $cropRight = $Job.CropParameters.Right ?? 0
        $cropTop = $Job.CropParameters.Top ?? 0
        $cropBottom = $Job.CropParameters.Bottom ?? 0
    } else {
        $cropLeft = $cropRight = $cropTop = $cropBottom = 0
    }
    
    # Тримминг - разный синтаксис для разных движков
    $trimScript = ''
    if ($Job.TrimStartSeconds -gt 0) {
        $startFrame = [math]::Round($Job.TrimStartSeconds * $Job.FrameRate)
        if ($Engine -eq 'AviSynth') {
            $trimScript = "Trim($startFrame, last)`n"
        } else {
            $trimScript = "clip = clip[${startFrame}:]`n"
        }
    }
    if ($Job.TrimDurationSeconds -gt 0) {
        $endFrame = [math]::Round(($Job.TrimStartSeconds + $Job.TrimDurationSeconds) * $Job.FrameRate)
        if ($Engine -eq 'AviSynth') {
            $trimScript = "Trim(0, $endFrame)`n"
        } else {
            $trimScript = "clip = clip[:${endFrame}]`n"
        }
    }
    
    # Формирование замен в зависимости от движка
    $replacements = @{
        '{VideoPath}' = $Job.VideoSource.Replace('\', '/')
        '{CacheFile}' = $Job.CacheFile.Replace('\', '/')
        '{trimScript}' = $trimScript
        '{CropLeft}' = $cropLeft
        '{CropRight}' = $cropRight
        '{CropTop}' = $cropTop
        '{CropBottom}' = $cropBottom
    }
    
    foreach ($key in $replacements.Keys) {
        $templateContent = $templateContent -replace [regex]::Escape($key), $replacements[$key]
    }
    
    return $templateContent
}

function Invoke-Encoder {
    [CmdletBinding()]
    param([hashtable]$Job)
    
    $isHEVC = $Job.EncoderName -match 'x265'
    $scriptEngine = $Job.ScriptEngine ?? 'VapourSynth'
    
    # Определение метода pipe в зависимости от движка
    if ($scriptEngine -eq 'AviSynth') {
        $pipeMethod = $global:Config.Processing.AviSynthPipeMethod ?? 'avs2pipemod'
        $pipeTool = $global:VideoTools.Avs2PipeMod ?? 'avs2pipemod64.exe'
    } else {
        $pipeMethod = $global:Config.Processing.VSPipeMethod ?? 'vspipe'
        $pipeTool = $global:VideoTools.VSPipe
    }
    
    if ($isHEVC) {
        $supportsVpy = $false # Test-X265VpySupport -X265Path $Job.EncoderPath
        
        if ($supportsVpy -and $scriptEngine -eq 'VapourSynth') {
            $encArgs = @(
                '--reader-options', 'library=X:\Apps\_VideoEncoding\StaxRip\Apps\FrameServer\VapourSynth\VSScript.dll'
                '--input', $Job.ScriptFile, '--output', $Job.VideoEncoded
                ) + $Job.EncoderParams
            Write-Log "Запуск x265 с прямым чтением VPY" -Severity Verbose -Category 'Video'
            
            $cmd="$($Job.EncoderPath) $($encArgs -join ' ')"
            Write-Log $cmd -Severity Verbose -Category 'Video'
            Write-Host $cmd -ForegroundColor Gray
            $Job.CommandLines+=@{'EncodeVideo'=$cmd}

            & $Job.EncoderPath $encArgs
        } else {
            # Запуск через pipe (vspipe или avs2pipemod)
            Write-Log "Запуск x265 через $pipeMethod" -Severity Verbose -Category 'Video'
            
            if ($scriptEngine -eq 'AviSynth') {
                # AviSynth через avs2pipemod
                $pipeArgs = @('-c', 'y4m', $Job.ScriptFile, '-')
            } else {
                # VapourSynth через vspipe
                $pipeArgs = @('-c', 'y4m', $Job.ScriptFile, '-')
            }
            
            $encArgs = @(
                '--y4m',
                '--output', $Job.VideoEncoded
                '--input', '-'
                ) + $Job.EncoderParams

            $cmd="$pipeTool $($pipeArgs -join ' ') | & $($Job.EncoderPath) $($encArgs -join ' ')"
            Write-Log $cmd -Severity Verbose -Category 'Video'
            $Job.CommandLines+=@{'EncodeVideo'=$cmd}

            & $pipeTool $pipeArgs | & $Job.EncoderPath $encArgs
        }
    } else {
        # AV1 и другие энкодеры
        # Формируем аргументы энкодера
        $encArgs = @('--output', $Job.VideoEncoded, '--input', '-') + $Job.EncoderParams
        
        # Добавляем параметр --frames, если известен
        if ($Job.ScriptInfo -and $Job.ScriptInfo.Frames -gt 0) {
            $encArgs = @('--frames', $Job.ScriptInfo.Frames) + $encArgs
            Write-Log "Установлено ограничение кадров: $($Job.ScriptInfo.Frames)" -Severity Verbose -Category 'Video'
        }
        
        if ($pipeMethod -eq 'ffmpeg') {
            Write-Log "Запуск через FFmpeg пайп" -Severity Verbose -Category 'Video'
            
            # Определение формата input для ffmpeg
            $inputFormat = if ($scriptEngine -eq 'AviSynth') { 'avisynth' } else { 'vapoursynth' }
            
            $ffmpegArgs = @(
                '-y', '-hide_banner', '-loglevel', 'error', '-nostats'
                '-f', $inputFormat, '-i', $Job.ScriptFile
                '-f', 'yuv4mpegpipe', '-strict', '-1', '-'
            )
            $cmd="$($global:VideoTools.FFmpeg) $($ffmpegArgs -join ' ') | & $($Job.EncoderPath) $($encArgs -join ' ')"
            Write-Log $cmd -Severity Verbose -Category 'Video'
            $Job.CommandLines+=@{'EncodeVideo'=$cmd}

            & $global:VideoTools.FFmpeg $ffmpegArgs | & $Job.EncoderPath $encArgs
        } else {
            Write-Log "Запуск через $pipeMethod" -Severity Verbose -Category 'Video'
            $pipeArgs = @('-c', 'y4m', $Job.ScriptFile, '-')
            
            $cmd="$pipeTool $($pipeArgs -join ' ') | & $($Job.EncoderPath) $($encArgs -join ' ')"
            Write-Log $cmd -Severity Verbose -Category 'Video'
            $Job.CommandLines+=@{'EncodeVideo'=$cmd}

            & $pipeTool $pipeArgs | & $Job.EncoderPath $encArgs
        }
    }
    
    if ($LASTEXITCODE -ne 0) {
        throw "Encoding failed with exit code: $LASTEXITCODE"
    }
    
    if (-not (Test-Path -LiteralPath $Job.VideoEncoded)) {
        throw "Encoded video not created: $($Job.VideoEncoded)"
    }
}

function Test-X265VpySupport {
    [CmdletBinding()]
    param([string]$X265Path)
    
    $help = & $X265Path --help 2>&1
    return ($help -match '--input.*y4m')
}

Export-ModuleMember -Function ConvertTo-Video