import os
import sys
import vapoursynth as vs
from vapoursynth import core

# ===== ПАРАМЕТРЫ =====
VideoPath = r"{VideoPath}"
CacheFile = r"{CacheFile}"
# CropLeft  = {CropLeft}
# CropRight = {CropRight}
# CropTop   = {CropTop}
# CropBottom= {CropBottom}

# ===== Ручное переопределение параметров =====
# VideoPath = r"r:\Temp\The.Pitt.S02E01.2160p.HMAX.WEB-DL.HDR.H.265.mkv"
# _temp_cache = r"{CacheFile}"
# CacheFile = _temp_cache if _temp_cache and _temp_cache != "{}" else os.path.splitext(VideoPath)[0] + ".lwi"

CropLeft  = 0
CropRight = 0
CropTop   = 0
CropBottom= 0

# ===== НАСТРОЙКИ =====
ENABLE_DENOISE = False
ENABLE_SHADERS = True
DEBUG_MODE = True

# Приоритет обработки для гибридных файлов (DOVI + HDR10 совместимый)
# "DOVI" - использовать Dolby Vision обработку (placebo.Tonemap с use_dovi=1)
# "HDR10" - использовать HDR10 обработку (DGHDRtoSDR)
PRIORITY = "HDR10"  # или "HDR10"

# Список шейдеров (порядок применения важен!)
SHADER_LIST = [
    r"X:\Apps\_VideoEncoding\ffmpeg\LiftGammaGain_lite.glsl",
    r"X:\Apps\_VideoEncoding\ffmpeg\adaptive-sharpen_lite.glsl",
]

# Настройки дениаза
DENOISE_SIGMA_BASIC = [3.0, 2.0, 2.0]
DENOISE_SIGMA_FINAL = [2.0, 1.5, 1.5]
DENOISE_BLOCK_STEP = 4
DENOISE_BM_RANGE = 9
DENOISE_RADIUS = 1
DENOISE_FAST = True

# Настройки DGHDRtoSDR для HDR10
DG_WHITE = 1900     # Целевая яркость
DG_TM = 0.9         # Сила тонмаппинга
DG_ROLL = 0.7       # Смягчение пересветов
DG_GAMMA = 0.42     # Гамма Rec.709
DG_R = 1.0          # Насыщенность красного
DG_G = 1.0          # Насыщенность зелёного
DG_B = 1.05         # Насыщенность синего

# ===== КОНСТАНТЫ =====
CSP_SDR   = 0
CSP_HDR10 = 1
CSP_HLG   = 2
CSP_DOVI  = 3

TONE_MAP_ST2094_10   = 3
GAMUT_MAP_PERCEPTUAL = 1
METADATA_AUTO        = 0

# ===== ФУНКЦИИ =====
def log(message, level="INFO"):
    if DEBUG_MODE:
        print(f"[{level}] {message}")

def debug_clip_info(clip, label=""):
    if DEBUG_MODE:
        if label:
            print(f"{label}: ", end="")
        print(f"{clip.width}x{clip.height} {clip.format.name if clip.format else 'Unknown'}")
    return clip

def detect_video_type(clip):
    """
    Определяет тип видео с учётом приоритета PRIORITY для гибридных файлов.
    Возвращает кортеж (тип, источник_метаданных).
    """
    try:
        frame = clip.get_frame(0)
        props = frame.props
        
        # Флаги для определения доступных форматов
        has_dovi = False
        has_hdr10 = False
        
        # Проверка DOVI
        if 'DolbyVisionRPU' in props:
            has_dovi = True
            log("Detected: DolbyVisionRPU present", "DEBUG")
        
        if props.get('DOVI_rpu_present', False):
            has_dovi = True
            log("Detected: DOVI_rpu_present", "DEBUG")
        
        hdr_format = str(props.get('_HDRFormat', ''))
        if 'dolby vision' in hdr_format.lower():
            has_dovi = True
            log("Detected: Dolby Vision in _HDRFormat", "DEBUG")
        
        # Проверка HDR10 (PQ)
        transfer = props.get('_Transfer', 0)
        primaries = props.get('_Primaries', 0)
        
        if transfer == 16:  # PQ
            has_hdr10 = True
            log("Detected: HDR10 (PQ)", "DEBUG")
        
        # Проверка HLG
        if transfer == 18:  # HLG
            log("Detected: HLG", "DEBUG")
            return ("HLG", "frame_props")
        
        # --- Принятие решения для гибридных файлов ---
        if has_dovi and has_hdr10:
            log(f"Hybrid file detected (DOVI + HDR10 compatible)", "INFO")
            log(f"Processing priority: {PRIORITY}", "INFO")
            
            if PRIORITY == "DOVI":
                return ("DOVI", "hybrid_priority")
            else:
                return ("HDR10", "hybrid_priority")
        
        # Чистый DOVI
        if has_dovi:
            log("Detected: Pure DOVI", "DEBUG")
            return ("DOVI", "frame_props")
        
        # Чистый HDR10
        if has_hdr10:
            log("Detected: Pure HDR10", "DEBUG")
            return ("HDR10", "frame_props")
        
        # SDR
        log("Detected: SDR", "DEBUG")
        return ("SDR", "frame_props")
        
    except Exception as e:
        log(f"Detection error: {e}", "ERROR")
        return ("SDR", "error")

def apply_denoise(clip):
    if not ENABLE_DENOISE:
        return clip
    
    try:
        log(f"Applying BM3D denoise (radius={DENOISE_RADIUS})", "INFO")
        
        src_format = clip.format
        is_float = src_format.sample_type == vs.FLOAT
        
        if not is_float:
            clip = core.resize.Spline36(clip, format=vs.YUV420PS)
        
        ref = core.bm3dcuda.BM3Dv2(
            clip, sigma=DENOISE_SIGMA_BASIC, radius=DENOISE_RADIUS,
            block_step=DENOISE_BLOCK_STEP, bm_range=DENOISE_BM_RANGE, fast=DENOISE_FAST
        )
        
        clip = core.bm3dcuda.BM3Dv2(
            clip, ref=ref, sigma=DENOISE_SIGMA_FINAL, radius=DENOISE_RADIUS,
            block_step=DENOISE_BLOCK_STEP, bm_range=DENOISE_BM_RANGE, fast=DENOISE_FAST
        )
        
        if not is_float:
            clip = core.resize.Spline36(clip, format=src_format.id)
        
        log("BM3D applied successfully", "INFO")
        return clip
    except Exception as e:
        log(f"BM3D failed: {e}", "WARNING")
        return clip

def apply_tonemap_placebo(clip, video_type):
    src_csp = CSP_DOVI if video_type == "DOVI" else CSP_HLG
    use_dovi = 1 if video_type == "DOVI" else 0
    
    log(f"Tonemap: {video_type} -> SDR via placebo (use_dovi={use_dovi})", "INFO")
    
    try:
        return core.placebo.Tonemap(
            clip,
            src_csp=src_csp,
            dst_csp=CSP_SDR,
            dst_prim=3,
            metadata=METADATA_AUTO,
            use_dovi=use_dovi,
            gamut_mapping=GAMUT_MAP_PERCEPTUAL,
            tone_mapping_function=TONE_MAP_ST2094_10,
            src_min=0.0001,
            src_max=1000.0,
            dst_min=0.0,
            dst_max=100.0,
            dynamic_peak_detection=1,
            percentile=99.995,
            contrast_recovery=0.3,
            log_level=1 if DEBUG_MODE else 0
        )
    except Exception as e:
        log(f"placebo tonemap error: {e}", "WARNING")
        return clip

def apply_tonemap_dghdr(clip):
    log(f"Tonemap: HDR10 -> SDR via DGHDRtoSDR (white={DG_WHITE}, tm={DG_TM})", "INFO")
    
    try:
        if clip.format.id != vs.YUV420P16:
            clip = core.resize.Spline36(clip, format=vs.YUV420P16)
        
        return core.dghdrtosdr.DGHDRtoSDR(
            clip=clip,
            mode="pq",
            white=DG_WHITE,
            gamma=DG_GAMMA,
            r=DG_R,
            g=DG_G,
            b=DG_B,
            tm=DG_TM,
            roll=DG_ROLL,
            fulldepth=True
        )
    except Exception as e:
        log(f"DGHDRtoSDR error: {e}, falling back to placebo", "WARNING")
        return apply_tonemap_placebo(clip, "HDR10")

def apply_shaders(clip):
    """Применяет все шейдеры из списка SHADER_LIST в порядке очереди"""
    if not ENABLE_SHADERS:
        return clip
    
    try:
        log(f"Applying {len(SHADER_LIST)} shader(s)", "INFO")
        
        for i, shader_path in enumerate(SHADER_LIST, 1):
            log(f"  [{i}/{len(SHADER_LIST)}] {os.path.basename(shader_path)}", "DEBUG")
            clip = core.placebo.Shader(clip, shader=shader_path)
        
        log("All shaders applied successfully", "INFO")
        return clip
    except Exception as e:
        log(f"Shaders failed: {e}", "WARNING")
        return clip

def process_hdr_content(clip, video_type, source):
    """
    Обработка HDR/DV контента (выход в 16-bit)
    video_type: "DOVI", "HDR10", "HLG"
    source: источник определения ("frame_props", "hybrid_priority")
    """
    log(f"Processing {video_type} content (source: {source})", "INFO")
    
    # Конвертация в 16-bit
    clip = core.resize.Spline36(clip, format=vs.YUV420P16)
    clip = debug_clip_info(clip, "After 16-bit conversion")
    
    # Выбор метода тонмаппинга
    if video_type == "HDR10":
        clip = apply_tonemap_dghdr(clip)
    else:  # DOVI или HLG
        clip = apply_tonemap_placebo(clip, video_type)
    
    # Дениаз
    clip = apply_denoise(clip)
    
    return clip

def process_sdr_content(clip):
    log("Processing SDR content", "INFO")
    
    if ENABLE_SHADERS:
        clip = core.resize.Spline36(clip, format=vs.YUV420P16)
        clip = debug_clip_info(clip, "After 16-bit conversion")
    
    clip = apply_denoise(clip)
    
    return clip

# ===== ОСНОВНОЙ СКРИПТ =====
if DEBUG_MODE:
    print("=" * 60)
    print("Video: {}".format(VideoPath))
    print("Cache: {}".format(CacheFile))
    print(f"Denoise: {'ENABLED' if ENABLE_DENOISE else 'DISABLED'}")
    print(f"Shaders: {'ENABLED' if ENABLE_SHADERS else 'DISABLED'}")
    print(f"Priority for hybrid files: {PRIORITY}")
    if ENABLE_SHADERS:
        print(f"Shader count: {len(SHADER_LIST)}")
    print("=" * 60)

# 1. Загрузка
try:
    clip = core.lsmas.LWLibavSource(VideoPath, cachefile=CacheFile, decoder='vulkan', prefer_hw=True)
    clip = debug_clip_info(clip, "Loaded")
except Exception as e:
    log(f"LWLibavSource failed: {e}, trying BestSource", "WARNING")
    clip = core.bs.VideoSource(VideoPath)
    clip = debug_clip_info(clip, "Loaded (BestSource)")

# 2. Trim
#{trimScript}

# 3. Определение типа (с учётом приоритета)
video_type, detection_source = detect_video_type(clip)
if DEBUG_MODE:
    print(f"Detected: {video_type} (source: {detection_source})")

# 4. Обработка (16-bit)
if video_type in ["DOVI", "HDR10", "HLG"]:
    clip = process_hdr_content(clip, video_type, detection_source)
else:
    clip = process_sdr_content(clip)

clip = debug_clip_info(clip, "After processing (16-bit)")

# 5. Обрезка (16-bit)
if CropLeft or CropRight or CropTop or CropBottom:
    clip = core.std.CropRel(clip, CropLeft, CropRight, CropTop, CropBottom)
    clip = debug_clip_info(clip, "After crop")

# 6. Шейдеры (16-bit)
clip = apply_shaders(clip)

# 7. Финальная конвертация в 10-bit
clip = core.resize.Spline36(clip, format=vs.YUV420P10, dither_type="error_diffusion")
clip = debug_clip_info(clip, "Final 10-bit output")

if DEBUG_MODE:
    print("\n" + "=" * 60)
    print("Processing complete!")
    print("=" * 60)

clip.set_output()