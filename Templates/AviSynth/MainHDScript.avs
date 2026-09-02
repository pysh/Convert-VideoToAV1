; MainHDScript.avs - Шаблон для HD контента в AviSynth
; Аналог VapourSynth/MainHDScript+.vpy

# Загрузка источника с LWLibavSource (требуется DGIndexNV/FFmpegSource2)
FFVideoSource("{VideoPath}", cachefile="{CacheFile}")

{trimScript}

# Обрезка
Crop({CropLeft}, {CropTop}, -{CropRight}, -{CropBottom})

# Конвертация в 16-bit промежуточный формат
ConvertToYV12(interlaced=false)
ConvertToBits(16, dither=true)

# Применение шейдеров через libplacebo (требуется плагин)
# LoadPlugin("X:\Apps\_VideoEncoding\StaxRip\Apps\Plugins\avs\libplacebo.dll")
# Shader(file="X:\Apps\_VideoEncoding\ffmpeg\LiftGammaGain_lite.glsl")
# Shader(file="X:\Apps\_VideoEncoding\ffmpeg\adaptive-sharpen_lite.glsl")

# Финальная конвертация в 10-bit
ConvertToBits(10, dither=true)
