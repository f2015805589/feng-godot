# feng-godot 延迟渲染器（deferred）实施计划

- **基线**：`feng-godot` @ `f6ab5db28b`（Godot 4.7.3-rc）
- **日期**：2026-09-08
- **状态**：M0-M4 已完成并合入 `feng-godot`（提交 `a8202449cf` 起，deferred-renderer 分支已删除）
- **决策**：复制 Forward+（`RenderForwardClustered`）为独立渲染器 `deferred`，与 Forward+ 并存，通过 `rendering/renderer/rendering_method = "deferred"` 选择。不改 Forward+ 的任何行为。

---

## 0. 实施记录（2026-09-08）

| 里程碑 | 提交 | 内容 |
|--------|------|------|
| M0 | `a51e8a20e4` | 克隆 forward_clustered → deferred_clustered（改名 + 接入点 13 处） |
| M1 | `593b2b6694` | G-buffer 纹理/变体/强制 pass + 项目对话框 deferred 选项 |
| M2 | `52ce732ee0` | `deferred_lighting.glsl` 全屏光照 pass（替换不透明前向 pass） |
| M3+M4 | `21aa3542c0` | decal 进 G-buffer + 前向 fallback pass（`RENDER_LIST_OPAQUE_FALLBACK`） |

**M5 遗留（后续迭代）**：性能 profile（光源数 1/8/32/128 × 1080p/4K 帧时间表）、MSAA 下 G-buffer resolve 的视觉验证、多视图（XR）明确降级、velocity 并入 G-buffer pass、`doc/` 使用文档。

---

## 1. 目标与非目标

**目标**

- 新增 RD 渲染器 `deferred`：不透明几何走 G-buffer + 全屏延迟光照；透明物体保持前向渲染。
- 视觉输出与 Forward+ 对齐（允许细微的混合顺序/浮点噪声差异）。
- 保留 Forward+ 的既有能力：cluster 光照、阴影、SDFGI/VoxelGI、SSAO/SSIL/SSR、体积雾、天空、SSS、TAA/FSR2、tonemap、compositor effects。
- 与 Forward+ 零耦合：deferred 的所有改动都在自己的目录里。

**非目标（初期明确不做）**

- 不做 Mobile / Compatibility 渲染器的延迟版本。
- 不做多视图/XR（遇到时明确报错降级，后续里程碑再评估）。
- 不做移动端带宽优化（G-buffer 带宽对桌面 GPU 可接受，见 §7.7）。

---

## 2. 现状：已核实可直接复用的零件

| # | 零件 | 位置 | 复用方式 |
|---|------|------|----------|
| 1 | G-buffer 输出变体已存在（`MODE_RENDER_MATERIAL`，输出 albedo/normal/ORM/emission/depth 五张缓冲） | `shaders/forward_clustered/scene_forward_clustered.glsl:1041-1045`、`:3017-3025`；变体注册 `forward_clustered/scene_shader_forward_clustered.cpp:655` | 复制后改造成 `MODE_RENDER_GBUFFER`（合并 normal_roughness 编码 + 材质输出），材质编译系统几乎不动 |
| 2 | 光照函数库独立于前向流程（`light_compute` / `light_process_omni/spot/area` / `reflection_process`） | `shaders/scene_forward_lights_inc.glsl:101`、`:466`、`:767`、`:958`、`:1315` | 延迟光照 shader 直接 `#include`，零修改 |
| 3 | cluster 数据（omni/spot/area/decal/reflection 按 cluster 分桶）在 opaque 前构建完成 | `forward_clustered/render_forward_clustered.cpp:1517`（`_pre_opaque_render`）→ `bake_cluster()`；shader 侧查找模式 `scene_forward_clustered.glsl:1166`、`:1544` | G-buffer pass 之后照常执行，光照 pass 按像素查 cluster |
| 4 | GI 双路径：前向逐片元 GI（`sc_use_forward_gi`）与 **预渲染 GI 缓冲**（ambient/reflection buffer，binding 28/29）并存 | `scene_forward_clustered.glsl:1982-2036`（`USE_GI_BUFFERS` 路径）；`_pre_opaque_render` 里 `gi.process_gi` | 延迟光照 pass 走 **GI 缓冲路径**（`gi.process_gi` 已存在，照常调用） |
| 5 | 渲染 pass uniform set（set 1）已绑定延迟光照所需全部纹理：depth(24)/color(25)/normal_roughness(26)/ao(27)/ambient(28)/reflection(29)/sdfgi(30/31)/voxelgi(32)/体积雾(33)/ssil(34)/ssr(35/36) | `shaders/forward_clustered/scene_forward_clustered_inc.glsl:420-479`；C++ 侧 `_setup_render_pass_uniform_set`（`render_forward_clustered.cpp:3381`） | 复制后直接复用，光照 pass 挂同一套 uniform set |
| 6 | 全屏 pass 模板（全屏三角形 + 采样合并） | `shaders/effects/specular_merge.glsl`；C++ 调度 `effects/copy_effects.cpp:1441`（`merge_specular`） | `deferred_lighting.glsl` 照此模式写 |
| 7 | 基类 `RendererSceneRenderRD`：后处理/tonemap、compositor effects 调度、screen/depth 拷贝、debug draw、SDFGI 调试、render buffers 管理 | `renderer_rd/renderer_scene_render_rd.cpp/.h` | **不复制**，直接继承 |
| 8 | 复制式渲染器先例：`forward_mobile` 本身就是 `forward_clustered` 的复制改造（同文件布局、同类结构） | `renderer_rd/forward_mobile/`（161KB/31KB/47KB/13KB） | 证明该模式在此代码库可行 |

---

## 3. 架构与命名

### 3.1 目录与文件

```
servers/rendering/renderer_rd/
├── deferred_clustered/                    [新建]
│   ├── render_deferred_clustered.cpp      ← 复制 render_forward_clustered.cpp (238KB)
│   ├── render_deferred_clustered.h        ← 复制 render_forward_clustered.h   (37KB)
│   ├── scene_shader_deferred_clustered.cpp← 复制 scene_shader_forward_clustered.cpp (48KB)
│   ├── scene_shader_deferred_clustered.h  ← 复制 scene_shader_forward_clustered.h   (15KB)
│   └── SCsub                              ← 抄 forward_clustered/SCsub
└── shaders/
    └── deferred_clustered/                [新建]
        ├── scene_deferred_clustered.glsl  ← 复制 scene_forward_clustered.glsl (109KB)
        ├── scene_deferred_clustered_inc.glsl ← 复制 scene_forward_clustered_inc.glsl (14KB)
        ├── deferred_lighting.glsl         [新建] 延迟光照全屏 pass
        └── SCsub                          ← 抄 shaders/forward_clustered/SCsub
```

### 3.2 类名与标识对照

| 原 | 新 |
|----|----|
| `RenderForwardClustered` | `RenderDeferredClustered` |
| `SceneShaderForwardClustered` | `SceneShaderDeferredClustered` |
| `RenderBufferDataForwardClustered` | `RenderBufferDataDeferredClustered` |
| `GeometryInstanceForwardClustered` | `GeometryInstanceDeferredClustered` |
| `RB_SCOPE_FORWARD_CLUSTERED` (`"forward_clustered"`，`render_forward_clustered.h:49`) | `RB_SCOPE_DEFERRED_CLUSTERED` (`"deferred_clustered"`) |
| `RB_TEX_SPECULAR / NORMAL_ROUGHNESS / VOXEL_GI`（`:51-56`） | 同名保留，另加 `RB_TEX_GBUFFER_ALBEDO / GBUFFER_ORM / GBUFFER_EMISSION`（normal_roughness 沿用现名，兼容 SSAO 管线） |
| 渲染方法 `"forward_plus"` | `"deferred"` |

注：`scene_deferred_clustered.glsl` 构建时自动生成 `SceneDeferredClusteredShaderRD` 类（gen.h 机制，`glsl_builders.py`），`scene_shader_deferred_clustered.h:34` 的 include 路径相应修改。

### 3.3 共享层 vs 复制层

- **共享（不复制）**：`RendererSceneRenderRD` 基类；`shaders/` 根目录的函数库 include（`scene_forward_lights_inc.glsl`、`scene_forward_gi_inc.glsl`、`scene_forward_aa_inc.glsl`、`scene_forward_vertex_lights_inc.glsl`、`cluster_data_inc.glsl`、`decal_data_inc.glsl`、`scene_data_inc.glsl`、`half_inc.glsl`、`oct_inc.glsl`）；`effects/`、`environment/`、`storage_rd/` 全部。
- **复制（约 460KB）**：上表 6 个文件。其中与延迟无关的框架代码（阴影 pass、render list、pipeline 管理、材质编译）复制后原样保留——这正是解耦的代价与收益来源。

---

## 4. 帧流程设计

### 4.1 Forward+ 现状 → deferred 目标

```
Forward+（现状，render_forward_clustered.cpp:1704 _render_scene）:
  [可选]深度预pass(只depth 或 +normal_roughness 或 +voxelgi)   :2124
  → _pre_opaque_render(阴影/GI缓冲/SSAO/SSIL/SSR/cluster烘焙/体积雾) :2182
  → 不透明颜色pass(逐片元前向光照, 所有不透明surface)           :2223
  → 天空 → MSAA resolve → SSS/specular合并 → 透明pass → TAA/FSR2 → tonemap

deferred（目标）:
  G-buffer pass(必选, = 深度预pass扩展: depth+normal_roughness+albedo+orm+emission[+voxelgi])
  → _pre_opaque_render(不变: 阴影/GI缓冲/SSAO/SSIL/SSR/cluster烘焙/体积雾)
  → 延迟光照pass(全屏三角形: 读G-buffer+cluster+阴影图+GI缓冲+AO/SSIL/SSR, 输出color[或diffuse+specular])
  → 前向fallback pass(特殊材质的不透明surface)
  → 天空 → MSAA resolve → SSS/specular合并 → 透明pass(不变) → TAA/FSR2(不变) → tonemap(不变)
```

关键编排变化只有两处：**深度预pass 换成 G-buffer pass**（位置不变，`_pre_opaque_render` 依然能拿到 normal_roughness）；**不透明颜色pass 拆成「延迟光照pass + fallback pass」**。天空/透明/后处理链条原样保留。

### 4.2 G-buffer 布局

| 附件 | 纹理名（RB scope `deferred_clustered`） | 格式 | 内容 | 兼容性说明 |
|------|------|------|------|-----------|
| depth | （现有 RB 深度纹理，不新建） | `D32_SFLOAT` | 深度 | 复用现有 |
| 0 | `normal_roughness` | `RGBA8_UNORM` | RGB: `encode24(normal)*0.5+0.5`；A: roughness（沿用现有 dynamic/static 反码编码，`scene_forward_clustered.glsl:3025-3037`） | **与现有 normal_roughness 缓冲逐字节同布局** → SSAO/SSIL/SSR/`gi.process_gi` 零改动（`scene_forward_clustered_inc.glsl:466` `normal_roughness_compatibility` 直接可用） |
| 1 | `gbuffer_albedo` | `RGBA8_UNORM` | RGB: albedo（线性空间）；A: alpha（距离淡出/alpha scissor 后的最终不透明度） | 对应 `albedo_output_buffer` |
| 2 | `gbuffer_orm` | `RGBA8_UNORM` | R: ao；G: roughness；B: metallic；A: sss_strength | 对应 `orm_output_buffer`，SSS 走 specular 分离路径 |
| 3 | `gbuffer_emission` | `RGBA16_SFLOAT` | RGB: HDR emission；A: 标记位（bit0: `fog_disabled`，bit1: 预留 fallback 标记） | 对应 `emission_output_buffer`，A 通道复用做逐像素标记 |
| 4（可选） | `voxel_gi` | `RG8_UINT` | VoxelGI 索引 | 沿用现有，仅 VoxelGI 场景分配 |

- velocity 缓冲（RG16F）沿用现有独立纹理；M4 阶段把它挪进 G-buffer pass 一并写入（消除单独的 motion pass）。
- 新增显存 @1080p：4+4+4+8 ≈ **20 B/px ≈ 41 MB**（+MSAA 翻倍）。可接受。

### 4.3 延迟光照 pass（`deferred_lighting.glsl`）

- **形式**：全屏三角形（照抄 `specular_merge.glsl` 的 vertex），fragment 每像素执行。
- **输入**：set 0（base uniform set：光源 buffer、decal atlas、dfg/LTC LUT——`render_forward_clustered.cpp:3188` 的绑定直接复用）+ set 1（render pass uniform set：G-buffer 纹理、cluster buffer、阴影图、radiance、反射 atlas、GI 缓冲、AO/SSIL/SSR、体积雾——`:3381` 的绑定直接复用）。G-buffer 纹理追加为 set 1 的新 binding。
- **重建**：`texture(depth)` → NDC → `inv_projection * ndc` 得视空间顶点 → `inv_view_matrix` 得世界位置；view 向量、法线解码（`normal_roughness_compatibility`）。
- **光照循环**：从 `scene_forward_clustered.glsl:2300-2880` 移植三段循环——方向光（含 PSSM 软阴影）、cluster omni/spot/area（含 shadow atlas 采样与 projector）；反射探针（`:2038` 一段）；GI 缓冲 + SSAO/SSIL/SSR 应用（`:1982-2216` 一段）；能量补偿 `get_energy_compensation`。所有 BRDF 计算通过 `#include "../scene_forward_lights_inc.glsl"` 复用。
- **天空像素**：`depth == 1.0` 直接 discard（天空由后续天空 pass 绘制，位置不变）。
- **雾**：depth fog + 体积雾在光照 pass 末尾应用（读 emission.a 的 `fog_disabled` 标记位）。
- **输出**：默认写 color；SSS/SSR 分离 specular 场景输出 diffuse+specular 双缓冲，下游 `_process_sss` + `merge_specular`（`render_forward_clustered.cpp:2364` 一带）原样工作。
- **MSAA**：初期光照 pass 前先 resolve（扩展 `resolve_effects->resolve_gi` 模式到全部 G-buffer 附件）；若 resolve 成本高，M4 评估强制关闭 MSAA 并告警。

### 4.4 材质 fallback 机制

**走前向 fallback 的材质**（光照依赖 G-buffer 无法表达的逐材质输入）：

| 特性 | 原因 |
|------|------|
| `unshaded` | 无需光照，直接输出 |
| `vertex_lighting` | 光照在顶点阶段完成 |
| lightmap / lightmap capture / shadowmask | 静态光照跳过逻辑依赖实例数据 |
| `clearcoat` / `anisotropy` | 需要额外 G-buffer 通道（tangent/binormal），初期不做 |
| `rim` / `backlight` / `transmittance_color` 等非默认 LIGHT 参数 | 同上 |
| 写 `SPECULAR`（非默认 0.5） | 无通道存放 |
| `fog_disabled` | 标记位方案之外的保守项（或走 emission.a bit0，M4 定） |
| 读 `SCREEN_TEXTURE` / `DEPTH_TEXTURE` 的材质 | 需要在最终光照后采样屏幕 |

**机制**（全部复用现有设施）：

- 检测：`SceneShaderDeferredClustered::ShaderData` 已通过 `actions.render_mode_flags` 等记录 `unshaded`、`uses_*` 标志（`scene_shader_forward_clustered.cpp:120-131`）；补少量检测（SPECULAR 写入、SCREEN_TEXTURE 已有 `uses_screen_texture`）。
- 分流：`_fill_render_list`（`render_forward_clustered.cpp:921`）里给 surface 设置 `color_pass_inclusion_mask` / 新 render list（`RENDER_LIST_OPAQUE_FALLBACK`），G-buffer pass 排除、fallback pass 包含。
- 执行：fallback pass = 现有 `PASS_MODE_COLOR` 前向 pass，插在延迟光照 pass 之后、天空之前（它需要读已光照的屏幕时也成立，因为 screen texture 拷贝在其后）。

---

## 5. 里程碑

### M0 — 克隆与接入（1-2 天）

**任务**

1. 按 §3.1 复制 6 个文件并按 §3.2 改名（纯文本替换 + 手工核对，不改任何逻辑）。
2. 接入渲染器选择与构建（见 §6 清单）。
3. 新建分支 `deferred-renderer` 开发（`feng-godot` 分支保持与上游同步的干净基线）。

**验收**

- `scons` 编译通过；`shaders/deferred_clustered/` 的 gen.h 正常生成。
- `godot --rendering-method deferred` 启动编辑器与测试项目，无报错。
- 同一场景 `forward_plus` vs `deferred` 截图逐像素一致（此阶段 deferred 就是 Forward+ 的完整克隆）。

### M1 — G-buffer pass（3-5 天）

**任务**

1. `RenderBufferDataDeferredClustered`：新增 `gbuffer_albedo/orm/emission` 纹理（`create_texture` 模式照抄 `ensure_specular()`，`render_forward_clustered.cpp:54-88`）与 `get_gbuffer_fb()`（照抄 `get_depth_fb(DEPTH_FB_ROUGHNESS_VOXELGI)` 的多附件缓存模式，`:215-233`）。
2. 复制版 glsl：新增 `MODE_RENDER_GBUFFER`（合并 `MODE_RENDER_NORMAL_ROUGHNESS` 的编码 + `MODE_RENDER_MATERIAL` 的材质输出，去掉冗余的 depth 颜色附件）；`PassMode` 加 `PASS_MODE_GBUFFER`；`_render_list_template` 两处 switch（`render_forward_clustered.cpp:435`、`:629`）加 case；shader 变体注册（`scene_shader_forward_clustered.cpp:655` 附近）加对应 version。
3. `_render_scene`：延迟模式下强制走 G-buffer pass（替代可选深度预pass），深度预pass 三分支逻辑简化。

**验收**

- debug 输出：albedo/normal/roughness/metallic/ao/emission 六个通道目视正确（临时用 debug draw 或截图工具）。
- SSAO/SSIL/SSR/VoxelGI 在 G-buffer 路径下结果与 Forward+ 一致（normal_roughness 布局未变）。
- 此阶段不透明颜色 pass 仍为前向（输出不变），确保无回归。

### M2 — 延迟光照 pass（5-7 天）

**任务**

1. 写 `deferred_lighting.glsl`（§4.3）；C++ 侧光照 pass 调度（uniform set 复用 + 新 G-buffer binding + framebuffer 为 color[+specular]）。
2. `_render_scene`：不透明链路改为 G-buffer → `_pre_opaque_render` → 延迟光照；`RENDER_LIST_OPAQUE` 中「标准 PBR」surface 不再进前向颜色 pass。
3. 反射探针烘焙、lightmap bake、SDFGI voxelization、材质预览（`_render_material`）**保持前向路径不动**（烘焙类渲染不需要延迟化）。

**验收**

- 单方向光 + 8 盏 omni/spot 的测试场景，延迟 vs 前向光照结果目视一致（允许浮点噪声）。
- `VIEWPORT_DEBUG_DRAW_LIGHTING`（仅光照）模式下两渲染器一致。
- 光源数 1→32 场景帧时间对比开始记录。

### M3 — 全特性对齐（5-10 天）

**任务**：GI 缓冲路径（SDFGI/VoxelGI）、反射探针、directional PSSM 软阴影与 contact shadow、projector、depth fog + 体积雾、SSS（specular 分离 + `merge_specular`）、SSR/SSAO/SSIL 应用、能量补偿、`emissive_exposure_normalization`、decal 在 G-buffer pass 内应用（把 `scene_forward_clustered.glsl:1552` 的 decal 块对 `MODE_RENDER_GBUFFER` 开放——decal 改 albedo/normal/orm/emission，天然属于 G-buffer 阶段）。

**验收**：全特性测试场景（多光源 + SDFGI + 体积雾 + 反射 + decal + SSS）延迟 vs 前向对齐；光源数 128/256 的帧时间曲线优于前向（延迟的核心收益验证点）。

### M4 — fallback / 透明 / MSAA / 多视图（5-10 天）

**任务**：§4.4 fallback 清单落地与逐项视觉验证；透明 pass 回归；MSAA resolve 方案或禁用告警；多视图遇到时明确 `ERR_FAIL` 降级；velocity 并入 G-buffer pass（可选）。

**验收**：fallback 材质清单逐项无视觉回归；MSAA 4x 下延迟输出正确；编辑器全功能可用（材质球预览、烘焙、探针）。

### M5 — 清理与性能（3-5 天）

**任务**：删除/关闭复制代码中的死路径（如延迟模式下不再需要的 `sc_use_forward_gi` 逐片元 GI 路径可保留给 fallback）；性能 profile（G-buffer 带宽、光照 pass 占用）；文档（`doc/` 或本文件更新使用说明）；`renderer_viewport.cpp` 等 feature gate 复查。

**验收**：性能报告（1/8/32/128 光源 × 1080p/4K）；使用文档；分支合并回 `feng-godot`。

**总计：全职约 4-6 周。**

---

## 6. M0 接入点改动清单（已核实到行号）

| 文件 | 位置 | 改动 |
|------|------|------|
| `servers/rendering/renderer_rd/renderer_compositor_rd.cpp` | `:373-386` | 渲染器选择加分支：`rendering_method == "deferred"` → `memnew(RendererSceneRenderImplementation::RenderDeferredClustered())`；文件头加 include（`:38-39` 一带） |
| `main/main.cpp` | `:2491` | `renderer_hints = "forward_plus,mobile"` → `"forward_plus,mobile,deferred"`（`gl_compatibility` 追加逻辑不动） |
| `main/main.cpp` | `:2513-2516` | 合法渲染方法校验名单加 `"deferred"` |
| `main/main.cpp` | `:2600` | `if (rendering_method == "forward_plus" \|\| rendering_method == "mobile")`（RD 驱动 vulkan/d3d12/metal）加 `\|\| rendering_method == "deferred"` |
| `servers/rendering/renderer_rd/SCsub` | 尾部 | 加 `SConscript("deferred_clustered/SCsub")` |
| 新 `deferred_clustered/SCsub` | — | 抄 `forward_clustered/SCsub`（`env.add_source_files(env.servers_sources, "*.cpp")`） |
| 新 `shaders/deferred_clustered/SCsub` | — | 抄 `shaders/forward_clustered/SCsub`（RD_GLSL builder 自动 glob 生成 gen.h；`*_inc.glsl` 视为 include 依赖） |
| `servers/rendering/renderer_viewport.cpp` | `:1026`、`:1449` | FSR1 与 TAA 的 `!= "forward_plus"` 检查加 deferred（延迟渲染器同样支持） |
| 可选：`editor/project_manager/project_dialog.cpp` | `:500`、`:1132` 一带 | 新建项目对话框加 deferred 选项按钮（不阻塞 M0，命令行 `--rendering-method deferred` 已可用） |

注：`scene/resources/environment.cpp`、`scene/3d/*.cpp`、export 插件里的 `"forward_plus"` 字符串是特性提示/平台校验，deferred 桌面专用，M5 统一复查。

---

## 7. 风险与应对

| # | 风险 | 等级 | 应对 |
|---|------|------|------|
| 1 | **上游同步税**（最大长期成本）：Godot 后续版本对 Forward+ 的修复/新特性需手动移植到复制文件 | 高 | 所有 defer 特有改动集中在 `_render_scene` 编排、`MODE_RENDER_GBUFFER`、`deferred_lighting.glsl` 三处，其余保持与上游逐字节接近；定期 `git diff upstream` 审计；大版本时可「重新复制 + 重放差异」 |
| 2 | 材质 shader 双份维护（109KB glsl 复制） | 中 | 共享的函数库 include（lights/gi/aa 等）不复制，实际分叉面只有主 glsl 与 `_inc`；材质变体列表与上游保持同名同序 |
| 3 | 材质兼容面广：render_mode 组合 × G-buffer 输出的正确性 | 中 | M4 的 fallback 清单保守起步（宁可多回退前向，不冒视觉错误风险）；用 `editor_build_profile` + 测试矩阵逐项验证 |
| 4 | MSAA 与 G-buffer | 中 | M2 先 resolve 方案；不行则延迟模式下告警禁用 MSAA（`_render_scene` 里 `use_msaa = false` + `WARN_PRINT_ONCE`） |
| 5 | 构建系统（gen.h 生成、SCsub、shader 缓存失效） | 低 | M0 即验证完整构建 + 清理重建；shader cache 目录会自动失效重编 |
| 6 | 多视图/XR | 低 | 初期 `ERR_FAIL_COND_MSG(view_count > 1, ...)` 明确不支持 |
| 7 | 带宽/显存：G-buffer ~20 B/px 新增 | 低 | 桌面 GPU 可接受；后续可选 emission 降 R11G11B10 或 albedo/orm 合并通道 |
| 8 | 反射探针/烘焙路径遗漏延迟化改造引发不一致 | 低 | 设计上烘焙类渲染**保持前向**（M2 任务 3 明确），只在主视口走延迟 |

---

## 8. 验证方法

- **M0**：`--rendering-method deferred` 启动 + 截图逐像素 diff（与 forward_plus）。
- **M2/M3**：测试场景集——①单方向光空场景 ②8 omni/spot 室内 ③128 光源压力场 ④SDFGI 室外 ⑤VoxelGI + 体积雾 ⑥decal + SSS + projector + 软阴影——每个场景两渲染器并排截图对比。
- **G-buffer 检查**：临时 debug draw（或截图工具）查看各通道；normal 通道应与 `VIEWPORT_DEBUG_DRAW_NORMAL_BUFFER` 一致。
- **性能**：固定场景下光源数 1/8/32/128 × 1080p/4K 帧时间表，验证「光源数扩展时光照成本与像素数而非几何复杂度成正比」的延迟收益。

---

## 9. 开发顺序建议

1. 全程在 `deferred-renderer` 分支进行，`feng-godot` 保持可随时 merge 上游。
2. M0 完成即提交一次（纯克隆，diff 清晰可审计）；每个里程碑独立提交，M1/M2 的中间态保证引擎始终可跑。
3. 开发期 Forward+ 与 deferred 并存切换（改 project setting 即可）是最有效的对比调试手段——**复制代码里不要急着删前向路径**，M5 再清理。
