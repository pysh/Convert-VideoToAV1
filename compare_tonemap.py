"""
Скрипт для сравнения вариантов ToneMapping видеофайла.
Создает горизонтально сложенное видео с разными настройками тонмаппинга.
Итоговое разрешение = разрешению исходного файла.
Каждый вариант - вертикальная полоса из центра кадра.

Использование:
    python compare_tonemap.py input_video.mkv
    python compare_tonemap.py input_video.mkv --variants "Placebo,Reinhard,ST2094-40"
    python compare_tonemap.py input_video.mkv --frames 100 --start 500
    python compare_tonemap.py --list-variants
"""

import os
import sys
import argparse
from pathlib import Path
import vapoursynth as vs
from vapoursynth import core

# ===== КОНСТАНТЫ ТОНМАППИНГА =====
# Цветовые пространства (src_csp, dst_csp)
CSP_SDR   = 0
CSP_HDR10 = 1
CSP_HLG   = 2
CSP_DOVI  = 3

# Цветовые первичные (dst_prim)
PRIMARY_BT709     = 3
PRIMARY_BT2020    = 6

# Функции тонмаппинга (tone_mapping_function)
TONE_MAP_SPLINE      = 1
TONE_MAP_ST2094_40   = 2
TONE_MAP_ST2094_10   = 3
TONE_MAP_BT2390      = 4
TONE_MAP_BT2446A     = 5
TONE_MAP_REINHARD    = 6
TONE_MAP_MOBIUS      = 7
TONE_MAP_HABLE       = 8
TONE_MAP_GAMMA       = 9
TONE_MAP_LINEAR      = 10

# Режимы отображения гамута (gamut_mapping)
GAMUT_MAP_CLIP       = 0
GAMUT_MAP_PERCEPTUAL = 1
GAMUT_MAP_SOFTCLIP   = 2
GAMUT_MAP_RELATIVE   = 3
GAMUT_MAP_SATURATION = 4
GAMUT_MAP_ABSOLUTE   = 5
GAMUT_MAP_DESATURE   = 6
GAMUT_MAP_DARKEN     = 7
GAMUT_MAP_HIGHLIGHT  = 8
GAMUT_MAP_LINEAR     = 9

# Метаданные
METADATA_AUTO = 0
METADATA_NONE = 1

# ===== НАСТРОЙКИ PLACEBO (БАЗОВЫЕ) =====
PLACEBO_TONEMAP_SETTINGS = {
    'gamut_mapping': GAMUT_MAP_PERCEPTUAL,
    'tone_mapping_function': TONE_MAP_ST2094_10,
    'src_min': 0.0050,
    'src_max': 1000.0,
    'dst_min': 0.1,
    'dst_max': 100.0,
    'dynamic_peak_detection': True,
    'percentile': 99.995,
    'contrast_recovery': 0.3,
    'log_level': 0  # Тихий режим по умолчанию
}


def log(message, level="INFO", debug=True):
    """Упрощенное логирование"""
    if debug:
        print(f"[{level}] {message}")


def create_tonemap_variants():
    """
    Создает различные варианты настроек тонмаппинга для сравнения.
    Каждый вариант - это словарь с настройками для placebo.Tonemap.
    """
    variants = {}
    
    # 1. Placebo (базовый)
    variants["Placebo (ST2094-10)"] = dict(PLACEBO_TONEMAP_SETTINGS)
    
    # 2-6: Разные функции тонмаппинга
    variants["ST2094-40"] = {**PLACEBO_TONEMAP_SETTINGS, 
                             'tone_mapping_function': TONE_MAP_ST2094_40}
    
    variants["BT.2390"] = {**PLACEBO_TONEMAP_SETTINGS, 
                           'tone_mapping_function': TONE_MAP_BT2390}
    
    variants["BT.2446A"] = {**PLACEBO_TONEMAP_SETTINGS, 
                            'tone_mapping_function': TONE_MAP_BT2446A}
    
    variants["Reinhard"] = {**PLACEBO_TONEMAP_SETTINGS, 
                            'tone_mapping_function': TONE_MAP_REINHARD}
    
    variants["Mobius"] = {**PLACEBO_TONEMAP_SETTINGS, 
                          'tone_mapping_function': TONE_MAP_MOBIUS}
    
    variants["Hable"] = {**PLACEBO_TONEMAP_SETTINGS, 
                         'tone_mapping_function': TONE_MAP_HABLE}
    
    # 7-9: Разные gamut mapping
    variants["Gamut: Perceptual"] = dict(PLACEBO_TONEMAP_SETTINGS)
    variants["Gamut: Perceptual"]['gamut_mapping'] = GAMUT_MAP_PERCEPTUAL
    
    variants["Gamut: Clip"] = {**PLACEBO_TONEMAP_SETTINGS, 
                               'gamut_mapping': GAMUT_MAP_CLIP}
    
    variants["Gamut: Darken"] = {**PLACEBO_TONEMAP_SETTINGS, 
                                 'gamut_mapping': GAMUT_MAP_DARKEN}
    
    variants["Gamut: SoftClip"] = {**PLACEBO_TONEMAP_SETTINGS, 
                                   'gamut_mapping': GAMUT_MAP_SOFTCLIP}
    
    variants["Gamut: Saturation"] = {**PLACEBO_TONEMAP_SETTINGS, 
                                     'gamut_mapping': GAMUT_MAP_SATURATION}
    
    # 10-12: Разные уровни контраста
    variants["Low Contrast (0.1)"] = {**PLACEBO_TONEMAP_SETTINGS, 
                                      'contrast_recovery': 0.1}
    
    variants["Medium Contrast (0.3)"] = dict(PLACEBO_TONEMAP_SETTINGS)
    
    variants["High Contrast (0.8)"] = {**PLACEBO_TONEMAP_SETTINGS, 
                                       'contrast_recovery': 0.8}
    
    # 13-15: Разные целевые яркости
    variants["Darker Output"] = {**PLACEBO_TONEMAP_SETTINGS, 
                                 'dst_min': 0.1, 'dst_max': 50.0}
    
    variants["Brighter Output"] = {**PLACEBO_TONEMAP_SETTINGS, 
                                   'dst_min': 1.0, 'dst_max': 200.0}
    
    variants["Very Bright"] = {**PLACEBO_TONEMAP_SETTINGS, 
                               'dst_min': 2.0, 'dst_max': 400.0}
    
    # 16-17: Разные src_max
    variants["src_max=500"] = {**PLACEBO_TONEMAP_SETTINGS, 'src_max': 500.0}
    variants["src_max=4000"] = {**PLACEBO_TONEMAP_SETTINGS, 'src_max': 4000.0}
    
    # 18: Без dynamic peak detection
    variants["No Dynamic Peak"] = {**PLACEBO_TONEMAP_SETTINGS, 
                                   'dynamic_peak_detection': 0, 
                                   'src_max': 1000.0}
    
    # 19-20: Разные процентили
    variants["Percentile 99.9"] = {**PLACEBO_TONEMAP_SETTINGS, 
                                   'percentile': 99.9}
    variants["Percentile 100"] = {**PLACEBO_TONEMAP_SETTINGS, 
                                  'percentile': 100.0}
    
    return variants


def detect_hdr_type(clip):
    """Определяет тип HDR контента"""
    try:
        frame = clip.get_frame(0)
        props = frame.props
        
        # Проверка на Dolby Vision
        has_dovi = False
        if 'DolbyVisionRPU' in props:
            has_dovi = True
        if props.get('DOVI_rpu_present', False):
            has_dovi = True
        
        # Проверка на HDR10/HLG
        transfer = props.get('_Transfer', 0)
        primaries = props.get('_Primaries', 0)
        
        if has_dovi:
            return "DOVI"
        elif transfer == 16:  # PQ
            return "HDR10"
        elif transfer == 18:  # HLG
            return "HLG"
        else:
            return "SDR"
    except Exception as e:
        log(f"Detection failed: {e}, assuming HDR10", "WARNING")
        return "HDR10"


def apply_tonemap(clip, settings, hdr_type="HDR10"):
    """
    Применяет тонмаппинг с указанными настройками.
    
    Args:
        clip: Входной клип (16-bit)
        settings: Словарь с настройками тонмаппинга
        hdr_type: Тип HDR ("DOVI", "HDR10", "HLG")
    
    Returns:
        Обработанный клип
    """
    # Определяем src_csp
    if hdr_type == "DOVI":
        src_csp = CSP_DOVI
        use_dovi = 1
    elif hdr_type == "HLG":
        src_csp = CSP_HLG
        use_dovi = 0
    else:  # HDR10
        src_csp = CSP_HDR10
        use_dovi = 0
    
    try:
        return core.placebo.Tonemap(
            clip,
            src_csp=src_csp,
            dst_csp=CSP_SDR,
            dst_prim=PRIMARY_BT709,
            metadata=METADATA_AUTO,
            use_dovi=use_dovi,
            **settings
        )
    except Exception as e:
        log(f"Tonemap failed: {e}", "ERROR")
        # Fallback: возвращаем оригинальный клип
        return clip


def crop_center_strip(clip, target_width):
    """
    Вырезает вертикальную полосу из центра кадра заданной ширины.
    
    Args:
        clip: Входной клип
        target_width: Целевая ширина полосы
    
    Returns:
        Клип с центральной полосой
    """
    src_width = clip.width
    src_height = clip.height
    
    # Вычисляем отступы слева и справа
    crop_left = (src_width - target_width) // 2
    crop_right = src_width - target_width - crop_left
    
    # Корректируем если сумма не совпадает из-за округления
    if crop_left + target_width + crop_right != src_width:
        crop_right = src_width - target_width - crop_left
    
    if crop_left > 0 or crop_right > 0:
        clip = core.std.Crop(clip, left=crop_left, right=crop_right)
    
    return clip


def resize_strips_for_stacking(clips, source_width, source_height, num_variants):
    """
    Изменяет размер полос так, чтобы итоговое разрешение совпадало с исходным.
    Каждая полоса получает равную ширину: source_width / num_variants.
    Высота остается исходной.
    
    Args:
        clips: Список клипов [(name, clip), ...]
        source_width: Ширина исходного видео
        source_height: Высота исходного видео
        num_variants: Количество вариантов
    
    Returns:
        Список обработанных клипов одинакового размера
    """
    # Вычисляем ширину каждой полосы
    strip_width = source_width // num_variants
    
    # Корректируем до четного
    if strip_width % 2 != 0:
        strip_width -= 1
    
    # Суммарная ширина всех полос
    total_width = strip_width * num_variants
    
    # Если есть остаток, добавляем к последней полосе
    remainder = source_width - total_width
    
    processed = []
    
    for i, (name, clip) in enumerate(clips):
        # Определяем ширину для этой полосы
        current_width = strip_width
        if i == len(clips) - 1:
            current_width += remainder
        
        # Делаем ширину четной
        if current_width % 2 != 0:
            current_width += 1
        
        # Вырезаем центральную полосу
        clip = crop_center_strip(clip, current_width)
        
        # Убеждаемся что высота совпадает с исходной
        if clip.height != source_height:
            clip = core.resize.Bicubic(clip, height=source_height)
        
        processed.append(clip)
    
    return processed


def create_comparison(input_file, output_file=None, variants_to_show=None,
                     start_frame=0, num_frames=None,
                     debug=True, cache_file=None):
    """
    Основная функция сравнения вариантов тонмаппинга.
    Итоговое разрешение = разрешению исходного файла.
    
    Args:
        input_file: Путь к входному видео
        output_file: Путь к выходному файлу (.vpy или .mkv)
        variants_to_show: Список названий вариантов для показа
        start_frame: Начальный кадр
        num_frames: Количество кадров (None = все)
        debug: Включить отладку
        cache_file: Файл кэша для индексации
    """
    
    log(f"Loading: {input_file}", "INFO", debug)
    
    # Загружаем видео
    try:
        if cache_file and os.path.exists(cache_file):
            clip = core.lsmas.LWLibavSource(input_file, cachefile=cache_file)
        else:
            clip = core.lsmas.LWLibavSource(input_file)
        log(f"Loaded: {clip.width}x{clip.height} {clip.format.name}", "INFO", debug)
    except Exception as e:
        log(f"LWLibavSource failed: {e}, trying BestSource", "WARNING", debug)
        try:
            clip = core.bs.VideoSource(input_file)
        except:
            log("Trying ffms2...", "WARNING", debug)
            clip = core.ffms2.Source(input_file)
    
    # Сохраняем исходное разрешение
    source_width = clip.width
    source_height = clip.height
    
    # Trim если нужно
    if start_frame > 0 or num_frames:
        if num_frames:
            end_frame = start_frame + num_frames
            clip = clip[start_frame:end_frame]
            log(f"Trimmed: frames {start_frame}-{end_frame}", "INFO", debug)
        else:
            clip = clip[start_frame:]
            log(f"Trimmed: frames {start_frame}-end", "INFO", debug)
    
    # Определяем тип HDR
    hdr_type = detect_hdr_type(clip)
    log(f"Detected HDR type: {hdr_type}", "INFO", debug)
    
    # Конвертируем в 16-bit для тонмаппинга
    if clip.format.bits_per_sample != 16:
        clip = core.resize.Spline36(clip, format=vs.YUV420P16)
        log("Converted to 16-bit", "DEBUG", debug)
    
    # Получаем варианты
    all_variants = create_tonemap_variants()
    
    if variants_to_show:
        # Проверяем существование вариантов
        invalid = [v for v in variants_to_show if v not in all_variants]
        if invalid:
            log(f"Unknown variants: {invalid}", "WARNING", debug)
        variants = {k: v for k, v in all_variants.items() if k in variants_to_show}
    else:
        # По умолчанию показываем основные 9 вариантов
        default_variants = [
            "Placebo (ST2094-10)",
            "ST2094-40",
            "BT.2390",
            "Reinhard",
            "Mobius",
            "Gamut: Clip",
            "Gamut: Darken",
            "High Contrast (0.8)",
            "No Dynamic Peak"
        ]
        variants = {k: all_variants[k] for k in default_variants if k in all_variants}
    
    log(f"Processing {len(variants)} variants...", "INFO", debug)
    log(f"Source resolution: {source_width}x{source_height}", "INFO", debug)
    log(f"Each strip will be ~{source_width // len(variants)}px wide", "INFO", debug)
    
    # Применяем тонмаппинг
    tonemapped_clips = []
    for i, (name, settings) in enumerate(variants.items(), 1):
        log(f"  [{i}/{len(variants)}] {name}", "INFO", debug)
        
        try:
            tm_clip = apply_tonemap(clip, settings, hdr_type)
            
            # Конвертируем в 10-bit для совместимости с текстом и вывода
            tm_clip = core.resize.Spline36(tm_clip, format=vs.YUV420P10)
            
            # Добавляем текст с названием варианта
            try:
                tm_clip = core.text.Text(tm_clip, text=name, alignment=7)  # top-left
            except:
                try:
                    tm_clip = core.subtext.Text(tm_clip, text=name)
                except:
                    log(f"  Text plugin not available, skipping label", "WARNING", debug)
            
            tonemapped_clips.append((name, tm_clip))
        except Exception as e:
            log(f"  Failed: {e}", "ERROR", debug)
            continue
    
    if not tonemapped_clips:
        log("No clips processed successfully!", "ERROR", debug)
        return None
    
    # Вырезаем центральные полосы и подгоняем ширину
    log(f"Creating {len(tonemapped_clips)} strips from center of each variant", "INFO", debug)
    processed_clips = resize_strips_for_stacking(
        tonemapped_clips, source_width, source_height, len(tonemapped_clips)
    )
    
    # Создаем горизонтальный стек
    log(f"Stacking {len(processed_clips)} strips horizontally", "INFO", debug)
    
    if len(processed_clips) == 1:
        final = processed_clips[0]
    else:
        final = core.std.StackHorizontal(processed_clips)
    
    # Проверяем итоговое разрешение
    log(f"Output: {final.width}x{final.height} (source: {source_width}x{source_height})", "INFO", debug)
    
    if final.width != source_width or final.height != source_height:
        log(f"Resolution mismatch! Adjusting to {source_width}x{source_height}", "WARNING", debug)
        final = core.resize.Bicubic(final, width=source_width, height=source_height)
    
    # Добавляем общий заголовок
    title = f"HDR Type: {hdr_type} | Variants: {len(processed_clips)}"
    try:
        final = core.text.Text(final, text=title, alignment=8)  # top-center
    except:
        try:
            final = core.subtext.Text(final, text=title)
        except:
            pass
    
    # Сохраняем результат
    if output_file:
        output_path = Path(output_file)
        
        if output_path.suffix == '.vpy':
            _save_as_vpy(final, output_file, input_file, variants, hdr_type, 
                        start_frame, num_frames, source_width, source_height)
        else:
            _save_as_video(final, output_file, debug)
    else:
        # По умолчанию сохраняем как VPY скрипт
        default_output = Path(input_file).stem + "_tonemap_comparison.vpy"
        _save_as_vpy(final, default_output, input_file, variants, hdr_type,
                    start_frame, num_frames, source_width, source_height)
    
    return final


def _save_as_vpy(final_clip, output_file, input_file, variants, hdr_type, 
                 start_frame, num_frames, source_width, source_height):
    """Сохраняет результат как VapourSynth скрипт для последующего использования"""
    
    # Правильная обработка None в num_frames
    trim_code = ""
    if start_frame > 0 or num_frames:
        if num_frames:
            end_frame = start_frame + num_frames
            trim_code = f"clip = clip[{start_frame}:{end_frame}]"
        else:
            trim_code = f"clip = clip[{start_frame}:]"
    
    num_variants = len(variants)
    
    script_content = f'''# """
# VapourSynth Script - ToneMapping Comparison
# Generated for: {input_file}
# HDR Type: {hdr_type}
# Variants: {num_variants}
# Source resolution: {source_width}x{source_height}

# Usage:
#     vspipe --y4m {output_file} - | ffmpeg -i pipe: -c:v libx264 -crf 18 output.mp4
# """

import vapoursynth as vs
from vapoursynth import core

# Константы
CSP_SDR = 0
CSP_HDR10 = 1
CSP_HLG = 2
CSP_DOVI = 3
PRIMARY_BT709 = 3
METADATA_AUTO = 0

# Загрузка видео
clip = core.lsmas.LWLibavSource(r"{input_file}")

# Trim
{trim_code}

# Сохраняем исходное разрешение
source_width = clip.width
source_height = clip.height

# Конвертация в 16-bit
if clip.format.bits_per_sample != 16:
    clip = core.resize.Spline36(clip, format=vs.YUV420P16)

# Варианты тонмаппинга
variants = {repr(variants)}
hdr_type = "{hdr_type}"
src_csp = CSP_DOVI if hdr_type == "DOVI" else (CSP_HLG if hdr_type == "HLG" else CSP_HDR10)
use_dovi = 1 if hdr_type == "DOVI" else 0

# Вычисляем ширину каждой полосы
num_variants = len(variants)
strip_width = source_width // num_variants
if strip_width % 2 != 0:
    strip_width -= 1

# Суммарная ширина и остаток
total_width = strip_width * num_variants
remainder = source_width - total_width

processed_clips = []

for i, (name, settings) in enumerate(variants.items()):
    # Применяем тонмаппинг
    tm_clip = core.placebo.Tonemap(
        clip,
        src_csp=src_csp,
        dst_csp=CSP_SDR,
        dst_prim=PRIMARY_BT709,
        metadata=METADATA_AUTO,
        use_dovi=use_dovi,
        **settings
    )
    
    # Конвертация в 10-bit
    tm_clip = core.resize.Spline36(tm_clip, format=vs.YUV420P10)
    
    # Определяем ширину для этой полосы
    current_width = strip_width
    if i == num_variants - 1:
        current_width += remainder
    
    if current_width % 2 != 0:
        current_width += 1
    
    # Вырезаем центральную полосу
    crop_left = (tm_clip.width - current_width) // 2
    crop_right = tm_clip.width - current_width - crop_left
    if crop_left > 0 or crop_right > 0:
        tm_clip = core.std.Crop(tm_clip, left=crop_left, right=crop_right)
    
    # Подгоняем высоту к исходной
    if tm_clip.height != source_height:
        tm_clip = core.resize.Bicubic(tm_clip, height=source_height)
    
    # Добавляем метку
    try:
        tm_clip = core.text.Text(tm_clip, text=name, alignment=7)
    except:
        pass
    
    processed_clips.append(tm_clip)

# Стекинг
if len(processed_clips) == 1:
    final = processed_clips[0]
else:
    final = core.std.StackHorizontal(processed_clips)

# Проверяем и корректируем итоговое разрешение
if final.width != source_width or final.height != source_height:
    final = core.resize.Bicubic(final, width=source_width, height=source_height)

# Заголовок
try:
    final = core.text.Text(final, text=f"HDR Type: {{hdr_type}} | Variants: {{num_variants}}", alignment=8)
except:
    pass

final.set_output()
'''
    
    with open(output_file, 'w', encoding='utf-8') as f:
        f.write(script_content)
    
    log(f"VapourSynth script saved to: {output_file}", "INFO")
    print(f"\nTo encode, run:")
    print(f'vspipe --y4m "{output_file}" - | ffmpeg -i pipe: -c:v libx264 -crf 18 output.mp4')


def _save_as_video(clip, output_file, debug=True):
    """Сохраняет клип напрямую в видеофайл через vspipe"""
    log("Direct video saving not implemented. Use VPY script approach.", "WARNING", debug)
    _save_as_vpy(clip, output_file.replace('.mp4', '.vpy').replace('.mkv', '.vpy'),
                 "unknown", {}, "HDR10", 0, None, 1920, 1080)


def main():
    parser = argparse.ArgumentParser(
        description='Сравнение вариантов ToneMapping видео (итоговое разрешение = исходному)',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Примеры использования:
  # Сравнить 9 основных вариантов
  python compare_tonemap.py video.mkv
  
  # Сравнить конкретные варианты
  python compare_tonemap.py video.mkv --variants "Placebo (ST2094-10),Reinhard,Mobius"
  
  # Сравнить все 20 вариантов
  python compare_tonemap.py video.mkv --all-variants
  
  # Обработать определенный отрезок
  python compare_tonemap.py video.mkv --start 1000 --frames 100
  
  # Указать выходной файл
  python compare_tonemap.py video.mkv --output comparison.vpy
  
  # Показать список всех вариантов
  python compare_tonemap.py --list-variants
  
После создания .vpy скрипта, закодируйте его:
  vspipe --y4m comparison.vpy - | ffmpeg -i pipe: -c:v libx264 -crf 18 output.mp4
  
Примечание: итоговое разрешение будет равно разрешению исходного файла.
Каждый вариант отображается как вертикальная полоса из центра кадра.
        """
    )
    
    parser.add_argument('input', nargs='?', help='Входной видеофайл')
    parser.add_argument('--output', '-o', help='Выходной файл (.vpy или .mp4)')
    parser.add_argument('--variants', '-v', 
                       help='Варианты для сравнения (через запятую)')
    parser.add_argument('--all-variants', '-a', action='store_true',
                       help='Показать все 20 вариантов')
    parser.add_argument('--frames', '-f', type=int, 
                       help='Количество кадров для обработки')
    parser.add_argument('--start', '-s', type=int, default=0,
                       help='Начальный кадр (default: 0)')
    parser.add_argument('--cache', '-c', help='Файл кэша для индексации')
    parser.add_argument('--quiet', '-q', action='store_true',
                       help='Отключить отладочные сообщения')
    parser.add_argument('--list-variants', '-l', action='store_true',
                       help='Показать список доступных вариантов')
    
    args = parser.parse_args()
    
    # Показываем список вариантов
    if args.list_variants:
        variants = create_tonemap_variants()
        print("\nДоступные варианты тонмаппинга:")
        print("=" * 60)
        
        categories = {
            "Функции тонмаппинга": ["Placebo (ST2094-10)", "ST2094-40", "BT.2390", 
                                    "BT.2446A", "Reinhard", "Mobius", "Hable"],
            "Gamut Mapping": ["Gamut: Perceptual", "Gamut: Clip", "Gamut: Darken", 
                             "Gamut: SoftClip", "Gamut: Saturation"],
            "Уровни контраста": ["Low Contrast (0.1)", "Medium Contrast (0.3)", 
                                "High Contrast (0.8)"],
            "Целевая яркость": ["Darker Output", "Brighter Output", "Very Bright"],
            "Параметры источника": ["src_max=500", "src_max=4000", "No Dynamic Peak"],
            "Процентили": ["Percentile 99.9", "Percentile 100"]
        }
        
        for category, variant_names in categories.items():
            print(f"\n{category}:")
            for name in variant_names:
                if name in variants:
                    settings = variants[name]
                    desc = f"  - {name}"
                    if 'tone_mapping_function' in settings:
                        desc += f" [func={settings['tone_mapping_function']}]"
                    if 'contrast_recovery' in settings:
                        desc += f" [contrast={settings['contrast_recovery']}]"
                    if 'src_max' in settings:
                        desc += f" [src_max={settings['src_max']}]"
                    print(desc)
        
        print("\n" + "=" * 60)
        print(f"Всего вариантов: {len(variants)}")
        print("\nИспользование с конкретными вариантами:")
        print('python compare_tonemap.py video.mkv --variants "Placebo (ST2094-10),Reinhard,Mobius"')
        return
    
    # Проверяем входной файл
    if not args.input:
        parser.print_help()
        print("\nОшибка: укажите входной видеофайл")
        return 1
    
    if not os.path.exists(args.input):
        print(f"Ошибка: файл не найден: {args.input}")
        return 1
    
    debug = not args.quiet
    
    # Парсим варианты
    variants_to_show = None
    if args.all_variants:
        variants_to_show = list(create_tonemap_variants().keys())
    elif args.variants:
        variants_to_show = [v.strip() for v in args.variants.split(',')]
        if debug:
            print(f"Selected variants: {len(variants_to_show)}")
    
    # Запускаем сравнение
    try:
        create_comparison(
            input_file=args.input,
            output_file=args.output,
            variants_to_show=variants_to_show,
            start_frame=args.start,
            num_frames=args.frames,
            debug=debug,
            cache_file=args.cache
        )
    except Exception as e:
        print(f"Error: {e}")
        import traceback
        traceback.print_exc()
        return 1
    
    return 0


if __name__ == "__main__":
    exit(main())