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
    
    $originalEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $output = & $global:VideoTools.FFprobe -v quiet -print_format json `
        -show_streams -show_format -show_chapters $FilePath 2>&1
    [Console]::OutputEncoding = $originalEncoding

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
    
    $outputFile = Join-Path $OutputDir "video.mkv" # "video.$extension"
    if (Test-Path -LiteralPath $outputFile) {
        Write-Log "Video stream already exists: $outputFile" -Severity Verbose -Category 'Demux'
        $Job.TempFiles.Add($outputFile)
        return $outputFile
    }
    
    $trimParams = @()
    if ($Job.TrimStartSeconds -gt 0) {
        $trimParams += '-ss', $Job.TrimStartSeconds.ToString('0.######', [CultureInfo]::InvariantCulture)
    }
    if ($Job.TrimDurationSeconds -gt 0) {
        $trimParams += '-t', $Job.TrimDurationSeconds.ToString('0.######', [CultureInfo]::InvariantCulture)
    }
    
    $ffmpegArgs = @(
        '-y', '-hide_banner', '-loglevel', 'error'
        $trimParams
        '-i', $Job.OriginalPath
        '-map', '0:v:0'
        '-c:v', 'copy'
        '-map_metadata', '-1'
        $outputFile
    )

    Write-Log "Extracting video stream with FFmpeg arguments: $($ffmpegArgs -join ' ')" -Severity Verbose -Category 'Demux'
    & $global:VideoTools.FFmpeg $ffmpegArgs 2>&1 | Out-Null
    
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $outputFile)) {
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
        
        $ffmpegArgs = @(
            '-y', '-hide_banner', '-loglevel', 'error'
            $trimParams
            '-i', $Job.OriginalPath
            '-map', "0:a:$($index-1)"
            '-c:a', 'copy'
            '-map_metadata', '-1'
            $outputFile
        )

        Write-Log "Extracting audio stream with FFmpeg arguments: $($ffmpegArgs -join ' ')" -Severity Verbose -Category 'Demux'
        & $global:VideoTools.FFmpeg $ffmpegArgs
        
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $outputFile)) {
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
            Forced = (($stream.disposition.forced -eq 1) -or ($title -eq 'forced'))
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
        $title = $stream.tags.title ?? $stream.tags.handler_name ?? ''
        
        $fileName = "sub_{0:D2}[{1}]{2}.srt" -f $index, $language,
            $(if ($title) { "_{$(Get-SafeFileName $title)}" } else { '' })
        $outputFile = Join-Path $OutputDir $fileName
        
        # Конвертируем все форматы в SRT
        $ffmpegArgs = @(
            '-y', '-hide_banner', '-loglevel', 'error'
            '-i', $Job.OriginalPath
            '-map', "0:s:$($index-1)"
            '-c:s', 'srt'
            $outputFile
        )
        
        Write-Log "Extracting video stream with FFmpeg arguments: $($ffmpegArgs -join ' ')" -Severity Verbose -Category 'Demux'
        & $global:VideoTools.FFmpeg $ffmpegArgs 2>&1 | Out-Null
        
        if (Test-Path -LiteralPath $outputFile) {
            $result += @{
                Path = $outputFile
                Index = $index
                Language = $language
                Name = $title
                Codec = 'srt'
                Default = $stream.disposition.default -eq 1
                Forced = (($stream.disposition.forced -eq 1) -or ($title -eq 'forced'))
                SDH = (($stream.disposition.hearing_impaired -eq 1) -or ($title -eq 'SDH'))
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
    
    # Проверяем наличие тегов
    if (-not $FileInfo.Format.tags -or $FileInfo.Format.tags.Count -eq 0) {
        Write-Log "No global tags found in file" -Severity Verbose -Category 'Demux'
        return $null
    }
    
    $outputFile = Join-Path $OutputDir 'tags.xml'
    
    try {
        Convert-MP4TagsToXml -Tags $FileInfo.Format.tags -OutputFile $outputFile
        
        if (Test-Path $outputFile) {
            # Проверяем, что файл не пустой
            $content = Get-Content $outputFile -Raw
            if ($content -match '<Simple>') {
                $Job.TempFiles.Add($outputFile)
                Write-Log "Global tags extracted: $outputFile" -Severity Verbose -Category 'Demux'
                return $outputFile
            } else {
                Write-Log "No meaningful tags found" -Severity Verbose -Category 'Demux'
                Remove-Item $outputFile -Force -ErrorAction SilentlyContinue
                return $null
            }
        }
    }
    catch {
        Write-Log "Failed to extract global tags: $_" -Severity Warning -Category 'Demux'
    }
    
    return $null
}

function Extract-CoverAndAttachments {
    [CmdletBinding()]
    param([hashtable]$Job, [object]$FileInfo, [string]$OutputDir)
    
    $result = @{ Cover = $null; Files = @() }
    
    # Проверка внешней обложки в директории исходного файла
    $sourceDir = [IO.Path]::GetDirectoryName($Job.OriginalPath)
    $coverFile = Find-ExternalCover -SourceDir $sourceDir
    
    if ($coverFile) {
        $coverExt = [IO.Path]::GetExtension($coverFile)
        $destPath = Join-Path $OutputDir "cover$coverExt"
        Copy-Item -LiteralPath $coverFile -Destination $destPath -Force
        $result.Cover = $destPath
        $Job.TempFiles.Add($destPath)
        Write-Log "Найдена внешняя обложка: $([IO.Path]::GetFileName($coverFile))" -Severity Information -Category 'Demux'
    }
    
    # Извлечение вложений из MKV
    $attachments = $FileInfo.Streams | Where-Object { 
        $_.codec_type -eq 'attachment' -or ($_.disposition.attached_pic -eq 1)
    }
    
    foreach ($attachment in $attachments) {
        $fileName = $attachment.tags.filename ?? "attach_$($attachment.index).dat"
        $outputFile = Join-Path $OutputDir $fileName
        
        $ffmpegArgs = @(
            '-y', '-hide_banner', '-loglevel', 'error'
            '-i', $Job.OriginalPath
            '-map', "0:$($attachment.index)"
            '-c', 'copy'
            $outputFile
        )
        
        Write-Log "Extracting attachments with FFmpeg arguments: $($ffmpegArgs -join ' ')" -Severity Verbose -Category 'Demux'
        & $global:VideoTools.FFmpeg $ffmpegArgs 2>&1 | Out-Null
        
        if (Test-Path $outputFile) {
            $isCover = $fileName -match 'cover|poster|folder'
            
            if ($isCover -and -not $result.Cover) {
                $result.Cover = $outputFile
                Write-Log "Встроенная обложка извлечена: $fileName" -Severity Information -Category 'Demux'
            } else {
                $result.Files += @{
                    Path = $outputFile
                    Name = $fileName
                    MimeType = $attachment.tags.mimetype ?? 'application/octet-stream'
                }
                Write-Log "Вложение извлечено: $fileName" -Severity Verbose -Category 'Demux'
            }
            $Job.TempFiles.Add($outputFile)
        }
    }
    
    return $result
}

function Find-ExternalCover {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [switch]$SearchParentDirectories = $true
    )
    
    # Статические имена файлов обложек
    $coverStaticNames = @(
        'cover.jpg', 'cover.png', 'cover.webp',
        'folder.jpg', 'folder.png', 'folder.webp',
        'poster.jpg', 'poster.png'
    )
    
    # Регулярные выражения для поиска обложек
    $coverRegexPatterns = @(
        'season\d+\-poster\.(jpg|jpeg|png|webp)',
        'poster\.(jpg|jpeg|png|webp)',
        'cover-\d+\.(jpg|jpeg|png|webp)',
        '.*-poster\.(jpg|jpeg|png|webp)',
        '.*-cover\.(jpg|jpeg|png|webp)'
    )
    
    # Функция поиска в конкретной директории
    function Search-InDirectory {
        param([string]$Directory)
        
        # Проверка статических имен
        foreach ($coverName in $coverStaticNames) {
            $potentialCover = Join-Path -Path $Directory -ChildPath $coverName
            if (Test-Path -LiteralPath $potentialCover -PathType Leaf) {
                return $potentialCover
            }
        }
        
        # Поиск по регулярным выражениям
        try {
            $allFiles = Get-ChildItem -Path $Directory -File -ErrorAction SilentlyContinue
            
            foreach ($pattern in $coverRegexPatterns) {
                $matchingFiles = $allFiles | Where-Object { $_.Name -match $pattern }
                
                if ($matchingFiles.Count -gt 0) {
                    $coverFile = $matchingFiles | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                    return $coverFile.FullName
                }
            }
        }
        catch {
            Write-Log "Ошибка поиска в директории $Directory : $_" -Severity Warning -Category 'Demux'
        }
        
        return $null
    }
    
    # Поиск в текущей директории
    $coverFile = Search-InDirectory -Directory $SourceDir
    if ($coverFile) {
        Write-Log "Найдена обложка в текущей директории: $([IO.Path]::GetFileName($coverFile))" -Severity Information -Category 'Demux'
        return $coverFile
    }
    
    # Поиск в родительских директориях (для структуры сериалов)
    if ($SearchParentDirectories) {
        $currentDir = $SourceDir
        $levelsUp = 0
        $maxLevels = 3
        
        while ($levelsUp -lt $maxLevels -and $currentDir -ne [IO.Path]::GetPathRoot($currentDir)) {
            $currentDir = [IO.Path]::GetDirectoryName($currentDir)
            $levelsUp++
            
            $coverFile = Search-InDirectory -Directory $currentDir
            if ($coverFile) {
                Write-Log "Найдена обложка на $levelsUp уровень(ей) выше: $([IO.Path]::GetFileName($coverFile))" -Severity Information -Category 'Demux'
                return $coverFile
            }
        }
    }
    
    Write-Log "Внешняя обложка не найдена" -Severity Verbose -Category 'Demux'
    return $null
}

Export-ModuleMember -Function Invoke-Demux