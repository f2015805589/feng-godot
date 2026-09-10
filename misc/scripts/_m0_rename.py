#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""M0 收尾：deferred -> frp 字符串替换（仅渲染器相关标识符，UTF-8 安全）。"""
import io
import sys

ROOT = r"d:\godot\feng-godot"

# (相对路径, [(old, new), ...])
PLAN = [
    (r"main\main.cpp", [
        ('renderer_hints = "forward_plus,mobile,deferred";', 'renderer_hints = "forward_plus,mobile,frp";'),
        ('rendering_method != "deferred" &&', 'rendering_method != "frp" &&'),
        ('rendering_method == "forward_plus" || rendering_method == "mobile" || rendering_method == "deferred"',
         'rendering_method == "forward_plus" || rendering_method == "mobile" || rendering_method == "frp"'),
    ]),
    (r"servers\rendering\renderer_rd\renderer_compositor_rd.cpp", [
        ('rendering_method == "forward_plus" || rendering_method == "deferred"',
         'rendering_method == "forward_plus" || rendering_method == "frp"'),
        ('} else if (rendering_method == "deferred") {', '} else if (rendering_method == "frp") {'),
    ]),
    (r"servers\rendering\storage\environment_storage.cpp", [
        ('!= "forward_plus" && OS::get_singleton()->get_current_rendering_method() != "deferred"',
         '!= "forward_plus" && OS::get_singleton()->get_current_rendering_method() != "frp"'),
    ]),
    (r"servers\rendering\shader_preprocessor.cpp", [
        ('rendering_method == "forward_plus" || rendering_method == "deferred"',
         'rendering_method == "forward_plus" || rendering_method == "frp"'),
    ]),
    (r"servers\rendering\shader_language.cpp", [
        ('!= "forward_plus" && OS::get_singleton()->get_current_rendering_method() != "deferred"',
         '!= "forward_plus" && OS::get_singleton()->get_current_rendering_method() != "frp"'),
    ]),
    (r"servers\rendering\rendering_device.cpp", [
        ('get_current_rendering_method() == "deferred"', 'get_current_rendering_method() == "frp"'),
        ('rendering_method = "Deferred";', 'rendering_method = "FRP";'),
    ]),
    (r"servers\rendering\renderer_viewport.cpp", [
        ('rendering_method != "forward_plus" && rendering_method != "deferred"',
         'rendering_method != "forward_plus" && rendering_method != "frp"'),
        ('!= "forward_plus" && OS::get_singleton()->get_current_rendering_method() != "deferred"',
         '!= "forward_plus" && OS::get_singleton()->get_current_rendering_method() != "frp"'),
    ]),
    (r"core\config\project_settings.cpp", [
        ('features.append("Deferred");', 'features.append("FRP");'),
    ]),
    (r"editor\project_manager\project_dialog.cpp", [
        ('renderer_type == "deferred"', 'renderer_type == "frp"'),
        ('TTR("Deferred lighting for opaque geometry.")', 'TTR("FRP lighting for opaque geometry.")'),
        ('project_features.push_back("Deferred");', 'project_features.push_back("FRP");'),
        ('rs_button->set_text(TTRC("Deferred"));', 'rs_button->set_text(TTRC("FRP"));'),
        ('rs_button->set_meta(SNAME("rendering_method"), "deferred");', 'rs_button->set_meta(SNAME("rendering_method"), "frp");'),
        ('default_renderer_type == "deferred"', 'default_renderer_type == "frp"'),
    ]),
    (r"misc\scripts\test_frp_pipeline.py", [
        ('renderer/rendering_method="deferred"', 'renderer/rendering_method="frp"'),
        ('"--rendering-method", "deferred"', '"--rendering-method", "frp"'),
    ]),
    (r"misc\feng-addons\feng-renderdoc-capture\tests\fixture\project.godot", [
        ('renderer/rendering_method="deferred"', 'renderer/rendering_method="frp"'),
    ]),
    (r"doc\classes\CompositorEffect.xml", [
        ('Deferred only:', 'FRP only:'),
    ]),
    (r"doc\classes\RenderingServer.xml", [
        ('Deferred only:', 'FRP only:'),
    ]),
    (r"misc\feng-addons\feng-render-pipeline\plugin.cfg", [
        ('description="Resource-based compute passes for the Deferred compositor."',
         'description="Resource-based compute passes for the FRP compositor."'),
    ]),
    (r"misc\feng-addons\feng-render-pipeline\README.md", [
        ('Deferred compositor', 'FRP compositor'),
        ('GBuffer 效果使用 Deferred: Post GBuffer / Pre Lighting', 'GBuffer 效果使用 FRP: Post GBuffer / Pre Lighting'),
    ]),
    (r"doc\feng-terrain-frp.md", [
        ('# 地形数组与 Deferred Pass', '# 地形数组与 FRP Pass'),
        ('## 自定义 Deferred Pass', '## 自定义 FRP Pass'),
        ('| Deferred: Pre GBuffer |', '| FRP: Pre GBuffer |'),
        ('| Deferred: Post GBuffer |', '| FRP: Post GBuffer |'),
        ('| Deferred: Pre Lighting |', '| FRP: Pre Lighting |'),
        ('| Deferred Lighting |', '| FRP Lighting |'),
        ('| Deferred: Post Lighting |', '| FRP: Post Lighting |'),
        ('新增阶段仅在 Deferred 中调用', '新增阶段仅在 FRP 中调用'),
    ]),
    (r"misc\frp-renderer-plan.md", [
        ('deferred', 'frp'),
        ('Deferred', 'FRP'),
    ]),
]

total = 0
for rel, pairs in PLAN:
    path = ROOT + "\\" + rel
    with io.open(path, "r", encoding="utf-8") as f:
        text = f.read()
    count = 0
    for old, new in pairs:
        n = text.count(old)
        if n:
            text = text.replace(old, new)
            count += n
            print("%s: %d x %r" % (rel, n, old[:60]))
    if count:
        with io.open(path, "w", encoding="utf-8", newline="") as f:
            f.write(text)
        total += count
print("TOTAL replacements:", total)
