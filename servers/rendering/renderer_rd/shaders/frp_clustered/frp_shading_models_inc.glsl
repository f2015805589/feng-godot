// FRP's independent material/BxDF layer, modeled after Unreal's legacy
// ShadingModels.ush seam: packed ShadingModelID selects IntegrateBxDF(), while
// clustered light discovery, attenuation and shadows remain renderer plumbing.
#ifndef FRP_SHADING_MODELS_INC_GLSL
#define FRP_SHADING_MODELS_INC_GLSL

#define FRP_SHADING_MODEL_ID_MASK 0x0Fu
#define FRP_SELECTIVE_OUTPUT_MASK 0xF0u

#define FRP_SHADING_MODEL_UNLIT 0u
#define FRP_SHADING_MODEL_DEFAULT_LIT 1u

struct FRPBxDFContext {
	float NoV;
	float NoL;
	float VoL;
	float NoH;
	float VoH;
};

struct FRPBRDFData {
	vec3 albedo;
	vec3 f0;
	float roughness;
	float metallic;
	float ao;
	float alpha;
	float sss_strength;
	vec3 emission;
	vec3 energy_compensation;
};

struct FRPDirectLighting {
	vec3 diffuse;
	vec3 specular;
	vec3 transmission;
};

FRPBxDFContext frp_init_bxdf_context(vec3 N, vec3 V, vec3 L, float area_bias) {
	FRPBxDFContext context;
	context.NoL = min(area_bias + dot(N, L), 1.0);
	context.NoV = dot(N, V);
	context.VoL = dot(V, L);
	float inv_len_h = inversesqrt(max(2.0 + 2.0 * context.VoL, 1e-4));
	context.NoH = clamp(area_bias + (context.NoL + context.NoV) * inv_len_h, 0.0, 1.0);
	context.VoH = clamp(inv_len_h + inv_len_h * context.VoL, 0.0, 1.0);
	return context;
}

uint frp_decode_shading_model(float packed_alpha) {
	uint packed_byte = uint(round(clamp(packed_alpha, 0.0, 1.0) * 255.0));
	return packed_byte & FRP_SHADING_MODEL_ID_MASK;
}

float frp_encode_shading_model(uint shading_model_id, uint selective_output_mask) {
	uint packed_byte = (shading_model_id & FRP_SHADING_MODEL_ID_MASK) | (selective_output_mask & FRP_SELECTIVE_OUTPUT_MASK);
	return float(packed_byte) / 255.0;
}

uint frp_normalize_shading_model(uint id) {
	return id == FRP_SHADING_MODEL_UNLIT ? FRP_SHADING_MODEL_UNLIT : FRP_SHADING_MODEL_DEFAULT_LIT;
}

FRPBRDFData frp_make_brdf_data(vec3 albedo, float alpha, float ao, float roughness, float metallic, float material_specular, float sss_strength, vec3 emission, vec3 normal, vec3 view) {
	FRPBRDFData data;
	data.albedo = albedo;
	data.alpha = alpha;
	data.ao = ao;
	data.roughness = roughness;
	data.metallic = metallic;
	data.sss_strength = sss_strength;
	data.emission = emission;
	data.f0 = F0(metallic, material_specular, albedo);
	vec2 env_brdf = prefiltered_dfg(roughness, clamp(dot(normal, view), 0.0001, 1.0)).xy;
	data.energy_compensation = get_energy_compensation(data.f0, env_brdf.y);
	return data;
}

FRPDirectLighting frp_default_lit_bxdf(FRPBRDFData material, vec3 N, vec3 V, vec3 L, float area_bias, vec3 light_color, float attenuation, float light_specular) {
	FRPDirectLighting lighting;
	lighting.diffuse = vec3(0.0);
	lighting.specular = vec3(0.0);
	lighting.transmission = vec3(0.0);

	FRPBxDFContext context = frp_init_bxdf_context(N, V, L, area_bias);
	float NoL = max(context.NoL, 0.0);
	if (attenuation <= 0.0 || NoL <= 0.0) {
		return lighting;
	}

	// DefaultLit: Lambert diffuse + Schlick Fresnel / GGX microfacet specular.
	// This is the same BxDF family used by Unreal's DefaultLitBxDF, adapted to
	// FRP's existing D/V helpers and its light-size approximation.
	if (material.metallic < 1.0) {
		lighting.diffuse = light_color * (NoL * (1.0 / M_PI)) * attenuation;
	}

	if (material.roughness > 0.0) {
		float alpha_ggx = material.roughness * material.roughness;
		float D = D_GGX(context.NoH, alpha_ggx, N, normalize(V + L));
		float Vis = V_GGX(NoL, max(context.NoV, 1e-4), alpha_ggx);
		float f90 = clamp(dot(material.f0, vec3(50.0 * 0.33)), material.metallic, 1.0);
		vec3 F = material.f0 + (vec3(f90) - material.f0) * SchlickFresnel(context.VoH);
		lighting.specular = material.energy_compensation * NoL * D * F * Vis * light_color * attenuation * light_specular;
	}
	return lighting;
}

FRPDirectLighting frp_integrate_bxdf(uint shading_model_id, FRPBRDFData material, vec3 N, vec3 V, vec3 L, float area_bias, vec3 light_color, float attenuation, float light_specular) {
	switch (frp_normalize_shading_model(shading_model_id)) {
		case FRP_SHADING_MODEL_DEFAULT_LIT:
			return frp_default_lit_bxdf(material, N, V, L, area_bias, light_color, attenuation, light_specular);
		case FRP_SHADING_MODEL_UNLIT:
		default: {
			FRPDirectLighting lighting;
			lighting.diffuse = vec3(0.0);
			lighting.specular = vec3(0.0);
			lighting.transmission = vec3(0.0);
			return lighting;
		}
	}
}

vec3 frp_compose_bxdf(uint shading_model_id, FRPBRDFData material, vec3 ambient, vec3 diffuse, vec3 direct_specular, vec3 indirect_specular) {
	if (frp_normalize_shading_model(shading_model_id) == FRP_SHADING_MODEL_UNLIT) {
		return material.emission + material.albedo;
	}
	return material.emission + ambient + diffuse + direct_specular + indirect_specular;
}

#endif // FRP_SHADING_MODELS_INC_GLSL
