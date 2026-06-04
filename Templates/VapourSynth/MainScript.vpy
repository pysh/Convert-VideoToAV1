import vapoursynth as vs
core = vs.core
clip = core.lsmas.LWLibavSource(source=r"{VideoPath}", cachefile=r"{CacheFile}")
{trimScript}

# clip = core.resize.Spline36(clip, format=vs.YUV444PS)
# ref  = core.bm3dcuda.BM3D(clip, sigma=[2, 1, 1])
# clip = core.bm3dcuda.BM3D(clip, ref, sigma=[2, 1, 1])
clip = core.resize.Spline36(clip, format=vs.YUV420P16)
clip = core.placebo.Shader(clip, shader=r"X:\Apps\_VideoEncoding\ffmpeg\LiftGammaGain_lite.glsl")
clip = core.placebo.Shader(clip, shader=r"X:\Apps\_VideoEncoding\ffmpeg\adaptive-sharpen_lite.glsl")
clip = core.resize.Spline36(clip, format=vs.YUV420P10, dither_type="error_diffusion")

#clip = core.fmtc.bitdepth(clip, bits=10)
clip = core.std.Crop(clip, {CropLeft}, {CropRight}, {CropTop}, {CropBottom})
clip.set_output()