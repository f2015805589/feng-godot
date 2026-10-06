// UE 5.8 default SDR film LUT addressing. Entries are scaled by 1/1.05 and
// quantized to the default 10-bit UNORM storage range before being carried in
// RGBA16F. Restore that headroom after hardware trilinear interpolation, then
// decode sRGB to keep Godot's output conversion single-pass.
vec3 sample_ue_film_lut(sampler3D lut, vec3 linear_color) {
	const float linear_range = 14.0;
	const float linear_grey = 0.18;
	const float exposure_grey = 444.0;
	float black_offset = 0.18 * exp2((-exposure_grey / 1023.0) * linear_range);
	const float log_grey = log2(linear_grey);
	vec3 lut_encoded = log2(max(linear_color + black_offset, vec3(black_offset))) / linear_range - log_grey / linear_range + exposure_grey / 1023.0;
	lut_encoded = clamp(lut_encoded, vec3(0.0), vec3(1.0));
	const float lut_size = 32.0;
	vec3 uvw = lut_encoded * ((lut_size - 1.0) / lut_size) + vec3(0.5 / lut_size);
	vec3 lut_sample_encoded = textureLod(lut, uvw, 0.0).rgb * 1.05;
	return srgb_to_linear(lut_sample_encoded);
}
