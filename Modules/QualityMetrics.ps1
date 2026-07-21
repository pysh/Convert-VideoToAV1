function Get-VideoQualityMetrics3 {
<#
.SYNOPSIS
    Calculates VMAF, XPSNR, PSNR and SSIM quality metrics for video files with parallel processing.
.EXAMPLE
    Get-VideoQualityMetrics2 -DistortedPaths @("enc1.mkv", "enc2.mkv") -ReferencePath "source.mkv" -Metrics All
.EXAMPLE
    Get-VideoQualityMetrics2 -DistortedPaths "encoded.mkv" -ReferencePath "source.vpy" -Metrics VMAF,XPSNR
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$DistortedPaths,
        
        [Parameter(Mandatory)]
        [string]$ReferencePath,

        [ValidateSet('VMAF', 'XPSNR', 'PSNR', 'SSIM', 'All')]
        [string[]]$Metrics = @('VMAF'),

        [PSCustomObject]$Crop = @{
            Left          = 0
            Right         = 0
            Top           = 0
            Bottom        = 0
            CropDistVideo = $false
        },

        [int]$TrimStartSeconds = 0,
        [int]$DurationSeconds = 0,

        [string]$ModelVersion = 'vmaf_4k_v0.6.1',

        [int]$Threads = [Environment]::ProcessorCount,
        [int]$Subsample = 1,

        [string]$LogPath,

        [ValidateSet('mean', 'harmonic_mean')]
        [string]$PoolMethod = 'mean',
        
        [switch]$Parallel = $true
    )
    
    # If 'All' is specified, expand to all metrics
    if ($Metrics -contains 'All') {
        $Metrics = @('VMAF', 'XPSNR', 'PSNR', 'SSIM')
    }
    
    # Validate files
    if (-not (Test-Path -LiteralPath $ReferencePath)) {
        throw "Reference file not found: $ReferencePath"
    }
    foreach ($file in $DistortedPaths) {
        if (-not (Test-Path -LiteralPath $file)) {
            throw "File not found: $file"
        }
    }
    
    # Helper function to detect file type
    function Get-FileType {
        param([string]$Path)
        $ext = [IO.Path]::GetExtension($Path).ToLower()
        if ($ext -eq '.vpy') { return 'VapourSynth' }
        if ($ext -eq '.avs') { return 'AviSynth' }
        return 'Video'
    }

    # Helper function to convert frame rate to double
    function Convert-FpsToDouble {
        param ([string]$FpsString)

        if ($FpsString -match '^\d+/\d+$') {
            $numerator, $denominator = $FpsString -split '/'
            return [double]$numerator / [double]$denominator
        }
        elseif ($FpsString -match '^\d+(\.\d+)?$') {
            return [double]$FpsString
        }
        else {
            throw "Некорректный формат FPS: $FpsString"
        }
    }    

    # Helper function to get frame rate
    function Get-FrameRate {
        param([string]$Path, [string]$FileType)
        
        try {
            if ($FileType -eq 'VapourSynth') {
                $output = & vspipe -i $Path --info 2>&1
                $fpsLine = $output | Where-Object { $_ -match 'FPS:\s*([\d\/]+(?:\.\d+)?)' }
                if ($fpsLine) {
                    $fps = [regex]::Match($fpsLine, 'FPS:\s*([\d\/]+(?:\.\d+)?)').Groups[1].Value
                    return [double][Math]::Round((Convert-FpsToDouble -FpsString $fps), 3)
                }
            }
            elseif ($FileType -eq 'AviSynth') {
                $ffprobe = (Get-Command ffprobe -ErrorAction Stop).Source
                $output = & $ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 $Path 2>&1
                if ($LASTEXITCODE -eq 0 -and $output) {
                    $fps = $output.Trim()
                    if ($fps -match '(\d+)/(\d+)') {
                        return [math]::Round([double]$Matches[1] / [double]$Matches[2], 3)
                    }
                    return [double]$fps
                }
            }
            else {
                $ffprobe = (Get-Command ffprobe -ErrorAction Stop).Source
                $output = & $ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 $Path 2>&1
                if ($LASTEXITCODE -eq 0 -and $output) {
                    $fps = $output.Trim()
                    if ($fps -match '(\d+)/(\d+)') {
                        return [math]::Round([double]$Matches[1] / [double]$Matches[2], 3)
                    }
                    return [double]$fps
                }
            }
        }
        catch {}
        return 25.0  # Default fallback
    }
    
    # Function to build filter graph
    function Build-FilterGraph {
        param(
            [string]$DistFilter,
            [string]$RefFilter,
            [string[]]$MetricsList,
            [string]$ModelVer,
            [int]$ThreadsCount,
            [int]$SubsampleCount,
            [string]$PoolMeth,
            [string]$LogFilePath
        )
        
        # Determine how many splits we need
        $splitCount = 0
        $metricFilters = @()
        $metricIndex = 0
        
        # VMAF metrics (2 outputs: normal and harmonic)
        if ($MetricsList -contains 'VMAF') {
            # Normal VMAF
            $vmafParams = @(
                "eof_action=endall",
                "n_threads=$ThreadsCount",
                "n_subsample=$SubsampleCount",
                "model=version=$ModelVer",
                "pool=$PoolMeth"
            )
            if ($LogFilePath) {
                $vmafParams += "log_path='$($LogFilePath.Replace('\', '\\'))'"
                $vmafParams += "log_fmt=json"
            }
            $metricFilters += "[dst$metricIndex][src$metricIndex]libvmaf=$($vmafParams -join ':')"
            $metricIndex++
            
            # VMAF with harmonic mean
            $vmafNegParams = @(
                "eof_action=endall",
                "n_threads=$ThreadsCount",
                "n_subsample=$SubsampleCount",
                "model=version=${ModelVer}neg",
                "pool=harmonic_mean"
            )
            $metricFilters += "[dst$metricIndex][src$metricIndex]libvmaf=$($vmafNegParams -join ':')"
            $metricIndex++
            $splitCount += 2
        }
        
        # XPSNR
        if ($MetricsList -contains 'XPSNR') {
            $metricFilters += "[dst$metricIndex][src$metricIndex]xpsnr=eof_action=endall"
            $metricIndex++
            $splitCount += 1
        }
        
        # PSNR
        if ($MetricsList -contains 'PSNR') {
            $metricFilters += "[dst$metricIndex][src$metricIndex]psnr=eof_action=endall"
            $metricIndex++
            $splitCount += 1
        }
        
        # SSIM
        if ($MetricsList -contains 'SSIM') {
            $metricFilters += "[dst$metricIndex][src$metricIndex]ssim=eof_action=endall"
            $metricIndex++
            $splitCount += 1
        }
        
        # If no metrics specified, return empty
        if ($splitCount -eq 0) {
            return $null
        }
        
        # Build split labels with proper formatting
        # Use comma-separated format: [dst0][dst1][dst2]...
        $dstLabels = (0..($splitCount-1) | ForEach-Object { "[dst$_]" }) -join ''
        $srcLabels = (0..($splitCount-1) | ForEach-Object { "[src$_]" }) -join ''
        
        # Apply filters to each split with proper comma separation
        $distFiltered = if ($DistFilter) { "[0:v]$DistFilter" } else { "[0:v]" }
        $refFiltered = if ($RefFilter) { "[1:v]$RefFilter" } else { "[1:v]" }
        
        # Build complete filter graph with proper syntax
        # Format: [0:v]filter1,filter2,split=N[dst0][dst1][dst2]...;
        $filterGraph = "${distFiltered},split=$splitCount$dstLabels;"
        $filterGraph += "${refFiltered},split=$splitCount$srcLabels;"
        $filterGraph += ($metricFilters -join ';')
        
        return $filterGraph
    }

    # Detect file types and get frame rates
    $refType = Get-FileType -Path $ReferencePath
    $refFPS = Get-FrameRate -Path $ReferencePath -FileType $refType
    
    $distInfo = @{}
    foreach ($path in $DistortedPaths) {
        $type = Get-FileType -Path $path
        $fps = Get-FrameRate -Path $path -FileType $type
        $distInfo[$path] = @{ Type = $type; FPS = $fps }
    }
    
    # Build filters (once for all videos)
    $cropFilter = ''
    if ($Crop.Left -or $Crop.Right -or $Crop.Top -or $Crop.Bottom) {
        $cropFilter = "crop=w=iw-$($Crop.Left)-$($Crop.Right):h=ih-$($Crop.Top)-$($Crop.Bottom):x=$($Crop.Left):y=$($Crop.Top)"
    }
    
    $trimFilter = ''
    if ($TrimStartSeconds -gt 0 -or $DurationSeconds -gt 0) {
        $trimFilter = if ($DurationSeconds -gt 0) {
            "trim=start=${TrimStartSeconds}:duration=$DurationSeconds"
        }
        else {
            "trim=start=$TrimStartSeconds"
        }
    }
    
    $baseFilter = "settb=AVTB,setpts=PTS-STARTPTS,format=yuv420p"
    $commonFilters = @($trimFilter, $baseFilter) -ne '' -join ','
    
    # Build distorted video filters with proper comma separation
    $distFilters = @()
    if ($Crop.CropDistVideo -and $cropFilter) { $distFilters += $cropFilter }
    if ($commonFilters) { $distFilters += $commonFilters }
    $distFilterStr = if ($distFilters) { ($distFilters -join ',') } else { '' }

    # Build reference video filters with proper comma separation
    $refFilters = @()
    if ($cropFilter) { $refFilters += $cropFilter }
    if ($commonFilters) { $refFilters += $commonFilters }
    $refFilterStr = if ($refFilters) { ($refFilters -join ',') } else { '' }
    
    # Build filter graph once (will be used for all jobs)
    $filterGraph = Build-FilterGraph `
        -DistFilter $distFilterStr `
        -RefFilter $refFilterStr `
        -MetricsList $Metrics `
        -ModelVer $ModelVersion `
        -ThreadsCount $Threads `
        -SubsampleCount $Subsample `
        -PoolMeth $PoolMethod `
        -LogFilePath $LogPath
    
    # Header
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "  VIDEO QUALITY METRICS" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Reference: $([IO.Path]::GetFileName($ReferencePath))" -ForegroundColor White
    Write-Host "Reference Type: $refType, FPS: $refFPS" -ForegroundColor Gray
    Write-Host "Files: $($DistortedPaths.Count)" -ForegroundColor White
    Write-Host "Metrics: $($Metrics -join ', ')" -ForegroundColor White
    Write-Host "Threads: $(if ($Parallel) { $Threads } else { 'Sequential' })" -ForegroundColor White
    if ($filterGraph) {
        Write-Host "Filter Graph: $filterGraph" -ForegroundColor DarkGray
    }
    Write-Host "========================================" -ForegroundColor Cyan
    
    # Get ffmpeg path
    $ffmpeg = (Get-Command ffmpeg -ErrorAction Stop).Source
    
    # Prepare job list with pre-built filter graph
    $jobs = @{}
    $counter = 0
    foreach ($path in $DistortedPaths) {
        $counter++
        $jobs["job_$counter"] = @{
            Id             = $counter
            Total          = $DistortedPaths.Count
            DistortedPath  = $path
            DistortedType  = $distInfo[$path].Type
            DistortedFPS   = $distInfo[$path].FPS
            ReferencePath  = $ReferencePath
            ReferenceType  = $refType
            ReferenceFPS   = $refFPS
            FilterGraph    = $filterGraph
            Metrics        = $Metrics
            Threads        = $Threads
            FFmpegPath     = $ffmpeg
        }
    }
    
    # Process videos in parallel
    if ($Parallel -and $DistortedPaths.Count -gt 1) {
        Write-Host "Processing $($DistortedPaths.Count) videos in parallel..." -ForegroundColor Cyan
        
        $jobResults = $jobs.GetEnumerator() | ForEach-Object -Parallel {
            $jobName = $_.Key
            $job = $_.Value
            
            $ffmpeg = $job.FFmpegPath
            
            Write-Host "[$($job.Id)/$($job.Total)] Processing: $([IO.Path]::GetFileName($job.DistortedPath))" -ForegroundColor Yellow
            
            $result = [PSCustomObject]@{ 
                ReferencePath = $job.ReferencePath
                DistortedPath = $job.DistortedPath
                VMAF          = $null
                VMAFNeg       = $null
                XPSNR         = $null
                PSNR          = $null
                SSIM          = $null
                Timer         = $null
                FFmpegArgs    = $null
            }
            
            # Build input arguments with proper FPS for each file
            $distArgs = @()
            $distArgs += '-r', ($job.DistortedFPS.ToString().Replace(',', '.'))
            if ($job.DistortedType -eq 'VapourSynth') {
                $distArgs += '-f', 'vapoursynth'
            }
            elseif ($job.DistortedType -eq 'AviSynth') {
                $distArgs += '-f', 'avisynth'
            }
            $distArgs += '-i', $job.DistortedPath
            
            $refArgs = @()
            $refArgs += '-r', ($job.ReferenceFPS.ToString().Replace(',', '.'))
            if ($job.ReferenceType -eq 'VapourSynth') {
                $refArgs += '-f', 'vapoursynth'
            }
            elseif ($job.ReferenceType -eq 'AviSynth') {
                $refArgs += '-f', 'avisynth'
            }
            $refArgs += '-i', $job.ReferencePath
            
            # Use pre-built filter graph
            if ($job.FilterGraph) {
                $ffargs = @(
                    "-threads", $job.Threads,
                    "-hide_banner", "-y", "-nostats"
                ) + $distArgs + $refArgs + @(
                    "-filter_complex", $job.FilterGraph,
                    "-f", "null", "-"
                )
                
                $result.FFmpegArgs = $ffargs
                $timer = [System.Diagnostics.Stopwatch]::StartNew()
                $output = & $ffmpeg $ffargs 2>&1
                $timer.Stop()
                $result.Timer = $timer
                
                $outputStr = $output -join "`n"
                
                # Parse VMAF
                if ($job.Metrics -contains 'VMAF') {
                    $vmafMatches = [regex]::Matches($outputStr, 'VMAF score:\s*(\d+\.\d+)')
                    if ($vmafMatches.Count -ge 1) {
                        $result.VMAF = [double]$vmafMatches[0].Groups[1].Value
                        Write-Host "  VMAF: $($result.VMAF)" -ForegroundColor Green
                    }
                    else {
                        Write-Host "  VMAF: FAILED" -ForegroundColor Red
                    }
                    
                    # Parse VMAF negative (harmonic mean) - second VMAF score
                    if ($vmafMatches.Count -ge 2) {
                        $result.VMAFNeg = [double]$vmafMatches[1].Groups[1].Value
                        Write-Host "  VMAF (harm): $($result.VMAFNeg)" -ForegroundColor Cyan
                    }
                }
                
                # Parse XPSNR
                if ($job.Metrics -contains 'XPSNR') {
                    if ($outputStr -match [regex]'(?m)XPSNR.*y:\s*(?<y>\d+\.\d+).*u:\s*(?<u>\d+\.\d+).*v:\s*(?<v>\d+\.\d+)') {
                        $result.XPSNR = @{
                            Y    = [double]$Matches['y']
                            U    = [double]$Matches['u']
                            V    = [double]$Matches['v']
                            MIN  = (([double]$Matches['y'], [double]$Matches['u'], [double]$Matches['v']) | Measure-Object -Minimum).Minimum
                            AVG  = ([double]$Matches['y'] + [double]$Matches['u'] + [double]$Matches['v']) / 3
                            WSUM = (4 * [double]$Matches['y'] + [double]$Matches['u'] + [double]$Matches['v']) / 6
                        }
                        Write-Host "  XPSNR: $($result.XPSNR.WSUM.ToString('F2'))" -ForegroundColor Green
                    }
                    else {
                        Write-Host "  XPSNR: FAILED" -ForegroundColor Red
                    }
                }
                
                # Parse PSNR
                if ($job.Metrics -contains 'PSNR') {
                    if ($outputStr -match [regex]'(?m)PSNR.*y:\s*(?<y>\d+\.\d+).*u:\s*(?<u>\d+\.\d+).*v:\s*(?<v>\d+\.\d+)') {
                        $result.PSNR = @{
                            Y    = [double]$Matches['y']
                            U    = [double]$Matches['u']
                            V    = [double]$Matches['v']
                            MIN  = (([double]$Matches['y'], [double]$Matches['u'], [double]$Matches['v']) | Measure-Object -Minimum).Minimum
                            AVG  = ([double]$Matches['y'] + [double]$Matches['u'] + [double]$Matches['v']) / 3
                            WSUM = (4 * [double]$Matches['y'] + [double]$Matches['u'] + [double]$Matches['v']) / 6
                        }
                        Write-Host "  PSNR: $($result.PSNR.WSUM.ToString('F2'))" -ForegroundColor Green
                    }
                    else {
                        Write-Host "  PSNR: FAILED" -ForegroundColor Red
                    }
                }
                
                # Parse SSIM
                if ($job.Metrics -contains 'SSIM') {
                    if ($outputStr -match [regex]'(?m)SSIM.*All:\s*(?<all>\d+\.\d+)') {
                        $result.SSIM = [double]$Matches['all']
                        Write-Host "  SSIM: $($result.SSIM.ToString('F4'))" -ForegroundColor Green
                    }
                    elseif ($outputStr -match [regex]'(?m)SSIM.*y:\s*(?<y>\d+\.\d+).*u:\s*(?<u>\d+\.\d+).*v:\s*(?<v>\d+\.\d+)') {
                        # Fallback to component values
                        $result.SSIM = @{
                            Y = [double]$Matches['y']
                            U = [double]$Matches['u']
                            V = [double]$Matches['v']
                            AVG = ([double]$Matches['y'] + [double]$Matches['u'] + [double]$Matches['v']) / 3
                        }
                        Write-Host "  SSIM: $($result.SSIM.AVG.ToString('F4'))" -ForegroundColor Green
                    }
                    else {
                        Write-Host "  SSIM: FAILED" -ForegroundColor Red
                    }
                }
            }
            else {
                Write-Host "  No metrics to calculate" -ForegroundColor Yellow
            }
            
            Write-Host ""
            return $result
        } -ThrottleLimit ([Math]::Min($DistortedPaths.Count, $Threads))
    }
    else {
        # Sequential processing
        $jobResults = @()
        $counter = 0
        
        foreach ($path in $DistortedPaths) {
            $counter++
            Write-Progress -Activity "Calculating metrics" `
                -Status "[$counter/$($DistortedPaths.Count)] $([IO.Path]::GetFileName($path))" `
                -PercentComplete (($counter / $DistortedPaths.Count) * 100) -Id 1
            
            Write-Host "[$counter/$($DistortedPaths.Count)] Processing: $([IO.Path]::GetFileName($path))" -ForegroundColor Yellow
            
            $result = [PSCustomObject]@{ 
                ReferencePath = $ReferencePath
                DistortedPath = $path
                VMAF          = $null
                VMAFNeg       = $null
                XPSNR         = $null
                PSNR          = $null
                SSIM          = $null
                Timer         = $null
                FFmpegArgs    = $null
            }
            
            $distType = $distInfo[$path].Type
            $distFPS = $distInfo[$path].FPS
            
            # Build input arguments
            $distArgs = @()
            $distArgs += '-r', ($distFPS.ToString().Replace(',', '.'))
            if ($distType -eq 'VapourSynth') {
                $distArgs += '-f', 'vapoursynth'
            }
            elseif ($distType -eq 'AviSynth') {
                $distArgs += '-f', 'avisynth'
            }
            $distArgs += '-i', $path
            
            $refArgs = @()
            $refArgs += '-r', ($refFPS.ToString().Replace(',', '.'))
            if ($refType -eq 'VapourSynth') {
                $refArgs += '-f', 'vapoursynth'
            }
            elseif ($refType -eq 'AviSynth') {
                $refArgs += '-f', 'avisynth'
            }
            $refArgs += '-i', $ReferencePath
            
            # Use pre-built filter graph
            if ($filterGraph) {
                $ffargs = @(
                    "-threads", $Threads,
                    "-hide_banner", "-y", "-nostats"
                ) + $distArgs + $refArgs + @(
                    "-filter_complex", $filterGraph,
                    "-f", "null", "-"
                )
                
                $result.FFmpegArgs = $ffargs
                $timer = [System.Diagnostics.Stopwatch]::StartNew()
                $output = & $ffmpeg $ffargs 2>&1
                $timer.Stop()
                $result.Timer = $timer
                
                $outputStr = $output -join "`n"
                
                # Parse VMAF
                if ($Metrics -contains 'VMAF') {
                    $vmafMatches = [regex]::Matches($outputStr, 'VMAF score:\s*(\d+\.\d+)')
                    if ($vmafMatches.Count -ge 1) {
                        $result.VMAF = [double]$vmafMatches[0].Groups[1].Value
                        Write-Host "  VMAF: $($result.VMAF)" -ForegroundColor Green
                    }
                    else {
                        Write-Host "  VMAF: FAILED" -ForegroundColor Red
                    }
                    
                    if ($vmafMatches.Count -ge 2) {
                        $result.VMAFNeg = [double]$vmafMatches[1].Groups[1].Value
                        Write-Host "  VMAF (harm): $($result.VMAFNeg)" -ForegroundColor Cyan
                    }
                }
                
                # Parse XPSNR
                if ($Metrics -contains 'XPSNR') {
                    if ($outputStr -match [regex]'(?m)XPSNR.*y:\s*(?<y>\d+\.\d+).*u:\s*(?<u>\d+\.\d+).*v:\s*(?<v>\d+\.\d+)') {
                        $result.XPSNR = @{
                            Y    = [double]$Matches['y']
                            U    = [double]$Matches['u']
                            V    = [double]$Matches['v']
                            MIN  = (([double]$Matches['y'], [double]$Matches['u'], [double]$Matches['v']) | Measure-Object -Minimum).Minimum
                            AVG  = ([double]$Matches['y'] + [double]$Matches['u'] + [double]$Matches['v']) / 3
                            WSUM = (4 * [double]$Matches['y'] + [double]$Matches['u'] + [double]$Matches['v']) / 6
                        }
                        Write-Host "  XPSNR: $($result.XPSNR.WSUM.ToString('F2'))" -ForegroundColor Green
                    }
                    else {
                        Write-Host "  XPSNR: FAILED" -ForegroundColor Red
                    }
                }
                
                # Parse PSNR
                if ($Metrics -contains 'PSNR') {
                    if ($outputStr -match [regex]'(?m)PSNR.*y:\s*(?<y>\d+\.\d+).*u:\s*(?<u>\d+\.\d+).*v:\s*(?<v>\d+\.\d+)') {
                        $result.PSNR = @{
                            Y    = [double]$Matches['y']
                            U    = [double]$Matches['u']
                            V    = [double]$Matches['v']
                            MIN  = (([double]$Matches['y'], [double]$Matches['u'], [double]$Matches['v']) | Measure-Object -Minimum).Minimum
                            AVG  = ([double]$Matches['y'] + [double]$Matches['u'] + [double]$Matches['v']) / 3
                            WSUM = (4 * [double]$Matches['y'] + [double]$Matches['u'] + [double]$Matches['v']) / 6
                        }
                        Write-Host "  PSNR: $($result.PSNR.WSUM.ToString('F2'))" -ForegroundColor Green
                    }
                    else {
                        Write-Host "  PSNR: FAILED" -ForegroundColor Red
                    }
                }
                
                # Parse SSIM
                if ($Metrics -contains 'SSIM') {
                    if ($outputStr -match [regex]'(?m)SSIM.*All:\s*(?<all>\d+\.\d+)') {
                        $result.SSIM = [double]$Matches['all']
                        Write-Host "  SSIM: $($result.SSIM.ToString('F4'))" -ForegroundColor Green
                    }
                    elseif ($outputStr -match [regex]'(?m)SSIM.*y:\s*(?<y>\d+\.\d+).*u:\s*(?<u>\d+\.\d+).*v:\s*(?<v>\d+\.\d+)') {
                        $result.SSIM = @{
                            Y = [double]$Matches['y']
                            U = [double]$Matches['u']
                            V = [double]$Matches['v']
                            AVG = ([double]$Matches['y'] + [double]$Matches['u'] + [double]$Matches['v']) / 3
                        }
                        Write-Host "  SSIM: $($result.SSIM.AVG.ToString('F4'))" -ForegroundColor Green
                    }
                    else {
                        Write-Host "  SSIM: FAILED" -ForegroundColor Red
                    }
                }
            }
            else {
                Write-Host "  No metrics to calculate" -ForegroundColor Yellow
            }
            
            Write-Host ""
            $jobResults += $result
        }
        Write-Progress -Completed -Id 1
    }
    
    # Convert results to array
    $results = @($jobResults)
    
    # Show results summary
    Write-Host "`n========================================" -ForegroundColor Cyan
    Write-Host "  RESULTS SUMMARY" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    
    if ($results.Count -eq 0) {
        Write-Host "  No results were calculated" -ForegroundColor Yellow
    }
    
    # Sort by VMAF if available
    $sorted = $results | Sort-Object { 
        if ($_.VMAF) { $_.VMAF } 
        elseif ($_.PSNR -and $_.PSNR.WSUM) { $_.PSNR.WSUM } 
        elseif ($_.XPSNR -and $_.XPSNR.WSUM) { $_.XPSNR.WSUM } 
        elseif ($_.SSIM) { $_.SSIM } 
        else { 0 } 
    } -Descending
    
    foreach ($r in $sorted) {
        $name = [IO.Path]::GetFileName($r.DistortedPath)
        $vmaf = if ($r.VMAF) { "{0:N2}" -f $r.VMAF } else { "N/A" }
        $vmafNeg = if ($r.VMAFNeg) { "{0:N2}" -f $r.VMAFNeg } else { "N/A" }
        
        $xpsnr = if ($r.XPSNR) { "{0:N2}" -f $r.XPSNR.WSUM } else { "N/A" }
        $psnr = if ($r.PSNR) { "{0:N2}" -f $r.PSNR.WSUM } else { "N/A" }
        
        $ssim = if ($r.SSIM -is [double]) { "{0:F4}" -f $r.SSIM } 
                elseif ($r.SSIM -and $r.SSIM.AVG) { "{0:F4}" -f $r.SSIM.AVG } 
                else { "N/A" }
        
        $time = if ($r.Timer) { "{0:F1}s" -f $r.Timer.Elapsed.TotalSeconds } else { "N/A" }
        
        $color = if ($r.VMAF -and $r.VMAF -gt 90) { 'Green' } 
        elseif ($r.VMAF -and $r.VMAF -gt 80) { 'Yellow' } 
        else { 'Gray' }
        
        Write-Host "  $name" -ForegroundColor Gray
        if ($Metrics -contains 'VMAF') {
            Write-Host "    VMAF         : $vmaf" -ForegroundColor $color
            Write-Host "    VMAF (harm)   : $vmafNeg" -ForegroundColor Cyan
        }
        if ($Metrics -contains 'XPSNR') {
            Write-Host "    XPSNR        : $xpsnr" -ForegroundColor Gray
        }
        if ($Metrics -contains 'PSNR') {
            Write-Host "    PSNR         : $psnr" -ForegroundColor Gray
        }
        if ($Metrics -contains 'SSIM') {
            Write-Host "    SSIM         : $ssim" -ForegroundColor Gray
        }
        Write-Host "    Time         : $time" -ForegroundColor DarkGray
        Write-Host ""
    }
    Write-Host "========================================" -ForegroundColor Cyan
    
    return $results
}

Export-ModuleMember -Function Get-VideoQualityMetrics3

<#
[PSCustomObject]$CropPrm = @{
    Left          = 0
    Right         = 0
    Top           = 0
    Bottom        = 0
    CropDistVideo = $false
}
$ref = 'r:\Temp\e16.mkv'
$dist = @(
'r:\Temp\UM_s06e16_[hevc_crf24].mkv'
# 'v:\Сериалы\Отечественные\Условный мент\сезон 06\Uslovnyj.ment.s06.2025.IPTV.1080p.by.ivandubskoj\.enc\Условный мент - s06e16 - Красная линия [2024-12-28][1080p][hevc_crf25].mkv'
# 'g:\.temp\av1an\e16_[av1an_x265-crf95].mkv'
)
$res = Get-VideoQualityMetrics3 -DistortedPaths $dist -ReferencePath $ref -Crop $CropPrm -Parallel -SubSample 5 -Metrics All -Threads 6 # -Metrics Both -TrimStartSeconds 0 -DurationSeconds 10
#$res | Format-List
#>