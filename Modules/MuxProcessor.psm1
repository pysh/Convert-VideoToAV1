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
    $mkvmergeArgs = @(
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
        $mkvmergeArgs += '--title', $title
    }
    
    # Видео
    $mkvmergeArgs += @(
        '--no-audio', '--no-subtitles', '--no-attachments', '--no-track-tags', '--no-chapters'
        $videoSource
    )
    
    # Аудио
    foreach ($audio in $Job.AudioEncodedSources) {
        $mkvmergeArgs += @(
            '--language', "0:$($audio.Language)"
            '--track-name', "0:$($audio.Title)"
            '--default-track-flag', "0:$(if ($audio.Default) {'yes'} else {'no'})"
            '--forced-display-flag', "0:$(if ($audio.Forced) {'yes'} else {'no'})"
            '--hearing-impaired-flag', "0:$(if ($audio.Title -eq 'SDH') {'yes'} else {'no'})"
            $audio.Path
        )
    }
    
    # Субтитры
    foreach ($sub in $Job.SubtitleSources) {
        $mkvmergeArgs += @(
            '--language', "0:$($sub.Language)"
            '--track-name', "0:$($sub.Name)"
            '--default-track-flag', "0:$(if ($sub.Default) {'yes'} else {'no'})"
            $sub.Path
        )
    }
    
    # Главы
    if ($Job.ChaptersSource -and (Test-Path $Job.ChaptersSource)) {
        $mkvmergeArgs += '--chapters', $Job.ChaptersSource
    }
    
    # Глобальные теги
    if ($Job.NfoTags -and (Test-Path $Job.NfoTags)) {
        $mkvmergeArgs += '--global-tags', $Job.NfoTags
    } elseif ($Job.TagsSource -and (Test-Path $Job.TagsSource)) {
        $mkvmergeArgs += '--global-tags', $Job.TagsSource
    }
    Write-Log "Запуск MkvMerge: $($mkvmergeArgs -join ' ')" -Severity Verbose -Category 'Mux'

    $cmd="$($global:VideoTools.MkvMerge) $($mkvmergeArgs -join ' ')"
    Write-Log $cmd -Severity Verbose -Category 'Video'
    $Job.CommandLines+=@{'FinalMKVMerge'=$cmd}

    & $global:VideoTools.MkvMerge $mkvmergeArgs
    
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
        
        $mkvPropEditArgs = @(
            $Job.FinalOutput
            '--attachment-name', 'cover'
            '--attachment-mime-type', $mimeType
            '--add-attachment', $Job.CoverSource
        )
        Write-Log "Добавление обложки: $($Job.CoverSource)" -Severity Verbose -Category 'Mux'
        $cmd="$($global:VideoTools.MkvPropedit) $($mkvPropEditArgs -join ' ')"
        $Job.CommandLines+=@{FinalAttachCover=$cmd}

        & $global:VideoTools.MkvPropedit $mkvPropEditArgs 2>&1 | Out-Null
        Write-Log "Обложка добавлена" -Severity Verbose -Category 'Mux'
    }
    
    # Вложения
    if ($Job.AttachmentSources) {
        foreach ($att in $Job.AttachmentSources) {
            $mkvPropEditArgs = @($Job.FinalOutput, '--add-attachment', $att.Path)
            if ($att.Name) { $mkvPropEditArgs += '--attachment-name', $att.Name }
            if ($att.MimeType) { $mkvPropEditArgs += '--attachment-mime-type', $att.MimeType }

            $cmd="$($global:VideoTools.MkvPropedit) $($mkvPropEditArgs -join ' ')"
            Write-Log $cmd -Severity Verbose -Category 'Audio'
            $Job.CommandLines+=@{"AddAttachment_$($att.Index.ToString('00'))"=$cmd}

            & $global:VideoTools.MkvPropedit $mkvPropEditArgs 2>&1 | Out-Null
        }
    }
}

Export-ModuleMember -Function Invoke-Mux