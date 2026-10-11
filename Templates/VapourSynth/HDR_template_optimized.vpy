"""
HDR Video Processing Template (Optimized)
==========================================

Поддерживаемые форматы:
- Dolby Vision (RPU)
- HDR10 (PQ)
- HLG
- SDR

Линейный пайплайн:
1. Загрузка → 2. Опред. типа → 3. Тонмаппинг → 4. Дениаз → 5. Кrop → 6. Шейдеры → 7. 10-bit
"""
import os
import vapoursynth as vs
from vapoursynth import core
from smdegrain_bis import SMDegrain
import vs_temporalfix

# ===== ПАРАМЕТРЫ =====
VideoPath = r"{VideoPath}"
CacheFile = r"{CacheFile}"
CropLeft  = {CropLeft}
CropRight = {CropRight}
CropTop   = {CropTop}
CropBottom= {CropBottom}

# VideoPath = r"g:\Видео\Сериалы\Зарубежные\Паук-Нуар (Spider-Noir)\Spider-Noir.S01.2160p.AMZN.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265-FLUX\Spider-Noir.S01E01.Step.Into.My.Office.2160p.AMZN.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265-FLUX.mkv"
# CacheFile = VideoPath + ".lwi"
# CropLeft  = 0
# CropRight = 0
# CropTop   = 0
# CropBottom= 0

# ===== НАСТРОЙКИ =====
ENABLE_DENOISE   = True
ENABLE_BM3D      = False
ENABLE_SMDegrain = True
ENABLE_Temporalfix = True
ENABLE_SHADERS   = True
DEBUG_MODE       = True

# Приоритет для гибридных файлов (DOVI + HDR10)
# "DOVI" — placebo.Tonemap с use_dovi=1
# "HDR10" — DGHDRtoSDR
PRIORITY = "DOVI"

# Шейдеры (порядок важен!)
SHADER_LIST = [
    #r"X:\Apps\_VideoEncoding\ffmpeg\LiftGammaGain_lite.glsl",
    r"X:\Apps\_VideoEncoding\ffmpeg\shaders\adaptive-sharpen-modern-4K.glsl"
]

# ===== НАСТРОЙКИ ДЕНИАЗА =====
DENOISE = {
    'sigma_basic': [3.0, 1.0, 1.0],
    'sigma_final': [2.0, 0.1, 0.1],
    'block_step': 4,
    'bm_range': 9,
    'radius': 1,
    'fast': True,
    'smdegrain_thsad': 400,
    'temporalfix_strength': 1.5,
}

# DGHDRtoSDR (HDR10)
DGHDR = {
    'white': 1900,
    'tm': 0.9,
    'roll': 0.7,
    'gamma': 0.42,
    'r': 1.0,
    'g': 1.0,
    'b': 1.05,
}

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

# Placebo Tonemap (DOVI / HLG)
PLACEBO = {
    'gamut_mapping': 1,    # PERCEPTUAL
    'tone_mapping_function': TONE_MAP_ST2094_10,
    'src_min': 0.0050,
    'src_max': 1000.0,
    'dst_min': 0.001,
    'dst_max': 100.0,
    'dynamic_peak_detection': True,
    'percentile': 99.995,
    'contrast_recovery': 0.2,
    'log_level': 1 if DEBUG_MODE else 0,
}


# ===== УТИЛИТЫ =====
def log(msg, level="INFO"):
    if DEBUG_MODE:
        print(f"[{level}] {msg}")


def to16(clip):
    """Гарантировать рабочий формат пайплайна YUV420P16 без лишних конвертаций."""
    return clip if clip.format.id == vs.YUV420P16 else core.resize.Spline36(clip, format=vs.YUV420P16)


# ===== ДЕНИАЗ =====
# Всё обрабатывается в YUV420P16; Temporalfix требует RGBH на входе.
def denoise(clip):
    """BM3D → SMDegrain → Temporalfix."""
    # BM3D (2-pass, YUV420P16)
    if ENABLE_BM3D:
        log("BM3D denoise", "INFO")
        ref = core.bm3dcuda.BM3Dv2(
            clip, sigma=DENOISE['sigma_basic'],
            radius=DENOISE['radius'], block_step=DENOISE['block_step'],
            bm_range=DENOISE['bm_range'], fast=DENOISE['fast'],
        )
        clip = core.bm3dcuda.BM3Dv2(
            clip, ref=ref, sigma=DENOISE['sigma_final'],
            radius=DENOISE['radius'], block_step=DENOISE['block_step'],
            bm_range=DENOISE['bm_range'], fast=DENOISE['fast'],
        )

    # SMDegrain (YUV420P16)
    if ENABLE_SMDegrain:
        log("SMDegrain denoise", "INFO")
        clip = SMDegrain(clip, tr=3, thSAD=DENOISE['smdegrain_thsad'])

    # Temporalfix (RGBH)
    if ENABLE_Temporalfix:
        log("Temporalfix denoise", "INFO")
        clip = core.resize.Bicubic(clip, format=vs.RGBH, matrix_in_s="709")
        clip = vs_temporalfix.model(clip, strength=DENOISE['temporalfix_strength'], backend="tensorrt")
        clip = core.resize.Bicubic(clip, format=vs.YUV420P16, matrix_s="709")

    return clip


# ===== ТОНМАППИНГ =====
# src_csp: 1 = HDR10 (PQ), 2 = HLG, 3 = DOVI;  dst_csp: 0 = SDR;  dst_prim: 3 = BT.709
def tonemap(clip, video_type):
    """HDR/DOVI/HLG → SDR (YUV420P16)."""
    if video_type == "HDR10":
        log(f"DGHDRtoSDR (white={DGHDR['white']})", "INFO")
        return core.dghdrtosdr.DGHDRtoSDR(
            clip=clip, mode="pq", fulldepth=True,
            white=DGHDR['white'], gamma=DGHDR['gamma'],
            r=DGHDR['r'], g=DGHDR['g'], b=DGHDR['b'],
            tm=DGHDR['tm'], roll=DGHDR['roll'],
        )

    # DOVI или HLG
    src_csp = 3 if video_type == "DOVI" else 2
    use_dovi = 1 if video_type == "DOVI" else 0
    log(f"Placebo Tonemap src_csp={src_csp} use_dovi={use_dovi}", "INFO")
    return core.placebo.Tonemap(
        clip,
        src_csp=src_csp,
        dst_csp=0,
        dst_prim=3,
        metadata=0,
        use_dovi=use_dovi,
        gamut_mapping=PLACEBO['gamut_mapping'],
        tone_mapping_function=PLACEBO['tone_mapping_function'],
        src_min=PLACEBO['src_min'],
        src_max=PLACEBO['src_max'],
        dst_min=PLACEBO['dst_min'],
        dst_max=PLACEBO['dst_max'],
        dynamic_peak_detection=PLACEBO['dynamic_peak_detection'],
        percentile=PLACEBO['percentile'],
        contrast_recovery=PLACEBO['contrast_recovery'],
        log_level=PLACEBO['log_level'],
    )


# ===== ШЕЙДЕРЫ =====
def apply_shaders(clip):
    """Последовательное применение шейдеров (YUV420P16)."""
    for shader in SHADER_LIST:
        log(f"  {os.path.basename(shader)}", "DEBUG")
        clip = core.placebo.Shader(clip, shader=shader)
    return clip


# ===== ОСНОВНОЙ СКРИПТ =====
if DEBUG_MODE:
    print("=" * 60)
    print(f"Video: {VideoPath}")
    print(f"Denoise: {'ON' if ENABLE_DENOISE else 'OFF'} "
          f"[BM3D={ENABLE_BM3D} SMDegrain={ENABLE_SMDegrain} Temporalfix={ENABLE_Temporalfix}]")
    print(f"Shaders: {'ON' if ENABLE_SHADERS else 'OFF'} ({len(SHADER_LIST)})")
    print(f"Hybrid priority: {PRIORITY}")
    print("=" * 60)

# 1. Загрузка
try:
    clip = core.lsmas.LWLibavSource(VideoPath, cachefile=CacheFile, prefer_hw=4, threads=1)
except Exception as e:
    log(f"LWLibavSource: {e} → BestSource", "WARNING")
    clip = core.bs.VideoSource(VideoPath)

# 2. Trim
#{trimScript}

# 3. Определение типа видео
try:
    frame = clip.get_frame(0)
    props = frame.props
    has_dovi = ('DolbyVisionRPU' in props or
                props.get('DOVI_rpu_present', False) or
                'dolby vision' in str(props.get('_HDRFormat', '')).lower())
    has_hdr10 = props.get('_Transfer', 0) == 16  # PQ

    if has_dovi and has_hdr10:
        video_type = "DOVI" if PRIORITY == "DOVI" else "HDR10"
        log(f"Hybrid → {video_type}", "INFO")
    elif has_dovi:
        video_type = "DOVI"
    elif has_hdr10:
        video_type = "HDR10"
    elif props.get('_Transfer', 0) == 18:  # HLG
        video_type = "HLG"
    else:
        video_type = "SDR"

    log(f"Detected: {video_type}", "INFO")
except Exception as e:
    log(f"Detection error: {e} → SDR", "WARNING")
    video_type = "SDR"

# 4. Единый рабочий формат пайплайна: YUV420P16 (16-bit нужен тонмапперу и фильтрам)
clip = to16(clip)

# 5. Тонмаппинг HDR → SDR
if video_type != "SDR":
    clip = to16(tonemap(clip, video_type))
else:
    log("SDR content — no tonemap", "INFO")

# 6. Crop
if CropLeft or CropRight or CropTop or CropBottom:
    clip = core.std.CropRel(clip, CropLeft, CropRight, CropTop, CropBottom)

# 7. Дениаз
if ENABLE_DENOISE:
    clip = denoise(clip)

# 8. Шейдеры (YUV420P16)
if ENABLE_SHADERS:
    clip = apply_shaders(clip)

# 9. Финал: 10-bit YUV
clip = core.resize.Spline36(clip, format=vs.YUV420P10, dither_type="error_diffusion")
clip = core.std.SetFrameProps(clip,
    _Matrix=1,   # BT.709
    _Transfer=1, # BT.709
    _Primaries=1,# BT.709
)

if DEBUG_MODE:
    print(f"\n{clip.width}x{clip.height} {clip.format.name} | Done")
    print("=" * 60)

clip.set_output()
