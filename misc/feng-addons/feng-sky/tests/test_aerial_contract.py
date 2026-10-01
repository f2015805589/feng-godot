"""Structural guards for the shared atmosphere handoff and renderer ownership."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[4]

class AerialContract(unittest.TestCase):
    def read(self, path):
        return (ROOT / path).read_text()

    def test_transport_helpers_identical(self):
        self.assertEqual(self.read('servers/rendering/renderer_rd/shaders/frp_clustered/atmosphere_inc.glsl'),
                         self.read('misc/feng-addons/feng-render-pipeline/library/height-fog/atmosphere_inc.glslinc'))

    def test_prepare_precedes_pipeline_execution(self):
        source = self.read('servers/rendering/renderer_rd/frp_clustered/render_frp_clustered.cpp')
        self.assertLess(source.index('object->callv("_frp_prepare"'), source.index('callback_object->callv("_frp_execute"'))
        self.assertIn('light == p_context->get_atmosphere_light_rid(slot)', source)
        self.assertNotIn('light_set_color(', source)
        self.assertNotIn('light_set_param(', source)

    def test_opaque_and_transparent_transport(self):
        opaque = self.read('misc/feng-addons/feng-render-pipeline/library/height-fog/height_fog.glsl')
        forward = self.read('servers/rendering/renderer_rd/shaders/frp_clustered/scene_frp_clustered.glsl')
        self.assertIn('depth > 0.0 && params.atmosphere_parameters[12].z', opaque)
        self.assertIn('frp_atmo_aerial(mat3(inv_view_matrix) * (vertex - eye_offset)', forward)
        self.assertIn('frag_color.rgb * atmosphere_transmission + atmosphere_radiance', forward)

    def test_volume_wrappers_and_linear_lut_sampler(self):
        for path in [
            'misc/feng-addons/feng-render-pipeline/pipeline/view_pass.gd',
            'misc/feng-addons/feng-render-pipeline/passes/builtin_pass.gd',
            'misc/feng-addons/feng-render-pipeline/passes/native/native_pass.gd',
        ]:
            self.assertIn('func _frp_prepare(', self.read(path))
        fog = self.read('misc/feng-addons/feng-render-pipeline/passes/height_fog_pass.gd')
        self.assertIn('state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR', fog)
        self.assertIn('uniform.add_id(_atmosphere_sampler)', fog)
        self.assertIn('set_base(light);', self.read('scene/3d/light_3d.cpp'))

    def test_vertex_lighting_has_ubo_only_transport(self):
        shader = self.read('servers/rendering/renderer_rd/shaders/frp_clustered/scene_frp_clustered.glsl')
        vertex = shader.split('#[fragment]')[0]
        self.assertIn('#define ATMO_DIRECT_ONLY', vertex)
        self.assertIn('vec3 frp_atmospheric_light_factor(', vertex)
        self.assertIn('frp_atmospheric_light_factor(0u,', vertex)
        helper = self.read('servers/rendering/renderer_rd/shaders/frp_clustered/atmosphere_inc.glsl')
        self.assertIn('#ifndef ATMO_DIRECT_ONLY', helper)

    def test_native_packet_is_bounded(self):
        context = self.read('servers/rendering/renderer_rd/frp_clustered/frp_pass_context.cpp')
        self.assertIn('p_parameters.size() != 64', context)
        self.assertIn('!Math::is_finite(value)', context)

if __name__ == '__main__':
    unittest.main()
