<#
.SYNOPSIS
    Извлекает все потоки из медиафайла в отдельные файлы
.DESCRIPTION
    Поддерживает MKV, MP4, MOV, AVI и другие форматы
#>

function Invoke-Demux {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Job)
    
    Write-Log "Demux: $([IO.Path]::GetFileName($Job.OriginalPath))" -Severity Information -Category 'Demux'
    
    # Создание поддиректорий
    $directories = @{
        Video = Join-Path $Job.WorkingDir 'video'
        Audio = Join-Path $Job.WorkingDir 'audio'
        Subtitles = Join-Path $Job.WorkingDir 'subtitles'
        Attachments = Join-Path $Job.WorkingDir 'attachments'
    }
    
    foreach ($dir in $directories.Values) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    
    # Получение информации о файле
    $fileInfo = Get-MediaFileInfo -FilePath $Job.OriginalPath
    
    # Извлечение потоков
    $Job.VideoSource = Extract-VideoStream -Job $Job -FileInfo $fileInfo -OutputDir $directories.Video
    $Job.AudioSources = Extract-AudioStreams -Job $Job -FileInfo $fileInfo -OutputDir $directories.Audio
    $Job.SubtitleSources = Extract-SubtitleStreams -Job $Job -FileInfo $fileInfo -OutputDir $directories.Subtitles
    $Job.ChaptersSource = Extract-Chapters -Job $Job -FileInfo $fileInfo -OutputDir $Job.WorkingDir
    $Job.TagsSource = Extract-GlobalTags -Job $Job -FileInfo $fileInfo -OutputDir $Job.WorkingDir
    
    # Извлечение обложки и вложений
    $attachments = Extract-CoverAndAttachments -Job $Job -FileInfo $fileInfo -OutputDir $directories.Attachments
    $Job.CoverSource = $attachments.Cover
    $Job.AttachmentSources = $attachments.Files
    
    Write-Log "Demux завершен: Видео=1, Аудио=$($Job.AudioSources.Count), Субтитры=$($Job.SubtitleSources.Count)" `
        -Severity Success -Category 'Demux'
    
    return $Job
}

function Get-MediaFileInfo {
    [CmdletBinding()]
    param([string]$FilePath)
    
    $output = & $global:VideoTools.FFprobe -v quiet -print_format json `
        -show_streams -show_format -show_chapters $FilePath 2>&1
    
    if ($LASTEXITCODE -ne 0) {
        throw "FFprobe failed: $output"
    }
    
    $info = $output | ConvertFrom-Json
    
    return @{
        Streams = $info.streams
        Format = $info.format
        Chapters = $info.chapters
    }
}

function Extract-VideoStream {
    [CmdletBinding()]
    param([hashtable]$Job, [object]$FileInfo, [string]$OutputDir)
    
    $videoStream = $FileInfo.Streams | Where-Object { $_.codec_type -eq 'video' } | Select-Object -First 1
    if (-not $videoStream) { throw "Video stream not found" }
    
    $extension = switch ($videoStream.codec_name) {
        'hevc' { 'hevc' }
        'h265' { 'hevc' }
        default { 'h264' }
    }
    
    $outputFile = Join-Path $OutputDir "video.$extension"
    
    $trimParams = @()
    if ($Job.TrimStartSeconds -gt 0) {
        $trimParams += '-ss', $Job.TrimStartSeconds.ToString('0.######', [CultureInfo]::InvariantCulture)
    }
    if ($Job.TrimDurationSeconds -gt 0) {
        $trimParams += '-t', $Job.TrimDurationSeconds.ToString('0.######', [CultureInfo]::InvariantCulture)
    }
    
    $args = @(
        '-y', '-hide_banner', '-loglevel', 'error'
        $trimParams
        '-i', $Job.OriginalPath
        '-map', '0:v:0'
        '-c:v', 'copy'
        '-map_metadata', '-1'
        $outputFile
    )
    
    & $global:VideoTools.FFmpeg $args 2>&1 | Out-Null
    
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $outputFile)) {
        throw "Failed to extract video stream (exit code: $LASTEXITCODE)"
    }
    
    $Job.TempFiles.Add($outputFile)
    return $outputFile
}

function Extract-AudioStreams {
    [CmdletBinding()]
    param([hashtable]$Job, [object]$FileInfo, [string]$OutputDir)
    
    $audioStreams = $FileInfo.Streams | Where-Object { $_.codec_type -eq 'audio' }
    $result = @()
    
    $index = 0
    foreach ($stream in $audioStreams) {
        $index++
        
        $language = $stream.tags.language ?? $stream.tags.LANGUAGE ?? 'und'
        $title = $stream.tags.title ?? $stream.tags.TITLE ?? $stream.tags.handler_name ?? ''
        
        $extension = switch ($stream.codec_name) {
            'aac' { 'm4a' }
            'ac3' { 'ac3' }
            'eac3' { 'eac3' }
            'opus' { 'opus' }
            'flac' { 'flac' }
            default { 'mka' }
        }
        
        $fileName = "audio_{0:D2}[{1}]{2}.{3}" -f $index, $language, 
            $(if ($title) { "_{$(Get-SafeFileName $title)}" } else { '' }), $extension
        $outputFile = Join-Path $OutputDir $fileName
        
        $trimParams = @()
        if ($Job.TrimStartSeconds -gt 0) {
            $trimParams += '-ss', $Job.TrimStartSeconds.ToString('0.######', [CultureInfo]::InvariantCulture)
        }
        if ($Job.TrimDurationSeconds -gt 0) {
            $trimParams += '-t', $Job.TrimDurationSeconds.ToString('0.######', [CultureInfo]::InvariantCulture)
        }
        
        $args = @(
            '-y', '-hide_banner', '-loglevel', 'error'
            $trimParams
            '-i', $Job.OriginalPath
            '-map', "0:a:$($index-1)"
            '-c:a', 'copy'
            '-map_metadata', '-1'
            $outputFile
        )
        
        & $global:VideoTools.FFmpeg $args 2>&1 | Out-Null
        
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $outputFile)) {
            throw "Failed to extract audio stream $index (exit code: $LASTEXITCODE)"
        }
        
        $result += @{
            Path = $outputFile
            Index = $index
            Language = $language
            Title = $title
            Codec = $stream.codec_name
            Channels = $stream.channels
            Default = $stream.disposition.default -eq 1
            Forced = $stream.disposition.forced -eq 1
        }
        
        $Job.TempFiles.Add($outputFile)
    }
    
    return $result
}

function Extract-SubtitleStreams {
    [CmdletBinding()]
    param([hashtable]$Job, [object]$FileInfo, [string]$OutputDir)
    
    $subtitleStreams = $FileInfo.Streams | Where-Object { $_.codec_type -eq 'subtitle' }
    $result = @()
    
    $index = 0
    foreach ($stream in $subtitleStreams) {
        $index++
        
        $language = $stream.tags.language ?? $stream.tags.LANGUAGE ?? 'und'
        $title = $stream.tags.title ?? $stream.tags.TITLE ?? ''
        
        $fileName = "sub_{0:D2}[{1}]{2}.srt" -f $index, $language,
            $(if ($title) { "_{$(Get-SafeFileName $title)}" } else { '' })
        $outputFile = Join-Path $OutputDir $fileName
        
        # Конвертируем все форматы в SRT
        $args = @(
            '-y', '-hide_banner', '-loglevel', 'error'
            '-i', $Job.OriginalPath
            '-map', "0:s:$($index-1)"
            '-c:s', 'srt'
            $outputFile
        )
        
        & $global:VideoTools.FFmpeg $args 2>&1 | Out-Null
        
        if (Test-Path $outputFile) {
            $result += @{
                Path = $outputFile
                Index = $index
                Language = $language
                Name = $title
                Codec = 'srt'
                Default = $stream.disposition.default -eq 1
                Forced = $stream.disposition.forced -eq 1
            }
            $Job.TempFiles.Add($outputFile)
        }
    }
    
    return $result
}

function Extract-Chapters {
    [CmdletBinding()]
    param([hashtable]$Job, [object]$FileInfo, [string]$OutputDir)
    
    if (-not $FileInfo.Chapters -or $FileInfo.Chapters.Count -eq 0) {
        return $null
    }
    
    $outputFile = Join-Path $OutputDir 'chapters.xml'
    
    $result = Convert-MP4ChaptersToXML -ChaptersJson @{ chapters = $FileInfo.Chapters } -OutputFile $outputFile
    
    if ($result) {
        $Job.TempFiles.Add($outputFile)
        return $outputFile
    }
    
    return $null
}

function Extract-GlobalTags {
    [CmdletBinding()]
    param([hashtable]$Job, [object]$FileInfo, [string]$OutputDir)
    
    if (-not $FileInfo.Format.tags -or $FileInfo.Format.tags.Count -eq 0) {
        return $null
    }
    
    $outputFile = Join-Path $OutputDir 'tags.xml'
    
    Convert-MP4TagsToXml -Tags $FileInfo.Format.tags -OutputFile $outputFile
    
    if (Test-Path $outputFile) {
        $Job.TempFiles.Add($outputFile)
        return $outputFile
    }
    
    return $null
}

function Extract-CoverAndAttachments {
    [CmdletBinding()]
    param([hashtable]$Job, [object]$FileInfo, [string]$OutputDir)
    
    $result = @{ Cover = $null; Files = @() }
    
    # Проверка внешней обложки
    $sourceDir = [IO.Path]::GetDirectoryName($Job.OriginalPath)
    $coverNames = @('cover.jpg', 'cover.png', 'folder.jpg', 'poster.jpg')
    
    foreach ($name in $coverNames) {
        $coverPath = Join-Path $sourceDir $name
        if (Test-Path $coverPath) {
            $destPath = Join-Path $OutputDir "cover$([IO.Path]::GetExtension($coverPath))"
            Copy-Item $coverPath $destPath -Force
            $result.Cover = $destPath
            $Job.TempFiles.Add($destPath)
            Write-Log "Найдена внешняя обложка: $name" -Severity Information -Category 'Demux'
            break
        }
    }
    
    # Извлечение вложений из MKV
    $attachments = $FileInfo.Streams | Where-Object { 
        $_.codec_type -eq 'attachment' -or ($_.disposition.attached_pic -eq 1)
    }
    
    foreach ($attachment in $attachments) {
        $fileName = $attachment.tags.filename ?? "attach_$($attachment.index).dat"
        $outputFile = Join-Path $OutputDir $fileName
        
        $args = @(
            '-y', '-hide_banner', '-loglevel', 'error'
            '-i', $Job.OriginalPath
            '-map', "0:$($attachment.index)"
            '-c', 'copy'
            $outputFile
        )
        
        & $global:VideoTools.FFmpeg $args 2>&1 | Out-Null
        
        if (Test-Path $outputFile) {
            $isCover = $fileName -match 'cover|poster|folder'
            
            if ($isCover -and -not $result.Cover) {
                $result.Cover = $outputFile
            } else {
                $result.Files += @{
                    Path = $outputFile
                    Name = $fileName
                    MimeType = $attachment.tags.mimetype ?? 'application/octet-stream'
                }
            }
            $Job.TempFiles.Add($outputFile)
        }
    }
    
    return $result
}

Export-ModuleMember -Function Invoke-Demux