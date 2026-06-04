import os, sys
import vapoursynth as vs
from vapoursynth import core

sys.path.append(r"X:\Apps\_VideoEncoding\StaxRip\Apps\Plugins\VS\Scripts")
import importlib.machinery

havsfunc = importlib.machinery.SourceFileLoader('havsfunc', r"X:\Apps\_VideoEncoding\StaxRip\Apps\Plugins\VS\Scripts\havsfunc.py").load_module()

# Цветовые пространства (src_csp, dst_csp)
CSP_SDR   = 0
CSP_HDR10 = 1
CSP_HLG   = 2
CSP_DOVI  = 3

# Цветовые первичные (dst_prim)
PRIMARY_UNKNOWN   = 0
PRIMARY_BT601_525 = 1
PRIMARY_BT601_625 = 2
PRIMARY_BT709     = 3
PRIMARY_BT470M    = 4
PRIMARY_EBU       = 5
PRIMARY_BT2020    = 6
PRIMARY_APPLE     = 7
PRIMARY_ADOBE     = 8
PRIMARY_PROPHOTO  = 9
PRIMARY_CIE1931   = 10
PRIMARY_DCIP3     = 11
PRIMARY_DCIP3_D65 = 12
PRIMARY_VGAMUT    = 13
PRIMARY_SGAMUT    = 14
PRIMARY_FILM_C    = 15
PRIMARY_ACES_0    = 16
PRIMARY_ACES_1    = 17

# Функции тонмаппинга (tone_mapping_function)
TONE_CLIP            = 0
TONE_MAP_SPLINE      = 1 # default
TONE_MAP_ST2094_40   = 2
TONE_MAP_ST2094_10   = 3
TONE_MAP_BT2390      = 4
TONE_MAP_BT2446A     = 5
TONE_MAP_REINHARD    = 6
TONE_MAP_MOBIUS      = 7
TONE_MAP_HABLE       = 8
TONE_MAP_GAMMA       = 9
TONE_MAP_LINEAR      = 10
TONE_MAP_LINEARLIGHT = 11

# Режимы отображения гамута (gamut_mapping)
GAMUT_MAP_CLIP       = 0
GAMUT_MAP_PERCEPTUAL = 1 # default
GAMUT_MAP_SOFTCLIP   = 2
GAMUT_MAP_RELATIVE   = 3
GAMUT_MAP_SATURATION = 4
GAMUT_MAP_ABSOLUTE   = 5
GAMUT_MAP_DESATURE   = 6
GAMUT_MAP_DARKEN     = 7
GAMUT_MAP_HIGHLIGHT  = 8
GAMUT_MAP_LINEAR     = 9

# Метаданные (metadata)
METADATA_AUTO      = 0 #default
METADATA_NONE      = 1
METADATA_HDR10     = 2
METADATA_HDR10PLUS = 3
METADATA_LUMINANCE = 4

# Загрузка видео
clip = core.lsmas.LWLibavSource(source=r"{VideoPath}", cachefile=r"{CacheFile}")
{trimScript}

# Повышаем битность для точных вычислений
clip = core.fmtc.bitdepth(clip, bits=16)

clip = core.placebo.Tonemap(
   clip,
   src_csp=CSP_HDR10,
   dst_csp=CSP_SDR,
   dst_prim=PRIMARY_BT709,
   metadata=METADATA_AUTO,
   src_min=0.005,
   src_max=1000.0,
   dst_min=0.0,
   dst_max=60.0,
   dynamic_peak_detection=True,
   tone_mapping_function=TONE_MAP_SPLINE,
   tone_mapping_param=0.0,
   gamut_mapping=GAMUT_MAP_PERCEPTUAL,
   percentile=99.9,
   contrast_recovery=1
)

# Дебанинг и резкость
clip = core.neo_f3kdb.Deband(clip, preset="veryhigh")
clip = havsfunc.LSFmod(clip, defaults='slow', strength=50, Smode=5, Smethod=3, kernel=11,
                        secure=True, Szrp= 16, Spwr= 4, SdmpLo= 4, SdmpHi= 48, Lmode=4, overshoot=1, undershoot=1,
                        soft=-2, soothe=True, keep=20, edgemode=0, edgemaskHQ=True, ss_x= 1.50, ss_y=1.50)

# Конвертируем обратно в YUV для кодирования
clip = core.resize.Spline36(clip, format=vs.YUV420P10, matrix_s="709")

# Обрезка
clip = core.std.Crop(clip, {CropLeft}, {CropRight}, {CropTop}, {CropBottom})

# Экспорт
clip.set_output()