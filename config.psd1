<#
.SYNOPSIS
    Универсальный конвейер для конвертации видео в AV1/HEVC с сохранением всех метаданных.
#>

# Параметры конвейера
@{
    # Пути к инструментам
    Tools = @{
        FFmpeg         = "ffmpeg.exe"
        FFprobe        = "ffprobe.exe"
        MkvMerge       = "mkvmerge.exe"
        MkvExtract     = "mkvextract.exe"
        MkvPropedit    = "mkvpropedit.exe"
        VSPipe         = "C:\Program Files\VapourSynth\core\vspipe.exe"
        x265           = 'X:\Apps\_VideoEncoding\StaxRip\Apps\Encoders\x265\x265.exe'
        SvtAv1EncESS   = 'X:\Apps\_VideoEncoding\StaxRip\Apps\Encoders\SvtAv1EncApp-Essential\SvtAv1EncApp.exe'
        OpusEnc        = 'd:\Sources\media-autobuild_suite\local64\bin-audio\opusenc.exe'
        QAAC           = 'X:\Apps\_VideoEncoding\StaxRip\Apps\Audio\qaac\qaac64.exe'
        AutoCrop       = '.\Tools\AutoCrop.exe'
    }
    
    # Пути к шаблонам VapourSynth
    Templates = @{
        VapourSynth = @{
            AutoCrop       = ".\Templates\AutoCropTemplate.py"
            MainScript     = ".\Templates\VapourSynth\universal_v2.vpy"
            MainHDScript   = ".\Templates\VapourSynth\MainHDScript+.vpy"
            HDRtoSDRScript = ".\Templates\VapourSynth\universal_v2.vpy"
        }
    }
    
    # Пути по умолчанию
    Paths = @{
        DefaultInputDirectory = "G:\Видео\"
        TempDirectory = "R:\.temp\"
    }
    
    # Параметры обработки
    Processing = @{
        DeleteTempFiles    = $true
        AutoCropThreshold  = 1000
        VSPipeMethod       = "vspipe"  # vspipe или ffmpeg
        CalculateVMAF      = $false
    }
    
    # Коды энкодеров для имен файлов
    EncoderCodes = @{
        x265           = 'hevc'
        SvtAv1EncESS   = 'av1'
        Rav1eEnc       = 'av1'
        AomAv1Enc      = 'av1'
    }
    
    # Доступные энкодеры
    AvailableEncoders = @{
        x265         = 'Tools.x265'
        SvtAv1EncESS = 'Tools.SvtAv1EncESS'
        Rav1eEnc     = 'Tools.Rav1eEnc'
        AomAv1Enc    = 'Tools.AomAv1Enc'
    }
    
    # Энкодер по умолчанию
    DefaultEncoder = 'SvtAv1EncESS.grain_optimized'
    
    # Настройки аудио
    Encoding = @{
        Audio = @{
            CopyAudio = $false
            Codec = 'opus'
            Bitrates = @{
                Stereo   = "144k"
                Surround = "300k"
                Multi    = "360k"
            }
            AAC = @{
                Quality = 110
                ProfileHE = $false
            }
        }
        
        Video = @{
            CopyVideo = $false
            CropRound = 2
            XtraParams = @()
            
            # Пресеты энкодеров
            EncoderPresets = @{
                x265 = @{
                    main = @{
                        DisplayName = "x265 Main"
                        CodecCode   = 'hevc'
                        Quality     = 27
                        Preset      = 'slow'
                        BaseArgs    = @('--output-depth', '10')
                    }
                    grain = @{
                        DisplayName = "x265 Film Grain"
                        CodecCode   = 'hevc'
                        Quality     = 23
                        Preset      = 'slower'
                        BaseArgs    = @('--output-depth', '10', '--tune', 'grain')
                    }
                }
                
                SvtAv1EncESS = @{
                    grain_optimized = @{
                        DisplayName = "SVT-AV1 Film Grain"
                        CodecCode   = 'av1'
                        Quality     = 'medium'
                        Speed       = 'slow'
                        BaseArgs    = @(
                            '--rc', '0',
                            '--progress', '3',
                            '--auto-tiling', '0',
                            '--aq-mode', '2',
                            '--film-grain-denoise', '0',
                            '--film-grain', '12'
                        )
                    }
                    main = @{
                        DisplayName = "SVT-AV1 Main"
                        CodecCode   = 'av1'
                        Quality     = 'medium'
                        Speed       = 'slow'
                        BaseArgs    = @('--rc', '0', '--progress', '3')
                    }
                }
            }
        }
    }
}