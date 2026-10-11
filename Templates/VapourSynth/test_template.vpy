"""HDR Video Processing Template (Optimized) — ТЕСТОВАЯ КОПИЯ"""
import os
import vapoursynth as vs
from vapoursynth import core
from smdegrain_bis import SMDegrain
import vs_temporalfix

VideoPath = r"g:\Видео\Сериалы\Зарубежные\Паук-Нуар (Spider-Noir)\Spider-Noir.S01.2160p.AMZN.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265-FLUX\Spider-Noir.S01E01.Step.Into.My.Office.2160p.AMZN.WEB-DL.DDP5.1.Atmos.DV.HDR.H.265-FLUX.mkv"
CacheFile = VideoPath + ".lwi"

CropLeft  = 0
CropRight = 0
CropTop   = 0
CropBottom= 0

ENABLE_DENOISE   = True
ENABLE_BM3D      = False
ENABLE_SMDegrain = True
ENABLE_Temporalfix = True
ENABLE_SHADERS   = False
DEBUG_MODE       = False

PRIORITY = "DOVI"

SHADER_LIST = []

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

DGHDR = {
    'white': 1900,
    'tm': 0.9,
    'roll': 0.7,
    'gamma': 0.42,
    'r': 1.0,
    'g': 1.0,
    'b': 1.05,
}

PLACEBO = {
    'gamut_mapping': 1,
    'tone_mapping_function': 3,
    'src_min': 0.0050,
    'src_max': 1000.0,
    'dst_min': 0.001,
    'dst_max': 100.0,
    'dynamic_peak_detection': True,
    'percentile': 99.995,
    'contrast_recovery': 0.2,
    'log_level': 0,
}

def log(msg, level="INFO"):
    if DEBUG_MODE:
        print(f"[{level}] {msg}")

def to16(clip):
    return clip if clip.format.id == vs.YUV420P16 else core.resize.Spline36(clip, format=vs.YUV420P16)

def denoise(clip):
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

    if ENABLE_SMDegrain:
        log("SMDegrain denoise", "INFO")
        clip = SMDegrain(clip, tr=3, thSAD=DENOISE['smdegrain_thsad'])

    if ENABLE_Temporalfix:
        log("Temporalfix denoise", "INFO")
        clip = core.resize.Bicubic(clip, format=vs.RGBH, matrix_in_s="709")
        clip = vs_temporalfix.model(clip, strength=DENOISE['temporalfix_strength'], backend="tensorrt")
        clip = core.resize.Bicubic(clip, format=vs.YUV420P16, matrix_s="709")

    return clip

def tonemap(clip, video_type):
    if video_type == "HDR10":
        log(f"DGHDRtoSDR (white={DGHDR['white']})", "INFO")
        return core.dghdrtosdr.DGHDRtoSDR(
            clip=clip, mode="pq", fulldepth=True,
            white=DGHDR['white'], gamma=DGHDR['gamma'],
            r=DGHDR['r'], g=DGHDR['g'], b=DGHDR['b'],
            tm=DGHDR['tm'], roll=DGHDR['roll'],
        )

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

def apply_shaders(clip):
    for shader in SHADER_LIST:
        log(f"  {os.path.basename(shader)}", "DEBUG")
        clip = core.placebo.Shader(clip, shader=shader)
    return clip

# ===== ОСНОВНОЙ СКРИПТ =====

try:
    clip = core.lsmas.LWLibavSource(VideoPath, cachefile=CacheFile)
except Exception as e:
    clip = core.bs.VideoSource(VideoPath)

# 3. Определение типа видео
try:
    frame = clip.get_frame(0)
    props = frame.props
    has_dovi = ('DolbyVisionRPU' in props or
                props.get('DOVI_rpu_present', False) or
                'dolby vision' in str(props.get('_HDRFormat', '')).lower())
    has_hdr10 = props.get('_Transfer', 0) == 16

    if has_dovi and has_hdr10:
        video_type = "DOVI" if PRIORITY == "DOVI" else "HDR10"
    elif has_dovi:
        video_type = "DOVI"
    elif has_hdr10:
        video_type = "HDR10"
    elif props.get('_Transfer', 0) == 18:
        video_type = "HLG"
    else:
        video_type = "SDR"

except Exception as e:
    video_type = "SDR"

# 4. YUV420P16
clip = to16(clip)

# 5. Тонмаппинг
if video_type != "SDR":
    clip = to16(tonemap(clip, video_type))

# 6. Дениаз
if ENABLE_DENOISE:
    clip = denoise(clip)

# 7. Crop
if CropLeft or CropRight or CropTop or CropBottom:
    clip = core.std.CropRel(clip, CropLeft, CropRight, CropTop, CropBottom)

# 8. Шейдеры
if ENABLE_SHADERS:
    clip = apply_shaders(clip)

# 9. Финал: 10-bit YUV
clip = core.resize.Spline36(clip, format=vs.YUV420P10, dither_type="error_diffusion")
clip = core.std.SetFrameProps(clip,
    _Matrix=1,
    _Transfer=1,
    _Primaries=1,
)

clip.set_output()
