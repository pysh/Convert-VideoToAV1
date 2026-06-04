<#
.SYNOPSIS
    Собирает итоговый MKV файл из компонентов
#>

function Invoke-Mux {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Job)
    
    Write-Log "Сборка MKV: $([IO.Path]::GetFileName($Job.FinalOutput))" -Severity Information -Category 'Mux'
    
    $videoSource = $Job.VideoEncoded ?? $Job.VideoSource
    
    # Базовые аргументы
    $args = @(
        '--ui-language', 'en'
        '--priority', 'lower'
        '--output', $Job.FinalOutput
    )
    
    # Заголовок файла
    if ($Job.NfoFields -and $Job.NfoFields.SHOWTITLE) {
        $title = "{0} - s{1:00}e{2:00} - {3}" -f 
            $Job.NfoFields.SHOWTITLE,
            ([int]($Job.NfoFields.SEASON_NUMBER ?? 1)),
            ([int]($Job.NfoFields.PART_NUMBER ?? 1)),
            ($Job.NfoFields.TITLE ?? 'Episode')
        $args += '--title', $title
    }
    
    # Видео
    $args += @(
        '--no-audio', '--no-subtitles', '--no-attachments', '--no-track-tags', '--no-chapters'
        $videoSource
    )
    
    # Аудио
    foreach ($audio in $Job.AudioEncodedSources) {
        $args += @(
            '--language', "0:$($audio.Language)"
            '--track-name', "0:$($audio.Title)"
            '--default-track-flag', "0:$(if ($audio.Default) {'yes'} else {'no'})"
            '--forced-display-flag', "0:$(if ($audio.Forced) {'yes'} else {'no'})"
            $audio.Path
        )
    }
    
    # Субтитры
    foreach ($sub in $Job.SubtitleSources) {
        $args += @(
            '--language', "0:$($sub.Language)"
            '--track-name', "0:$($sub.Name)"
            '--default-track-flag', "0:$(if ($sub.Default) {'yes'} else {'no'})"
            $sub.Path
        )
    }
    
    # Главы
    if ($Job.ChaptersSource -and (Test-Path $Job.ChaptersSource)) {
        $args += '--chapters', $Job.ChaptersSource
    }
    
    # Глобальные теги
    if ($Job.NfoTags -and (Test-Path $Job.NfoTags)) {
        $args += '--global-tags', $Job.NfoTags
    } elseif ($Job.TagsSource -and (Test-Path $Job.TagsSource)) {
        $args += '--global-tags', $Job.TagsSource
    }
    
    & $global:VideoTools.MkvMerge $args
    
    if ($LASTEXITCODE -ne 0) {
        throw "MkvMerge failed with exit code: $LASTEXITCODE"
    }
    
    # Добавление обложки и вложений
    Add-AttachmentsToMkv -Job $Job
    
    return $Job
}

function Add-AttachmentsToMkv {
    [CmdletBinding()]
    param([hashtable]$Job)
    
    # Обложка
    if ($Job.CoverSource -and (Test-Path $Job.CoverSource)) {
        $ext = [IO.Path]::GetExtension($Job.CoverSource).ToLower()
        $mimeType = switch ($ext) {
            '.jpg' { 'image/jpeg' }
            '.png' { 'image/png' }
            '.webp' { 'image/webp' }
            default { 'image/jpeg' }
        }
        
        $args = @(
            $Job.FinalOutput
            '--attachment-name', 'cover'
            '--attachment-mime-type', $mimeType
            '--add-attachment', $Job.CoverSource
        )
        
        & $global:VideoTools.MkvPropedit $args 2>&1 | Out-Null
        Write-Log "Обложка добавлена" -Severity Verbose -Category 'Mux'
    }
    
    # Вложения
    if ($Job.AttachmentSources) {
        foreach ($att in $Job.AttachmentSources) {
            $args = @($Job.FinalOutput, '--add-attachment', $att.Path)
            if ($att.Name) { $args += '--attachment-name', $att.Name }
            if ($att.MimeType) { $args += '--attachment-mime-type', $att.MimeType }
            & $global:VideoTools.MkvPropedit $args 2>&1 | Out-Null
        }
    }
}

Export-ModuleMember -Function Invoke-Mux