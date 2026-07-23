import vapoursynth as vs
core = vs.core
#clip = core.lsmas.LWLibavSource(source=r"{VideoPath}", cachefile=r"{CacheFile}", threads=8)
clip = core.dgdecodenv.DGSource(source=r"{VideoPath}")
#{trimScript}
clip = core.std.Crop(clip, 0, 0, 140, 140)

#clip = core.resize.Spline36(clip, format=vs.YUV444PS)
#ref  = core.bm3dcuda.BM3D(clip, sigma=[3, 2, 2])
#clip = core.bm3dcuda.BM3D(clip, ref, sigma=[3, 2, 2])
clip = core.resize.Spline36(clip, format=vs.YUV420P16)
clip = core.placebo.Shader(clip, shader=r"X:\Apps\_VideoEncoding\ffmpeg\LiftGammaGain.glsl")
clip = core.placebo.Shader(clip, shader=r"X:\Apps\_VideoEncoding\ffmpeg\adaptive-sharpen.glsl")
clip = core.resize.Spline36(clip, format=vs.YUV420P10, dither_type="error_diffusion")

#clip = core.fmtc.bitdepth(clip, bits=10)
clip.set_output()