import vapoursynth as vs
core = vs.core
#clip = core.lsmas.LWLibavSource(source=r"{VideoPath}", cachefile=r"{CacheFile}", threads=8)
#{trimScript}

clip = core.dgdecodenv.DGSource(source=r"{VideoPath}")
#(source, i420, deinterlace, use_top_field, use_pf, strict_avc, ct, cb, cl, cr, rw, rh, fieldop, show, show2, indexing_path, h2s_enable, h2s_white, h2s_black, h2s_gamma, h2s_hue, h2s_r, h2s_g, h2s_b, h2s_tm, h2s_roll, h2s_mode, dn_enable, dn_strength, dn_cstrength, dn_quality, dn_tthresh, dn_show, sh_enable, sh_strength, sh_os, sh_us, sh_top, sh_bottom, sh_left, sh_right, tw_enable, tw_hue, tw_sat, tw_bright, tw_cont, tw_coring, tw_startHue, tw_endHue, tw_maxSat, tw_minSat, tw_interp, lv_enable, lv_input_low, lv_gamma, lv_input_high, lv_output_low, lv_output_high, lv_chroma, lv_coring, lv_dither)
clip = core.resize.Spline36(clip, format=vs.YUV444PS)
#ref  = core.bm3dcuda.BM3D(clip, sigma=[0.7, 0.5, 0.5])
#clip = core.bm3dcuda.BM3D(clip, ref, sigma=[0.5, 0.2, 0.2])
ref = core.bm3dcuda.BM3Dv2(clip, sigma=[0.7, 0.5, 0.5])
clip = core.bm3dcuda.BM3Dv2(clip, ref, sigma=[0.5, 0.2, 0.2])
clip = core.resize.Spline36(clip, format=vs.YUV420P16)


clip = core.placebo.Shader(clip, shader=r"X:\Apps\_VideoEncoding\ffmpeg\LiftGammaGain_lite.glsl")
clip = core.placebo.Shader(clip, shader=r"X:\Apps\_VideoEncoding\ffmpeg\adaptive-sharpen_lite.glsl")
clip = core.resize.Spline36(clip, format=vs.YUV420P10, dither_type="error_diffusion")

#clip = core.fmtc.bitdepth(clip, bits=10)
#clip = core.std.Crop(clip, {CropLeft}, {CropRight}, {CropTop}, {CropBottom})
clip.set_output()