<#
.SYNOPSIS
    Обрабатывает аудиодорожки (копирование или перекодирование в Opus/AAC)
#>

function ConvertTo-Audio {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Job)
    
    Write-Log "Обработка $($Job.AudioSources.Count) аудиодорожек" -Severity Information -Category 'Audio'
    
    $copyAudio = $global:Config.Encoding.Audio.CopyAudio
    $audioCodec = $global:Config.Encoding.Audio.Codec
    $bitrates = $global:Config.Encoding.Audio.Bitrates
    
    $outputDir = Join-Path $Job.WorkingDir 'audio_encoded'
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    
    $Job.AudioEncodedSources = @()
    
    foreach ($audio in $Job.AudioSources) {
        $needConvert = (-not $copyAudio) -and ($audio.Codec -ne $audioCodec)
        
        $extension = if ($copyAudio -or -not $needConvert) {
            switch ($audio.Codec) {
                'aac' { 'm4a' }
                'opus' { 'opus' }
                default { [IO.Path]::GetExtension($audio.Path).TrimStart('.') }
            }
        } else {
            if ($audioCodec -eq 'aac') { 'm4a' } else { 'opus' }
        }
        
        $fileName = "audio_{0:D2}[{1}]{2}.{3}" -f 
            $audio.Index, $audio.Language, 
            $(if ($audio.Title) { "_{$(Get-SafeFileName $audio.Title)}" } else { '' }),
            $extension
        
        $outputFile = Join-Path $outputDir $fileName
        
        if ($copyAudio -or -not $needConvert) {
            # Прямое копирование
            Copy-Item $audio.Path $outputFile -Force
            Write-Log "Копирование: $fileName" -Severity Verbose -Category 'Audio'
        } else {
            # Перекодирование
            Write-Log "Перекодирование: $($audio.Codec) -> $audioCodec" -Severity Verbose -Category 'Audio'
            
            $tempFlac = [IO.Path]::ChangeExtension($outputFile, 'flac')
            
            # Конвертация в FLAC
            $ffmpegArgs = @(
                '-y', '-hide_banner', '-loglevel', 'error'
                '-i', $audio.Path
                '-c:a', 'flac', '-compression_level', '8'
                $tempFlac
            )
            
            & $global:VideoTools.FFmpeg $ffmpegArgs 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "FLAC conversion failed" }
            
            # Кодирование в целевой формат
            switch ($audioCodec) {
                'opus' {
                    $bitrate = if ($audio.Channels -le 2) { $bitrates.Stereo } else { $bitrates.Surround }
                    $opusArgs = @(
                        '--quiet', '--vbr', '--bitrate', $bitrate
                        '--title', $audio.Title
                        '--comment', "language=$($audio.Language)"
                        $tempFlac, $outputFile
                    )
                    & $global:VideoTools.OpusEnc $opusArgs
                }
                'aac' {
                    $qaacArgs = @(
                        '--no-delay', '--tvbr', $global:Config.Encoding.Audio.AAC.Quality
                        '-o', $outputFile
                        '--title', $audio.Title
                        $tempFlac
                    )
                    & $global:VideoTools.QAAC $qaacArgs
                }
                default { throw "Unknown audio codec: $audioCodec" }
            }
            
            if ($LASTEXITCODE -ne 0) { throw "$audioCodec encoding failed" }
            Remove-Item $tempFlac -Force -ErrorAction SilentlyContinue
        }
        
        if (-not (Test-Path $outputFile)) { throw "Output file not created: $outputFile" }
        
        $Job.AudioEncodedSources += @{
            Path = $outputFile
            Index = $audio.Index
            Language = $audio.Language
            Title = $audio.Title
            Default = $audio.Default
            Forced = $audio.Forced
        }
        
        $Job.TempFiles.Add($outputFile)
    }
    
    Write-Log "Аудио обработано: $($Job.AudioEncodedSources.Count) дорожек" -Severity Success -Category 'Audio'
    return $Job
}

Export-ModuleMember -Function ConvertTo-Audio