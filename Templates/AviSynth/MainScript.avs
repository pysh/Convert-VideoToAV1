; MainScript.avs - Базовый шаблон для AviSynth
; Аналог VapourSynth/MainScript.vpy

# Загрузка источника (FFmpegSource2 рекомендуется)
# LoadPlugin("X:\Apps\_VideoEncoding\StaxRip\Apps\Plugins\avs\FFmpegSource2.dll")
FFVideoSource("{VideoPath}", cachefile="{CacheFile}")

{trimScript}

# Конвертация формата в 16-bit промежуточный
ConvertToYV12(interlaced=false)
ConvertBits(16, dither=true)

# Применение шейдеров через libplacebo (требуется плагин)
# LoadPlugin("X:\Apps\_VideoEncoding\StaxRip\Apps\Plugins\avs\libplacebo.dll")
# Shader(file="X:\Apps\_VideoEncoding\ffmpeg\LiftGammaGain_lite.glsl")
# Shader(file="X:\Apps\_VideoEncoding\ffmpeg\adaptive-sharpen_lite.glsl")

# Обрезка черных полей
Crop({CropLeft}, {CropTop}, -{CropRight}, -{CropBottom})

# Финальная конвертация в 10-bit
ConvertBits(10, dither=true)
