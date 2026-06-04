<#
.SYNOPSIS
    Модуль для работы с цветовыми пространствами и характеристиками видео
#>

# Хеш-таблицы для преобразования цветовых параметров
$script:ColorRangeMappings = @{
    'tv' = @{
        'aomenc' = @{ param = '--color-range='; value = '0' };
        'x264'   = @{ param = '--range='; value = '0' };
        'x265'   = @{ param = '--range'; value = 'limited' };
        'svt'    = @{ param = '--color-range'; value = '0' } 
    }
    'pc' = @{
        'aomenc' = @{ param = '--color-range='; value = '1' };
        'x264'   = @{ param = '--range='; value = '1' };
        'x265'   = @{ param = '--range'; value = 'full' };
        'svt'    = @{ param = '--color-range'; value = '1' } 
    }
}

$script:ColorPrimariesMappings = @{
    'bt709'     = @{
        'aomenc' = @{ param = '--color-primaries='; value = 'bt709' };
        'x264'   = @{ param = '--colorprim='; value = '1' };
        'x265'   = @{ param = '--colorprim'; value = 'bt709' };
        'svt'    = @{ param = '--color-primaries'; value = '1' } 
    }
    'bt470bg'   = @{
        'aomenc' = @{ param = '--color-primaries='; value = 'bt470bg' };
        'x264'   = @{ param = '--colorprim='; value = '5' };
        'x265'   = @{ param = '--colorprim'; value = 'bt470bg' };
        'svt'    = @{ param = '--color-primaries'; value = '5' } 
    }
    'bt470m'    = @{
        'aomenc' = @{ param = '--color-primaries='; value = 'bt470m' };
        'x264'   = @{ param = '--colorprim='; value = '4' };
        'x265'   = @{ param = '--colorprim'; value = 'bt470m' };
        'svt'    = @{ param = '--color-primaries'; value = '4' } 
    }
    'bt2020'    = @{
        'aomenc' = @{ param = '--color-primaries='; value = 'bt2020' };
        'x264'   = @{ param = '--colorprim='; value = '9' };
        'x265'   = @{ param = '--colorprim'; value = 'bt2020' };
        'svt'    = @{ param = '--color-primaries'; value = '9' } 
    }
    'smpte170m' = @{
        'aomenc' = @{ param = '--color-primaries='; value = 'smpte170m' };
        'x264'   = @{ param = '--colorprim='; value = '6' };
        'x265'   = @{ param = '--colorprim'; value = 'smpte170m' };
        'svt'    = @{ param = '--color-primaries'; value = '6' } 
    }
    'smpte240m' = @{
        'aomenc' = @{ param = '--color-primaries='; value = 'smpte240m' };
        'x264'   = @{ param = '--colorprim='; value = '7' };
        'x265'   = @{ param = '--colorprim'; value = 'smpte240m' };
        'svt'    = @{ param = '--color-primaries'; value = '7' } 
    }
    'film'      = @{
        'aomenc' = @{ param = '--color-primaries='; value = 'film' };
        'x264'   = @{ param = '--colorprim='; value = '8' };
        'x265'   = @{ param = '--colorprim'; value = 'film' };
        'svt'    = @{ param = '--color-primaries'; value = '8' } 
    }
}

$script:TransferMappings = @{
    'bt709'     = @{
        'aomenc' = @{ param = '--transfer-characteristics='; value = 'bt709' };
        'x264'   = @{ param = '--transfer='; value = '1' };
        'x265'   = @{ param = '--transfer'; value = 'bt709' };
        'svt'    = @{ param = '--transfer-characteristics'; value = '1' } 
    }
    'bt470bg'   = @{
        'aomenc' = @{ param = '--transfer-characteristics='; value = 'bt470bg' };
        'x264'   = @{ param = '--transfer='; value = '5' };
        'x265'   = @{ param = '--transfer'; value = 'bt470bg' };
        'svt'    = @{ param = '--transfer-characteristics'; value = '5' } 
    }
    'bt470m'    = @{
        'aomenc' = @{ param = '--transfer-characteristics='; value = 'bt470m' };
        'x264'   = @{ param = '--transfer='; value = '4' };
        'x265'   = @{ param = '--transfer'; value = 'bt470m' };
        'svt'    = @{ param = '--transfer-characteristics'; value = '4' } 
    }
    'bt2020-10' = @{
        'aomenc' = @{ param = '--transfer-characteristics='; value = 'bt2020-10bit' };
        'x264'   = @{ param = '--transfer='; value = '14' };
        'x265'   = @{ param = '--transfer'; value = 'bt2020-10' };
        'svt'    = @{ param = '--transfer-characteristics'; value = '14' } 
    }
    'bt2020-12' = @{
        'aomenc' = @{ param = '--transfer-characteristics='; value = 'bt2020-12bit' };
        'x264'   = @{ param = '--transfer='; value = '15' };
        'x265'   = @{ param = '--transfer'; value = 'bt2020-12' };
        'svt'    = @{ param = '--transfer-characteristics'; value = '15' } 
    }
    'smpte170m' = @{
        'aomenc' = @{ param = '--transfer-characteristics='; value = 'unspecified' };
        'x264'   = @{ param = '--transfer='; value = '6' };
        'x265'   = @{ param = '--transfer'; value = 'smpte170m' };
        'svt'    = @{ param = '--transfer-characteristics'; value = '6' } 
    }
    'smpte240m' = @{
        'aomenc' = @{ param = '--transfer-characteristics='; value = 'unspecified' };
        'x264'   = @{ param = '--transfer='; value = '7' };
        'x265'   = @{ param = '--transfer'; value = 'smpte240m' };
        'svt'    = @{ param = '--transfer-characteristics'; value = '7' } 
    }
    'smpte2084' = @{
        'aomenc' = @{ param = '--transfer-characteristics='; value = 'smpte2084' };
        'x264'   = @{ param = '--transfer='; value = '16' };
        'x265'   = @{ param = '--transfer'; value = 'smpte2084' };
        'svt'    = @{ param = '--transfer-characteristics'; value = '16' } 
    }
}

$script:MatrixMappings = @{
    'bt709'     = @{
        'aomenc' = @{ param = '--matrix-coefficients='; value = '1' };
        'x264'   = @{ param = '--colormatrix='; value = '1' };
        'x265'   = @{ param = '--colormatrix'; value = 'bt709' };
        'svt'    = @{ param = '--matrix-coefficients'; value = '1' } 
    }
    'fcc'       = @{
        'aomenc' = @{ param = '--matrix-coefficients='; value = '4' };
        'x264'   = @{ param = '--colormatrix='; value = '4' };
        'x265'   = @{ param = '--colormatrix'; value = 'fcc' };
        'svt'    = @{ param = '--matrix-coefficients'; value = '4' } 
    }
    'bt470bg'   = @{
        'aomenc' = @{ param = '--matrix-coefficients='; value = '5' };
        'x264'   = @{ param = '--colormatrix='; value = '5' };
        'x265'   = @{ param = '--colormatrix'; value = 'bt470bg' };
        'svt'    = @{ param = '--matrix-coefficients'; value = '5' } 
    }
    'smpte170m' = @{
        'aomenc' = @{ param = '--matrix-coefficients='; value = '6' };
        'x264'   = @{ param = '--colormatrix='; value = '6' };
        'x265'   = @{ param = '--colormatrix'; value = 'smpte170m' };
        'svt'    = @{ param = '--matrix-coefficients'; value = '6' } 
    }
    'smpte240m' = @{
        'aomenc' = @{ param = '--matrix-coefficients='; value = '7' };
        'x264'   = @{ param = '--colormatrix='; value = '7' };
        'x265'   = @{ param = '--colormatrix'; value = 'smpte240m' };
        'svt'    = @{ param = '--matrix-coefficients'; value = '7' } 
    }
    'bt2020nc'  = @{
        'aomenc' = @{ param = '--matrix-coefficients='; value = '9' };
        'x264'   = @{ param = '--colormatrix='; value = '9' };
        'x265'   = @{ param = '--colormatrix'; value = 'bt2020nc' };
        'svt'    = @{ param = '--matrix-coefficients'; value = '9' } 
    }
    'bt2020c'   = @{
        'aomenc' = @{ param = '--matrix-coefficients='; value = '10' };
        'x264'   = @{ param = '--colormatrix='; value = '10' };
        'x265'   = @{ param = '--colormatrix'; value = 'bt2020c' };
        'svt'    = @{ param = '--matrix-coefficients'; value = '10' } 
    }
}

function Get-VideoColorParams {
    <#
    .SYNOPSIS
        Получает цветовые параметры видеофайла
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VideoFilePath
    )

    $colorParams = & ffprobe -v error -select_streams v:0 `
        -show_entries "stream=color_range,color_space,color_transfer,color_primaries" `
        -of default=noprint_wrappers=1 "$VideoFilePath" 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "Не удалось получить цветовые параметры видео: $colorParams"
    }

    $result = @{}
    $colorParams | ForEach-Object {
        if ($_ -match '(.+)=(.+)') {
            $key = $matches[1]
            $value = $matches[2]
            if ($value -ne 'unknown') {
                $result[$key] = $value
            }
        }
    }

    return [PSCustomObject]@{
        ColorRange     = $result['color_range']
        ColorSpace     = $result['color_space']
        ColorTransfer  = $result['color_transfer']
        ColorPrimaries = $result['color_primaries']
    }
}

function Get-VideoColorMappings {
    <#
    .SYNOPSIS
        Получает маппинги цветовых параметров для различных энкодеров
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$VideoPath
    )

    $colorParams = Get-VideoColorParams -VideoFilePath $VideoPath
    $mappings = @{}

    # Map color range
    if ($colorParams.ColorRange -and $script:ColorRangeMappings[$colorParams.ColorRange]) {
        $mappings['Range'] = $script:ColorRangeMappings[$colorParams.ColorRange]
    }

    # Map color primaries
    if ($colorParams.ColorPrimaries -and $script:ColorPrimariesMappings[$colorParams.ColorPrimaries]) {
        $mappings['Primaries'] = $script:ColorPrimariesMappings[$colorParams.ColorPrimaries]
    }

    # Map transfer characteristics
    if ($colorParams.ColorTransfer -and $script:TransferMappings[$colorParams.ColorTransfer]) {
        $mappings['Transfer'] = $script:TransferMappings[$colorParams.ColorTransfer]
    }

    # Map matrix coefficients
    if ($colorParams.ColorSpace -and $script:MatrixMappings[$colorParams.ColorSpace]) {
        $mappings['Matrix'] = $script:MatrixMappings[$colorParams.ColorSpace]
    }

    return $mappings
}

function Test-VideoHDR {
    <#
    .SYNOPSIS
        Проверяет, является ли видео HDR/DV
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VideoPath)
    
    try {
        $ffprobeOutput = & $global:VideoTools.FFprobe -v error -select_streams v:0 `
            -show_entries stream=color_primaries,color_transfer,color_space,side_data_list `
            -of json $VideoPath | ConvertFrom-Json
        
        $stream = $ffprobeOutput.streams[0]
        
        # Проверяем цветовые характеристики HDR
        $isHDR = $false
        
        # Проверяем transfer characteristics
        if ($stream.color_transfer -in ('smpte2084', 'arib-std-b67')) {
            $isHDR = $true
        }
        
        # Проверяем color primaries
        if ($stream.color_primaries -eq 'bt2020') {
            $isHDR = $true
        }
        
        # Проверяем Dolby Vision side data
        if ($stream.side_data_list) {
            foreach ($sideData in $stream.side_data_list) {
                if ($sideData.side_data_type -eq 'DOVI configuration record') {
                    $isHDR = $true
                    Write-Log "Обнаружен Dolby Vision" -Severity Information -Category 'Video'
                    break
                }
            }
        }
        
        return $isHDR
    }
    catch {
        Write-Log "Ошибка при определении HDR/DV: $_" -Severity Warning -Category 'Video'
        return $false
    }
}

class VideoColorInfo {
    [bool]$IsHDR
    [bool]$IsDolbyVision
    [string]$ColorPrimaries
    [string]$ColorTransfer
    [string]$ColorSpace
    [string]$ColorRange
    [string]$HDRFormat
    [double]$MaxLuminance
    [double]$MinLuminance
    [string]$MatrixCoefficients
    
    VideoColorInfo() {
        $this.IsHDR = $false
        $this.IsDolbyVision = $false
        $this.HDRFormat = "SDR"
    }
    
    [string] ToString() {
        if ($this.IsHDR) {
            $format = if ($this.IsDolbyVision) { "Dolby Vision" } else { $this.HDRFormat }
            return "HDR ($format) - Primaries: $($this.ColorPrimaries), Transfer: $($this.ColorTransfer)"
        }
        return "SDR - Primaries: $($this.ColorPrimaries), Transfer: $($this.ColorTransfer)"
    }
}

function Get-DetailedVideoColorInfo {
    <#
    .SYNOPSIS
        Получает детальную информацию о цветовых характеристиках видео
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VideoPath
    )
    
    try {
        $colorInfo = [VideoColorInfo]::new()
        
        # Получаем базовую информацию через ffprobe
        $ffprobeOutput = & $global:VideoTools.FFprobe -v error -select_streams v:0 `
            -show_entries stream=color_primaries,color_transfer,color_space,color_range,side_data_list `
            -show_entries format_tags=MAXCLL,MAXFALL `
            -of json $VideoPath | ConvertFrom-Json
        
        $stream = $ffprobeOutput.streams[0]
        $formatTags = $ffprobeOutput.format.tags
        
        # Заполняем базовые цветовые характеристики
        $colorInfo.ColorPrimaries = $stream.color_primaries ?? 'unknown'
        $colorInfo.ColorTransfer = $stream.color_transfer ?? 'unknown'
        $colorInfo.ColorSpace = $stream.color_space ?? 'unknown'
        $colorInfo.ColorRange = $stream.color_range ?? 'unknown'
        
        # Определяем HDR характеристики
        $colorInfo.IsHDR = $false
        
        # Проверяем transfer characteristics для HDR
        if ($stream.color_transfer -in ('smpte2084', 'arib-std-b67', 'bt2020-10', 'bt2020-12')) {
            $colorInfo.IsHDR = $true
            $colorInfo.HDRFormat = switch ($stream.color_transfer) {
                'smpte2084' { 'HDR10' }
                'arib-std-b67' { 'HLG' }
                'bt2020-10' { 'HDR10' }
                'bt2020-12' { 'HDR10' }
                default { 'HDR' }
            }
        }
        
        # Проверяем Dolby Vision
        if ($stream.side_data_list) {
            foreach ($sideData in $stream.side_data_list) {
                if ($sideData.side_data_type -eq 'DOVI configuration record') {
                    $colorInfo.IsHDR = $true
                    $colorInfo.IsDolbyVision = $true
                    $colorInfo.HDRFormat = 'Dolby Vision'
                    break
                }
            }
        }
        
        # Получаем информацию о яркости из метаданных
        if ($formatTags) {
            if ($formatTags.MAXCLL) {
                $colorInfo.MaxLuminance = [double]$formatTags.MAXCLL
            }
            if ($formatTags.MAXFALL) {
                $colorInfo.MinLuminance = [double]$formatTags.MAXFALL
            }
        }
        
        # Определяем матричные коэффициенты
        if ($stream.color_space -and $script:MatrixMappings[$stream.color_space]) {
            $colorInfo.MatrixCoefficients = $stream.color_space
        }
        
        Write-Log "Цветовая информация: $colorInfo" -Severity Information -Category 'Video'
        return $colorInfo
    }
    catch {
        Write-Log "Ошибка при получении цветовой информации: $_" -Severity Warning -Category 'Video'
        # Возвращаем базовый объект с информацией об ошибке
        $colorInfo.IsHDR = Test-VideoHDR -VideoPath $VideoPath
        return $colorInfo
    }
}

function Get-RecommendedEncoderSettings {
    <#
    .SYNOPSIS
        Рекомендует настройки энкодера на основе характеристик видео
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [VideoColorInfo]$ColorInfo,
        
        [Parameter(Mandatory)]
        [string]$EncoderName,
        
        [object]$VideoStats
    )
    
    $recommendations = @{
        Encoder = $EncoderName
        QualityAdjustment = 0
        PresetAdjustment = 0
        AdditionalParams = @()
        Notes = @()
    }
    
    # Рекомендации для HDR контента
    if ($ColorInfo.IsHDR) {
        $recommendations.Notes += "HDR контент: $($ColorInfo.HDRFormat)"
        
        switch ($EncoderName) {
            { $_ -like 'SvtAv1Enc*' } {
                if ($ColorInfo.IsDolbyVision) {
                    $recommendations.AdditionalParams += '--enable-dolby-vision', '1'
                    $recommendations.Notes += "Включена поддержка Dolby Vision"
                }
                
                # Для HDR немного увеличиваем качество
                $recommendations.QualityAdjustment = -2
                $recommendations.Notes += "HDR требует более высокого битрейта"
            }
            
            'AomAv1Enc' {
                $recommendations.AdditionalParams += '--color-primaries=bt2020', '--transfer-characteristics=smpte2084'
                if ($ColorInfo.MaxLuminance -gt 0) {
                    $recommendations.AdditionalParams += "--mastering-display=$($ColorInfo.MaxLuminance)nits"
                }
            }
        }
    }
    
    # Рекомендации на основе разрешения
    if ($VideoStats -and $VideoStats.ResolutionWidth -gt 1920) {
        $recommendations.Notes += "Высокое разрешение: $($VideoStats.ResolutionWidth)x$($VideoStats.ResolutionHeight)"
        
        # Для 4K+ уменьшаем preset для лучшего качества
        if ($VideoStats.ResolutionWidth -gt 3840) {
            $recommendations.PresetAdjustment = -2
            $recommendations.Notes += "8K контент: используем более медленный preset"
        } elseif ($VideoStats.ResolutionWidth -gt 2560) {
            $recommendations.PresetAdjustment = -1
            $recommendations.Notes += "4K контент: умеренное снижение скорости"
        }
    }
    
    return $recommendations
}

Export-ModuleMember -Function `
    Get-VideoColorParams, `
    Get-VideoColorMappings, `
    Test-VideoHDR, `
    Get-DetailedVideoColorInfo, `
    Get-RecommendedEncoderSettings