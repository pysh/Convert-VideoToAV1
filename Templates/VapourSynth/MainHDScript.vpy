import vapoursynth as vs
core = vs.core
clip = core.lsmas.LWLibavSource(source=r"{VideoPath}", cachefile=r"{CacheFile}", threads=8)
{trimScript}

#clip = core.resize.Spline36(clip, format=vs.YUV444PS)
#ref  = core.bm3dcuda.BM3D(clip, sigma=[3, 2, 2])
#clip = core.bm3dcuda.BM3D(clip, ref, sigma=[3, 2, 2])
clip = core.resize.Spline36(clip, format=vs.YUV420P16)
#clip = core.placebo.Shader(clip, shader=r"X:\Apps\_VideoEncoding\ffmpeg\LiftGammaGain_lite.glsl")
clip = core.placebo.Shader(clip, shader=r"X:\Apps\_VideoEncoding\ffmpeg\adaptive-sharpen_lite.glsl")
clip = core.resize.Spline36(clip, format=vs.YUV420P10, dither_type="error_diffusion")

#clip = core.fmtc.bitdepth(clip, bits=10)
clip = core.std.Crop(clip, {CropLeft}, {CropRight}, {CropTop}, {CropBottom})
clip.set_output()


$ffmpegParams = @(
'-f', 'vapoursynth',
'-i', 'r:\Temp\Sugar.S02E05.WEB-DL.2160p.DV.HDR10.RGzsRutracker_EncodingTests\Sugar.S02E05.WEB-DL.2160p.DV.HDR10.RGzsRutracker_sample.vpy',
'-c:v', 'hevc_nvenc',
'-tune', 'lossless',
'-rc', 'constqp',
'-qp', 0,
'y:\.temp\Sugar.S02E05.WEB-DL.2160p.DV.HDR10.RGzsRutracker_sample[LL].mkv'
)



. vspipe 'r:\Temp\Sugar.S02E05.WEB-DL.2160p.DV.HDR10.RGzsRutracker_EncodingTests\Sugar.S02E05.WEB-DL.2160p.DV.HDR10.RGzsRutracker_sample.vpy' -c y4m - | & 'SvtAv1EncApp.exe' --input stdin --output 'y:\.temp\Sugar.S02E05.WEB-DL.2160p.DV.HDR10.RGzsRutracker_sample[LL].ivf' --progress 2 --lossless 1 --color-range 0 --color-primaries 1 --transfer-characteristics 1 --matrix-coefficients 1 --frames 7063