function Get-VideoInfo {
    <#
    .SYNOPSIS
        Получает информацию о видеофайле или скрипте (VapourSynth, AviSynth).
    .PARAMETER ScriptPath
        Путь к видеофайлу, .vpy или .avs скрипту.
    .PARAMETER CountPackets
        Если задано, при отсутствии метаданных будет выполнен подсчёт пакетов
        (медленно — ffprobe читает весь файл).
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param (
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('FullName', 'Path')]
        [string]$ScriptPath,

        [switch]$CountPackets
    )

    process {
        if (-not (Test-Path -LiteralPath $ScriptPath)) {
            throw "Файл не найден: $ScriptPath"
        }

        $Engine = switch ([IO.Path]::GetExtension($ScriptPath).ToLowerInvariant()) {
            '.vpy' { 'VapourSynth' }
            '.avs' { 'AviSynth' }
            default { 'other' }
        }

        try {
            if ($Engine -eq 'VapourSynth') {
                return Get-VapourSynthInfo -ScriptPath $ScriptPath
            }
            return Get-FFprobeInfo -ScriptPath $ScriptPath -Engine $Engine -CountPackets:$CountPackets
        }
        catch {
            # Если Write-Log нет — используйте Write-Error
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log "Ошибка при получении информации о файле ($Engine): $_" -Severity Error -Category 'Video'
            }
            throw
        }
    }
}

# --- Вспомогательная: VapourSynth через vspipe ---
function Get-VapourSynthInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ScriptPath)

    $vspInfo = & vspipe --info $ScriptPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Ошибка выполнения vspipe: $vspInfo"
    }

    $infoHash = [ordered]@{}
    foreach ($line in $vspInfo) {
        if ($line -match '^(?<name>[^:]+):\s*(?<value>.*)$') {
            $key = $Matches.name.Trim()
            # Не перезаписываем уже существующий ключ (первое значение приоритетнее)
            if (-not $infoHash.Contains($key)) {
                $infoHash[$key] = $Matches.value.Trim()
            }
        }
    }

    # Нормализация ключей (vspipe отдаёт "Width", "Height", "FPS" и т.п.)
    $normalized = [ordered]@{}
    foreach ($kv in $infoHash.GetEnumerator()) {
        $normalized[$kv.Key] = $kv.Value
    }
    return [PSCustomObject]$normalized
}

# --- Вспомогательная: ffprobe ---
function Get-FFprobeInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$Engine,
        [switch]$CountPackets
    )

    $ffprobeApp = if ($global:VideoTools -and $global:VideoTools.FFprobe) {
        $global:VideoTools.FFprobe
    }
    else { 'ffprobe' }

    # Секции show_entries: stream (базовые поля), stream_side_data (DoVi), stream_tags (NUMBER_OF_FRAMES)
    # nb_read_packets запрашивается только при -CountPackets
    $streamFields = 'index,r_frame_rate,avg_frame_rate,nb_frames,width,height,codec_name,duration,color_primaries,color_transfer,color_space'
    if ($CountPackets) { $streamFields += ',nb_read_packets' }

    $showEntries = @(
        "stream=$streamFields"
        'stream_side_data=side_data_type,dv_profile,dv_bl_signal_compatibility_id,bl_present_flag,dv_level,rpu_present_flag,el_present_flag'
        'stream_tags=NUMBER_OF_FRAMES,DURATION'
    ) -join ':'

    $ffprobeArgs = [System.Collections.Generic.List[string]]::new()
    $ffprobeArgs.AddRange([string[]]@('-v', 'error'))

    if ($Engine -eq 'AviSynth') {
        $ffprobeArgs.AddRange([string[]]@('-f', 'avisynth'))
    }
    if ($CountPackets) {
        $ffprobeArgs.Add('-count_packets')
    }

    $ffprobeArgs.AddRange([string[]]@(
            '-select_streams', 'v:0',
            '-show_entries', $showEntries,
            '-of', 'json',
            $ScriptPath
        ))

    Write-Verbose "ffprobe args: $($ffprobeArgs -join ' ')"
    $ffprobeOutput = & $ffprobeApp @ffprobeArgs 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        throw "ffprobe завершился с кодом $exitCode : $ffprobeOutput"
    }

    try {
        $infoJson = $ffprobeOutput | ConvertFrom-Json -Depth 10
    }
    catch {
        throw "Не удалось распарсить JSON от ffprobe: $_"
    }

    $stream = $infoJson.streams | Select-Object -First 1
    if (-not $stream) {
        throw "Не удалось получить информацию из '$ScriptPath' с помощью ffprobe"
    }

    # --- FPS ---
    $fpsRaw = if ($stream.avg_frame_rate -and $stream.avg_frame_rate -ne '0/0') {
        $stream.avg_frame_rate
    }
    else {
        $stream.r_frame_rate
    }

    $fpsNum = 0; $fpsDen = 1; $fpsValue = 0
    if ($fpsRaw -match '^(?<num>\d+)/(?<den>\d+)$') {
        $fpsNum = [int]$Matches.num
        $fpsDen = [int]$Matches.den
        if ($fpsDen -gt 0) { $fpsValue = $fpsNum / $fpsDen }
    }
    elseif ($fpsRaw -match '^[\d.]+$') {
        $fpsValue = [int]$fpsRaw
        $fpsNum = $fpsValue
        $fpsDen = 1
    }

    # --- Frame count: приоритет дешёвых источников ---
    $frameCount = $null
    $frameCountSource = $null

    # 1) nb_frames из stream (самый дешёвый)
    if (-not [string]::IsNullOrWhiteSpace($stream.nb_frames) -and $stream.nb_frames -ne 'N/A') {
        $frameCount = [long]$stream.nb_frames
        $frameCountSource = 'nb_frames'
    }
    # 2) NUMBER_OF_FRAMES из тегов (тоже дешёвый)
    if ($stream.tags -and -not [string]::IsNullOrWhiteSpace($stream.tags.NUMBER_OF_FRAMES) -and $stream.tags.NUMBER_OF_FRAMES -ne 'N/A') {
        $frameCount = [long]$stream.tags.NUMBER_OF_FRAMES
        $frameCountSource = 'NUMBER_OF_FRAMES'
    }
    # 3) nb_read_packets (только если запросили -CountPackets)
    elseif (-not [string]::IsNullOrWhiteSpace($stream.nb_read_packets) -and $stream.nb_read_packets -ne 'N/A') {
        $frameCount = [long]$stream.nb_read_packets
        $frameCountSource = 'nb_read_packets'
    }

    # --- Duration ---
    $duration = 0.0
    if (-not [string]::IsNullOrWhiteSpace($stream.duration) -and $stream.duration -ne 'N/A') {
        $duration = [double]$stream.duration
    }
    elseif ($stream.tags -and -not [string]::IsNullOrWhiteSpace($stream.tags.DURATION)) {
        # MKV-тег в формате HH:MM:SS.nnnnnnnnn
        $ts = [TimeSpan]::Zero
        if ([TimeSpan]::TryParse(
                $stream.tags.DURATION,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [ref]$ts)) {
            $duration = $ts.TotalSeconds
        }
    }
    if ($duration -le 0 -and $frameCount -and $fpsValue -gt 0) {
        $duration = $frameCount / $fpsValue
    }

    # --- Dolby Vision ---
    $isDolbyVision = $false
    $dvProfile = $null
    $dvBlPresent = $false
    $dvBlCompatId = $null

    $doviData = $stream.side_data_list | Where-Object { $_.side_data_type -eq 'DOVI configuration record' } | Select-Object -First 1
    if ($doviData) {
        $isDolbyVision = $true
        $dvProfile = $doviData.dv_profile
        $dvBlPresent = ([int]$doviData.bl_present_flag) -eq 1
        $dvBlCompatId = $doviData.dv_bl_signal_compatibility_id
    }

    # --- HDR10 / HLG ---
    $isHdr10 = $false
    $isHlg = $false
    if ($stream.color_transfer -eq 'smpte2084' -and $stream.color_primaries -eq 'bt2020') {
        $isHdr10 = $true
    }
    elseif ($stream.color_transfer -eq 'arib-std-b67') {
        $isHlg = $true
    }
    # DoVi Profile 5 — DV-only, не HDR10
    if ($isDolbyVision -and -not $dvBlPresent) {
        $isHdr10 = $false
    }

    [PSCustomObject]@{
        Index            = [int]$stream.index
        Frames           = $frameCount
        FramesSource     = $frameCountSource
        FPS              = [math]::Round($fpsValue, 3)
        FPSnum           = $fpsNum
        FPSden           = $fpsDen
        Width            = [int]$stream.width
        Height           = [int]$stream.height
        Codec            = $stream.codec_name
        Duration         = [math]::Round($duration, 3)
        DurationTimeSpan = [TimeSpan]::FromSeconds($duration)
        color_primaries  = $stream.color_primaries
        color_transfer   = $stream.color_transfer
        color_space      = $stream.color_space
        isDoVi           = $isDolbyVision
        dvProfile        = $dvProfile
        dvBlPresent      = $dvBlPresent
        dvBlCompatId     = $dvBlCompatId
        isHDR            = $isHdr10
        isHLG            = $isHlg
    }
}