<#
.SYNOPSIS
    Обрабатывает видео (кодирование или копирование)
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
    
    # Создание VapourSynth скрипта
    $Job.ScriptFile = Join-Path $Job.WorkingDir "$($Job.BaseName).vpy"
    $Job.CacheFile = Join-Path $Job.WorkingDir "$($Job.BaseName).lwi"
    
    # Выбор шаблона
    $selectedTemplate = Select-Template -Job $Job -CustomPath $TemplatePath
    
    # Создание скрипта
    $scriptContent = New-VapourSynthScript -Job $Job -TemplatePath $selectedTemplate
    Set-Content -LiteralPath $Job.ScriptFile -Value $scriptContent -Force -Encoding UTF8
    $Job.TempFiles.Add($Job.ScriptFile)
    
    # Запуск кодирования
    Invoke-Encoder -Job $Job
    
    # Проверка количества кадров
    $encodedInfo = Get-VideoStats -VideoFilePath $Job.VideoEncoded
    $scriptInfo = Get-VideoScriptInfo -ScriptPath $Job.ScriptFile
    
    if ($encodedInfo.FrameCount -ne $scriptInfo.Frames) {
        Write-Log "Предупреждение: несоответствие кадров (скрипт: $($scriptInfo.Frames), видео: $($encodedInfo.FrameCount))" `
            -Severity Warning -Category 'Video'
    }
    
    $Job.TempFiles.Add($Job.VideoEncoded)
    Write-Log "Кодирование завершено: $([IO.Path]::GetFileName($Job.VideoEncoded))" -Severity Success -Category 'Video'
    
    return $Job
}

function Select-Template {
    [CmdletBinding()]
    param([hashtable]$Job, [string]$CustomPath)
    
    if ($CustomPath -and (Test-Path $CustomPath)) {
        Write-Log "Использование пользовательского шаблона: $CustomPath" -Severity Information -Category 'Video'
        return $CustomPath
    }
    
    $videoDir = [IO.Path]::GetDirectoryName($Job.VideoSource)
    $localTemplate = Join-Path $videoDir 'template.vpy'
    if (Test-Path $localTemplate) {
        Write-Log "Использование локального шаблона: $localTemplate" -Severity Information -Category 'Video'
        return $localTemplate
    }
    
    $isHDR = Test-VideoHDR -VideoPath $Job.VideoSource
    $isHEVC = $Job.EncoderName -match 'x265'
    
    $templateName = if ($isHDR) { 'HDRtoSDRScript' } 
                    elseif ($isHEVC) { 'MainHDScript' }
                    else { 'MainScript' }
    
    $relativePath = $global:Config.Templates.VapourSynth[$templateName]
    $scriptDir = Split-Path -Parent $PSScriptRoot
    $templatePath = Join-Path $scriptDir $relativePath
    
    if (-not (Test-Path $templatePath)) {
        throw "Template not found: $templatePath"
    }
    
    Write-Log "Использование шаблона: $templateName" -Severity Information -Category 'Video'
    return $templatePath
}

function New-VapourSynthScript {
    [CmdletBinding()]
    param([hashtable]$Job, [string]$TemplatePath)
    
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
    
    # Тримминг
    $trimScript = ''
    if ($Job.TrimStartSeconds -gt 0) {
        $startFrame = [math]::Round($Job.TrimStartSeconds * $Job.FrameRate)
        $trimScript = "clip = clip[${startFrame}:]`n"
    }
    if ($Job.TrimDurationSeconds -gt 0) {
        $endFrame = [math]::Round(($Job.TrimStartSeconds + $Job.TrimDurationSeconds) * $Job.FrameRate)
        $trimScript = "clip = clip[:${endFrame}]`n"
    }
    
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
    
    if ($isHEVC) {
        $supportsVpy = Test-X265VpySupport -X265Path $Job.EncoderPath
        
        if ($supportsVpy) {
            $x265args = @('--input', $Job.ScriptFile, '--output', $Job.VideoEncoded) + $Job.EncoderParams
            & $Job.EncoderPath $x265args
        } else {
            $vspipeArgs = @('-c', 'y4m', $Job.ScriptFile, '-')
            $encArgs = @('--output', $Job.VideoEncoded, '--input', '-') + $Job.EncoderParams
            & $global:VideoTools.VSPipe $vspipeArgs | & $Job.EncoderPath $encArgs
        }
    } else {
        $vspipeMethod = $global:Config.Processing.VSPipeMethod ?? 'vspipe'
        
        if ($vspipeMethod -eq 'ffmpeg') {
            $ffmpegArgs = @(
                '-y', '-hide_banner', '-loglevel', 'error', '-nostats'
                '-f', 'vapoursynth', '-i', $Job.ScriptFile
                '-f', 'yuv4mpegpipe', '-strict', '-1', '-'
            )
            $encArgs = @('--output', $Job.VideoEncoded, '--input', '-') + $Job.EncoderParams
            & $global:VideoTools.FFmpeg $ffmpegArgs | & $Job.EncoderPath $encArgs
        } else {
            $vspipeArgs = @('-c', 'y4m', $Job.ScriptFile, '-')
            $encArgs = @('--output', $Job.VideoEncoded, '--input', '-') + $Job.EncoderParams
            
            if ($Job.VPYInfo.Frames -gt 0) {
                $encArgs = @('--frames', $Job.VPYInfo.Frames) + $encArgs
            }
            
            & $global:VideoTools.VSPipe $vspipeArgs | & $Job.EncoderPath $encArgs
        }
    }
    
    if ($LASTEXITCODE -ne 0) {
        throw "Encoding failed with exit code: $LASTEXITCODE"
    }
    
    if (-not (Test-Path $Job.VideoEncoded)) {
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