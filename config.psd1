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
        SvtAv1Enc      = 'X:\Apps\_VideoEncoding\StaxRip\Apps\Encoders\SvtAv1EncApp\SvtAv1EncApp.exe'
        SvtAv1EncESS   = 'X:\Apps\_VideoEncoding\StaxRip\Apps\Encoders\SvtAv1EncApp-Essential\SvtAv1EncApp.exe'
        SvtAv1EncHDR   = 'X:\Apps\_VideoEncoding\StaxRip\Apps\Encoders\SvtAv1EncApp-HDR\SvtAv1EncApp.exe'
        SvtAv1EncPSYEX = 'X:\Apps\_VideoEncoding\StaxRip\Apps\Encoders\SvtAv1EncApp-PSYEX\SvtAv1EncApp.exe'
        SvtAv1EncTritium = 'X:\Apps\_VideoEncoding\StaxRip\Apps\Encoders\SvtAv1EncApp-Tritium\SvtAv1EncApp.exe'
        Rav1eEnc       = 'X:\Apps\_VideoEncoding\StaxRip\Apps\Encoders\rav1e\rav1e.exe'
        AomAv1Enc      = 'X:\Apps\_VideoEncoding\StaxRip\Apps\Encoders\AOMEnc\aomenc.exe'
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
        SvtAv1Enc      = 'av1'
        SvtAv1EncESS   = 'av1'
        Rav1eEnc       = 'av1'
        AomAv1Enc      = 'av1'
    }
    
    # Доступные энкодеры
    AvailableEncoders = @{
        x265         = 'Tools.x265'
        SvtAv1Enc    = 'Tools.SvtAv1Enc'
        SvtAv1EncESS = 'Tools.SvtAv1EncESS'
        Rav1eEnc     = 'Tools.Rav1eEnc'
        AomAv1Enc    = 'Tools.AomAv1Enc'
    }
    
    # Энкодер по умолчанию
    DefaultEncoder = 'SvtAv1Enc.grain'
    
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
                Quality = 110 # 91, 100, 109
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
                        BaseArgs    = @(
                            '--output-depth', '10',
                            '--no-strong-intra-smoothing',
                            '--range', 'limited',
                            '--colorprim', 'bt709',
                            '--transfer', 'bt709',
                            '--colormatrix', 'bt709'
                        )
                    }
                    grain = @{
                        DisplayName = "x265 Film Grain"
                        CodecCode   = 'hevc'
                        Quality     = 23
                        Preset      = 'slower'
                        BaseArgs    = @(
                            '--tune', 'grain',
                            '--output-depth', '10',
                            '--no-strong-intra-smoothing',
                            '--range', 'limited',
                            '--colorprim', 'bt709',
                            '--transfer', 'bt709',
                            '--colormatrix', 'bt709'
                        )
                    }
                }
                SvtAv1Enc = @{
                    main = @{
                        DisplayName = "SVT-AV1 Main Preset"
                        CodecCode   = 'av1'
                        Quality     = 36
                        Preset      = 3
                        BaseArgs    = @(
                            '--rc', '0',
                            '--progress', '2',
                            '--color-range', '0'
                            '--color-primaries', '1',
                            '--transfer-characteristics', '1',
                            '--matrix-coefficients', '1'
                        )
                    }
                    grain = @{
                        DisplayName = "SVT-AV1 Grain"
                        CodecCode   = 'av1'
                        Quality     = 32
                        Preset      = 3
                        BaseArgs    = @(
                            '--lp', 4,
                            '--rc', '0',
                            '--progress', 2
                            "--scm", 0,
                            "--film-grain-denoise", 0,
                            "--film-grain", 10,
                            '--color-range', '0'
                            '--color-primaries', '1',
                            '--transfer-characteristics', '1',
                            '--matrix-coefficients', '1'
                            )
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
                            '--film-grain', '12',
                            '--color-range', '0',
                            '--color-primaries', '1',
                            '--transfer-characteristics', '1',
                            '--matrix-coefficients', '1'
                        )
                    }
                    main = @{
                        DisplayName = "SVT-AV1 Main"
                        CodecCode   = 'av1'
                        Quality     = 'medium'
                        Speed       = 'slow'
                        BaseArgs    = @(
                            '--rc', '0',
                            '--progress', '3',
                            '--color-range', '0'
                            '--color-primaries', '1',
                            '--transfer-characteristics', '1',
                            '--matrix-coefficients', '1'
                            )
                    }
                }
                # ============================================
                # ДРУГИЕ AV1 ЭНКОДЕРЫ
                # ============================================
                Rav1eEnc = @{
                    main = @{
                        DisplayName = "Rav1e Main Preset"
                        CodecCode   = 'av1'
                        Quality     = 80
                        Speed       = 4
                        BaseArgs    = @()
                    }
                    
                    fast = @{
                        DisplayName = "Rav1e Fast Preset"
                        CodecCode   = 'av1'
                        Quality     = 90
                        Speed       = 8
                        BaseArgs    = @()
                    }
                }
                
                AomAv1Enc = @{
                    main = @{
                        DisplayName = "AOM AV1 Main"
                        CodecCode   = 'av1'
                        Quality     = 30
                        CpuUsed     = 6
                        BaseArgs    = @('--end-usage=q')
                    }
                    
                    fast = @{
                        DisplayName = "AOM AV1 Fast"
                        CodecCode   = 'av1'
                        Quality     = 35
                        CpuUsed     = 8
                        BaseArgs    = @('--end-usage=q')
                    }
                }
            }
        }
    }
}