import os, sys
import vapoursynth as vs
from vapoursynth import core

sys.path.append(r"X:\Apps\_VideoEncoding\StaxRip\Apps\Plugins\VS\Scripts")
import importlib.machinery

# --- Все константы (CSP, PRIMARY, TONE_MAP, etc.) остаются без изменений ---
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

# Функции тонмэппинга (tone_mapping_function)
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

# --- ФУНКЦИЯ ДЛЯ ЗАГРУЗКИ ВИДЕО ---
def load_video(path):
    """
    Пытается загрузить видео, используя несколько методов в порядке убывания предпочтения.
    Returns: vapoursynth.VideoNode
    """
    print(f"Попытка загрузки: {path}")
    
    try:
        # LWLibavSource (чаще всего работает, но медленнее)
        print("  Пробуем core.lsmas.LWLibavSource...")
        # Используем путь к видео как путь для кэш-файла. Lsmas создаст .lwi файл.
        return core.lsmas.LWLibavSource(source=path) # , cachefile=path)
    except Exception as e:
        print(f"  core.lsmas.LWLibavSource не удалось: {e}")
        
    try:
        # BestSource
        print("  Пробуем core.bs.VideoSource...")
        return core.bs.VideoSource(path, cachemode=3) #, hwdevice="d3d11va", hwfallback=True, showprogress=True)
    except Exception as e:
        print(f"  core.bs.VideoSource не удалось: {e}")

    try:
        # DGDecNV (требует DGDecNV и index файл)
        print("  Пробуем core.dgdecodenv.DGSource...")
        # DGSource ищет .dgi файл в той же папке. Если его нет, можно создать его через DGIndexNV.
        # Предполагаем, что файл уже существует или DGSource может его создать на лету.
        return core.dgdecodenv.DGSource(path)
    except Exception as e:
        print(f"  core.dgdecodenv.DGSource не удалось: {e}")


    # Если все методы не сработали
    raise RuntimeError(f"Не удалось загрузить видео файл ни одним из способов: {path}")

# --- Функция для обработки клипа ---
def process_clip(source_clip, tone_mapping_func, label_text):
    """Применяет тонмэппинг, шейдер и текст к клипу."""
    c = source_clip
    c = core.resize.Spline36(c, format=vs.YUV420P16)
    c = core.placebo.Tonemap(
        c,
        src_csp       = CSP_HDR10,
        dst_csp       = CSP_SDR,
        dst_prim      = PRIMARY_BT709,
        metadata      = METADATA_AUTO,
        gamut_mapping = GAMUT_MAP_PERCEPTUAL,
        tone_mapping_function=tone_mapping_func,
        src_min=0.005,
        src_max=1000.0,
        dst_min=0.0,
        dst_max=60.0,
        dynamic_peak_detection=True,
        tone_mapping_param=0.0,
        percentile=99.9,
        contrast_recovery=1
    )
    c = core.resize.Spline36(c, format=vs.YUV420P16)
    c = core.placebo.Shader(c, shader=r"X:\Apps\_VideoEncoding\ffmpeg\adaptive-sharpen_lite.glsl")
    c = core.resize.Spline36(c, format=vs.YUV420P10, dither_type="error_diffusion", matrix_s="709")
    c = core.text.Text(clip=c, text=label_text, alignment=8, scale=2)
    return c

# --- ОСНОВНАЯ ЛОГИКА ---

# 1. Загружаем видео с помощью новой функции.
video_hdr_path = r"g:\Видео\Сериалы\Зарубежные\Фоллаут (Fallout)\Fallout.S01.2024.2160p.UHD.AMZN.WEB-DL.DV.P5.HEVC-Нечипорук\Fallout.S01E01.2024.2160p.UHD.AMZN.WEB-DL.DV.P5.HEVC-Нечипорук.mp4"
clip_hdr = core.std.Crop(load_video(video_hdr_path), left=0, right=0, top=0, bottom=0)

video_sd_path = r"g:\Видео\Сериалы\Зарубежные\Фоллаут (Fallout)\Fallout.S01.2160p.AMZN.WEB-DL.H.265.SDR\Fallout.S01E01.The.End.2160p.AMZN.WEB-DL.H.265.RGzsRutracker.mkv"
clip_sd = core.std.Crop(load_video(video_sd_path), left=0, right=0, top=0, bottom=0)

print("Файлы загружены")

# 2. Определяем, какие клипы мы хотим получить.
clip_processing_configs = [
    {'label': r"clip1: TONE_MAP_ST2094_40", 'tone_mapping': TONE_MAP_ST2094_40},
    {'label': r"clip2: TONE_MAP_HABLE", 'tone_mapping': TONE_MAP_HABLE},
    # Теперь можно легко добавлять новые клипы, например:
    #{'label': r"clip3: TONE_MAP_BT2390", 'tone_mapping': TONE_MAP_BT2390},
    #{'label': r"clip4: TONE_MAP_BT2446A", 'tone_mapping': TONE_MAP_BT2446A}
]
print(clip_processing_configs)

# 3. Создаем список всех полноразмерных клипов, которые будут в финальной сборке.
all_full_size_clips = []
for config in clip_processing_configs:
    processed = process_clip(
        source_clip=clip_hdr,  # Используем загруженный HDR клип
        tone_mapping_func=config['tone_mapping'],
        label_text=config['label']
    )
    all_full_size_clips.append(processed)

# Добавляем исходный SDR клип в этот же список
all_full_size_clips.append(clip_sd)
print()

# 4. Вычисляем динамическую ширину обрезки.
num_clips = len(all_full_size_clips)
source_width = clip_hdr.width  # Используем ширину основного HDR источника как эталон
final_clip_width = source_width // num_clips
print('Динамическая ширина обрезки:', final_clip_width)

# 5. Обрезаем центральную часть каждого клипа до нужной ширины.
crop_amount = (source_width - final_clip_width) // 2
cropped_clips_to_stack = [core.std.CropRel(c, left=crop_amount, right=crop_amount, top=0, bottom=0) for c in all_full_size_clips]

# 6. Склеиваем обрезанные клипы горизонтально.
output_clip = core.std.StackHorizontal(cropped_clips_to_stack)

# Экспорт
output_clip.set_output()
