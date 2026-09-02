; HDRtoSDR.avs - Шаблон для конвертации HDR в SDR через AviSynth
; Аналог VapourSynth/universal_v2.vpy

# Загрузка источника
FFVideoSource("{VideoPath}", cachefile="{CacheFile}")

{trimScript}

# Обрезка (будет применена после тонмаппинга)
# Crop({CropLeft}, {CropTop}, -{CropRight}, -{CropBottom})

# Тонмаппинг HDR10/Dolby Vision в SDR
# Вариант 1: Через DGDeinterlaceFilter с DGHDRtoSDR
# LoadPlugin("X:\Apps\_VideoEncoding\StaxRip\Apps\Plugins\avs\DGHDRtoSDR.dll")
# DGHDRtoSDR(white=1900, tm=0.9, roll=0.7, gamma=0.42, r=1.0, g=1.0, b=1.05)

# Вариант 2: Через znedi3 и ручную конвертацию
ConvertToYV12(interlaced=false)
ColorYUV(off_y=-16, off_u=-128, off_v=-128, gain_y=219, gain_u=224, gain_v=224)

# Конвертация в 10-bit
ConvertToBits(10, dither=true)

# Обрезка черных полей
Crop({CropLeft}, {CropTop}, -{CropRight}, -{CropBottom})
