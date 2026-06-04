import vapoursynth as vs
import os

core = vs.core

# Если основной text плагин не работает, используем subtext
try:
    text_plugin = core.text
except AttributeError:
    try:
        text_plugin = core.subtext
        print("Используем subtext вместо text")
    except AttributeError:
        raise ImportError("Ни text, ни subtext плагины не найдены")

# Массив входных файлов
video_files = [
        r"f:\Видео\Сериалы\Зарубежные\Больница Питт (The Pitt)\The.Pitt.S02.2160p.HMAX.WEB-DL.HDR.H.265\.enc_av1-ess\Больница Питт - s02e10 - Десятый час_ с 16_00 до 17_00 [2026-03-12][4k][av1][DVtoSDR].mkv",
        r"f:\Видео\Сериалы\Зарубежные\Больница Питт (The Pitt)\The.Pitt.S02.2160p.HMAX.WEB-DL.HDR.H.265\.enc_av1-ess\Больница Питт - s02e10 - Десятый час_ с 16_00 до 17_00 [2026-03-12][4k][av1][DVtoSDR_LGGFull].mkv",
        #r"f:\Видео\Сериалы\Зарубежные\Больница Питт (The Pitt)\The.Pitt.S02.2160p.HMAX.WEB-DL.HDR.H.265\.enc_av1-ess\Больница Питт - s02e10 - Десятый час_ с 16_00 до 17_00 [2026-03-12][4k][av1][HDRtoSDR_grain].mkv"
]

existing_files = [f for f in video_files if os.path.exists(f)]
if len(existing_files) < 2:
    raise ValueError("Нужно как минимум 2 файла")

num_files = len(existing_files)
crop_percent = min(100 / num_files, 50)

clips = []
max_height = 0

# Функция для добавления текста (совместимая с разными плагинами)
def add_text_safe(clip, text, position=1):
    """Универсальная функция добавления текста"""
    try:
        # Пробуем text с alignment
        return text_plugin.Text(clip, text=text, alignment=position, scale=1.0)
    except Exception as e:
        # Fallback: простой текст без позиционирования
        print(f"Ошибка позиционирования: {e}, используем простой текст")
        return text_plugin.Text(clip, text=text)

# Обработка каждого файла
for i, file_path in enumerate(existing_files):
    clip = core.lsmas.LWLibavSource(file_path)
    
    # Динамический crop
    crop_width = max(100, int(clip.width * crop_percent / 100))
    left = (clip.width - crop_width) // 2
    cropped = core.std.Crop(clip, left=left, right=clip.width - left - crop_width)
    
    # Текст ДО стекинга
    text = f"File {i+1}: {os.path.basename(file_path)}"
    texted_clip = add_text_safe(cropped, text, 1)
    
    clips.append(texted_clip)
    max_height = max(max_height, texted_clip.height)

# Масштабирование к общей высоте
processed_clips = []
for clip in clips:
    if clip.height != max_height:
        processed_clips.append(core.resize.Bicubic(clip, height=max_height))
    else:
        processed_clips.append(clip)

# Стекинг
stacked = core.std.StackHorizontal(processed_clips)

# Общая информация
final = add_text_safe(stacked, f"Comparison: {num_files} files | Crop: {crop_percent:.1f}%", 8)

final.set_output()