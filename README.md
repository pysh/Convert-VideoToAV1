# Convert-VideoToAV1

Универсальный конвейер для конвертации видео в AV1/HEVC с сохранением всех метаданных.

## Архитектура
Convert-VideoToAV1.ps1
│
├── DemuxProcessor → Извлечение всех потоков
├── NfoProcessor → Обработка метаданных
├── AudioProcessor → Перекодирование аудио
├── VideoProcessor → Кодирование видео
└── MuxProcessor → Сборка MKV

text

## Требования

- PowerShell 7.5 или выше
- MKVToolNix (mkvmerge, mkvextract, mkvpropedit)
- FFmpeg/FFprobe
- VapourSynth
- OpusEnc или QAAC

## Установка

```powershell
git clone https://github.com/yourusername/Convert-VideoToAV1.git
cd Convert-VideoToAV1
Использование
powershell
.\Convert-VideoToAV1.ps1 -InputDirectory "D:\Videos" -Encoder "SvtAv1EncESS.grain_optimized"
Параметры
Параметр	Описание
-InputDirectory	Входная директория с видео
-OutputDirectory	Выходная директория (по умолчанию .enc)
-Encoder	Энкодер и пресет (например, x265.film_grain)
-CopyAudio	Копировать аудио без перекодирования
-CopyVideo	Копировать видео без перекодирования
-TrimStartSeconds	Начало обрезки в секундах
-TrimEndSeconds	Конец обрезки в секундах
-ListEncoders	Показать доступные энкодеры
-Force	Перезаписывать существующие файлы
Лицензия
MIT
