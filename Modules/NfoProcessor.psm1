<#
.SYNOPSIS
    Обрабатывает NFO файлы и конвертирует в XML теги для MKV
#>

function Invoke-NfoProcessing {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Job)
    
    if (-not $Job.NfoPath -or -not (Test-Path -LiteralPath $Job.NfoPath)) {
        Write-Log "NFO файл не найден" -Severity Verbose -Category 'Metadata'
        return $Job
    }
    
    Write-Log "Обработка NFO: $([IO.Path]::GetFileName($Job.NfoPath))" -Severity Information -Category 'Metadata'
    
    $nfoContent = Get-Content -LiteralPath $Job.NfoPath -Raw -Encoding UTF8
    
    if ($nfoContent -match '^\s*<\?xml') {
        [xml]$xml = $nfoContent
        $episode = $xml.episodedetails
    } else {
        throw "NFO файл не является XML: $($Job.NfoPath)"
    }
    
    $tagsFile = Join-Path $Job.WorkingDir 'nfo_tags.xml'
    $Job.NfoFields = Convert-NfoToTagsXml -Episode $episode -OutputFile $tagsFile
    
    if (Test-Path -LiteralPath $tagsFile) {
        $Job.NfoTags = $tagsFile
        $Job.TempFiles.Add($tagsFile)
        Write-Log "NFO успешно конвертирован в XML теги" -Severity Success -Category 'Metadata'
    }
    
    return $Job
}

function Convert-NfoToTagsXml {
    [CmdletBinding()]
    param([object]$Episode, [string]$OutputFile)
    
    $fields = @{}
    
    $settings = [System.Xml.XmlWriterSettings]@{
        Indent = $true
        Encoding = [System.Text.Encoding]::UTF8
        ConformanceLevel = [System.Xml.ConformanceLevel]::Document
    }
    
    $writer = [System.Xml.XmlWriter]::Create($OutputFile, $settings)
    
    $writer.WriteStartDocument()
    $writer.WriteStartElement('Tags')
    $writer.WriteStartElement('Tag')
    $writer.WriteStartElement('Targets')
    $writer.WriteElementString('TargetTypeValue', '50')
    $writer.WriteEndElement()
    
    # Вспомогательная функция для получения уникальных значений
    function Get-UniqueValues {
        param($Value)
        
        if ($null -eq $Value) {
            return @()
        }
        
        $array = if ($Value -is [array]) { $Value } else { @($Value) }
        
        $array | 
            Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace($_.ToString()) } |
            ForEach-Object { $_.ToString().Trim() } |
            Where-Object { $_ -ne '' } |
            Select-Object -Unique
    }
    
    # Функция для получения текстового значения узла (игнорируя атрибуты)
    function Get-NodeText {
        param($Node)
        
        if ($null -eq $Node) {
            return $null
        }
        
        if ($Node -is [array]) {
            return $Node | ForEach-Object { $_.InnerText.Trim() }
        }
        
        return $Node.InnerText.Trim()
    }
    
    # Основные поля (все могут быть массивами)
    $fieldMappings = @{
        'TITLE'          = $Episode.title
        'ORIGINAL_TITLE' = $Episode.originaltitle
        'SUMMARY'        = $Episode.plot
        'DATE_RELEASED'  = $Episode.premiered
        'AIR_DATE'       = $Episode.aired
        'PART_NUMBER'    = $Episode.episode
        'SEASON_NUMBER'  = $Episode.season
        'SHOWTITLE'      = $Episode.showtitle
        'GENRE'          = $Episode.genre
        'RATING'         = $Episode.rating
        'STUDIO'         = $Episode.studio
    }
    
    # Обработка director отдельно (берем только текст, игнорируя атрибуты)
    $directorValues = Get-NodeText -Node $Episode.director
    if ($directorValues) {
        $fieldMappings['DIRECTOR'] = $directorValues
    }
    
    foreach ($fieldName in $fieldMappings.Keys) {
        $values = Get-UniqueValues -Value $fieldMappings[$fieldName]
        
        if ($values.Count -gt 0) {
            $fields[$fieldName] = $values -join '; '
            
            foreach ($value in $values) {
                $writer.WriteStartElement('Simple')
                $writer.WriteElementString('Name', $fieldName)
                $writer.WriteElementString('String', $value)
                $writer.WriteEndElement()
            }
        }
    }
    
    # Уникальные идентификаторы (отдельно в конце)
    if ($Episode.uniqueid) {
        $ids = if ($Episode.uniqueid -is [array]) { $Episode.uniqueid } else { @($Episode.uniqueid) }
        
        # Собираем все ID по типам, удаляя дубли
        $uniqueIds = @{}
        foreach ($id in $ids) {
            $type = $id.type
            $value = $id.InnerText
            if ($type -and $value -and -not [string]::IsNullOrWhiteSpace($value)) {
                $key = $type.ToUpper().Trim()
                $trimmedValue = $value.Trim()
                
                if (-not $uniqueIds.ContainsKey($key)) {
                    $uniqueIds[$key] = [System.Collections.Generic.HashSet[string]]::new()
                }
                [void]$uniqueIds[$key].Add($trimmedValue)
            }
        }
        
        # Записываем уникальные ID
        foreach ($key in $uniqueIds.Keys) {
            $values = $uniqueIds[$key]
            if ($values.Count -gt 0) {
                $fields[$key] = $values -join '; '
                foreach ($value in $values) {
                    $writer.WriteStartElement('Simple')
                    $writer.WriteElementString('Name', $key)
                    $writer.WriteElementString('String', $value)
                    $writer.WriteEndElement()
                }
            }
        }
    }
    
    $writer.WriteEndElement() # Tag
    $writer.WriteEndElement() # Tags
    $writer.WriteEndDocument()
    $writer.Close()
    
    return $fields
}

Export-ModuleMember -Function Invoke-NfoProcessing