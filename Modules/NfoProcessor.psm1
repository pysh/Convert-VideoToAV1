<#
.SYNOPSIS
    Обрабатывает NFO файлы и конвертирует в XML теги для MKV
#>

function Invoke-NfoProcessing {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Job)
    
    if (-not $Job.NfoPath -or -not (Test-Path $Job.NfoPath)) {
        Write-Log "NFO файл не найден" -Severity Verbose -Category 'Metadata'
        return $Job
    }
    
    Write-Log "Обработка NFO: $([IO.Path]::GetFileName($Job.NfoPath))" -Severity Information -Category 'Metadata'
    
    $nfoContent = Get-Content $Job.NfoPath -Raw -Encoding UTF8
    
    if ($nfoContent -match '^\s*<\?xml') {
        [xml]$xml = $nfoContent
        $episode = $xml.episodedetails
    } else {
        throw "NFO файл не является XML: $($Job.NfoPath)"
    }
    
    $tagsFile = Join-Path $Job.WorkingDir 'nfo_tags.xml'
    $Job.NfoFields = Convert-NfoToTagsXml -Episode $episode -OutputFile $tagsFile
    
    if (Test-Path $tagsFile) {
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
    
    # Основные поля
    $basicFields = @{
        TITLE = $Episode.title
        ORIGINAL_TITLE = $Episode.originaltitle
        SUMMARY = $Episode.plot
        DATE_RELEASED = $Episode.premiered
        AIR_DATE = $Episode.aired
        PART_NUMBER = $Episode.episode
        SEASON_NUMBER = $Episode.season
        SHOWTITLE = $Episode.showtitle
        DIRECTOR = $Episode.director
        GENRE = $Episode.genre
        RATING = $Episode.rating
    }
    
    foreach ($field in $basicFields.GetEnumerator()) {
        $value = $field.Value
        if ($value -and -not [string]::IsNullOrWhiteSpace($value.ToString())) {
            $fields[$field.Key] = $value.ToString()
            
            $writer.WriteStartElement('Simple')
            $writer.WriteElementString('Name', $field.Key)
            $writer.WriteElementString('String', $value.ToString())
            $writer.WriteEndElement()
        }
    }
    
    # Студии
    if ($Episode.studio) {
        $studios = if ($Episode.studio -is [array]) { $Episode.studio } else { @($Episode.studio) }
        foreach ($studio in $studios) {
            if ($studio) {
                $writer.WriteStartElement('Simple')
                $writer.WriteElementString('Name', 'STUDIO')
                $writer.WriteElementString('String', $studio)
                $writer.WriteEndElement()
            }
        }
    }
    
    # Уникальные идентификаторы
    if ($Episode.uniqueid) {
        $ids = if ($Episode.uniqueid -is [array]) { $Episode.uniqueid } else { @($Episode.uniqueid) }
        foreach ($id in $ids) {
            $type = $id.type
            $value = $id.InnerText
            if ($type -and $value) {
                $writer.WriteStartElement('Simple')
                $writer.WriteElementString('Name', $type.ToUpper())
                $writer.WriteElementString('String', $value)
                $writer.WriteEndElement()
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