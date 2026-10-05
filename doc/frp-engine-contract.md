# FRP 引擎契约

本文列出插件使用的引擎接口、帧数据布局和升级 Godot 时要检查的集成点。
管线使用方式见 [插件说明](../misc/feng-addons/feng-render-pipeline/README.md)，
插件内部职责见 [插件架构](frp-addon-architecture.md)。

## 所有权

引擎拥有渲染原语、原生 ID/依赖表、帧缓冲与底层执行。
插件拥有 Pass 实现选择、资源顺序、参数声明、Volume 混合、库同步和编辑器界面。
新增效果先使用现有 Core 原语；新增底层能力或修复引擎缺陷时，再扩展最小接口。

`servers/rendering/frp_pipeline_spec.h` 定义原生 Pass、Operation 和依赖。
`RenderingServer.get_frp_pipeline_spec()` 将它交给插件 `pipeline/native_spec.gd`。
ID 是稳定身份；默认顺序由 `DEFAULT_PASS_ORDER` 定义，显式资源按自身顺序执行。
默认库条目和启用状态由插件的 `library_manager.gd` 与 `renderer.gd` 定义。

引擎保留原生 Pass 调度和无插件 fallback；插件默认实现通过同一套原语执行这些工作。
原生 SSAO、SSIL、SSR、SDFGI、VoxelGI 和调试几何不在 FRP 的渲染范围内。
Magic GI 等插件效果使用独立数据路径。

## 脚本可见的 Core

`FRPPassContext` 位于 `servers/rendering/renderer_rd/frp_clustered/frp_pass_context.{h,cpp}`。
渲染器为当前帧创建上下文，脚本在渲染线程通过 `_frp_execute(ctx)` 使用它。

| 类别 | 当前绑定的方法 |
|---|---|
| 帧状态 | `get_render_data()`、`get_render_scene_buffers()`、`get_view_count()`、`get_internal_size()` |
| Pass 查询 | `get_pass_name(id)`、`is_valid_pass_id(id)`、`get_pass_parameters(key)` |
| 绘制 | `draw_gbuffer()`、`draw_motion_vectors()`、`draw_deferred_lighting()`、`draw_sky()`、`draw_opaque_fallback()`、`draw_transparent()` |
| 准备与 resolve | `precompute_shadows()`、`execute_virtual_texture_updates()`、`prepare_lighting()`、`merge_subsurface_and_specular()`、`resolve_opaque()`、`resolve_sky()`、`resolve_final()`、`copy_screen_and_depth()`、`copy_history()` |
| 时域与后处理 | `temporal_aa_and_upscale()`、`prepare_bloom()`、`post_process()`、`tonemap()`、`tonemap_deferred()`、`present(texture)`、`post_process_and_tonemap()` |
| 组合执行 | `run_pass(id)`、`stage_compositor_effects(type)` |
| 曝光 | `get_pre_exposure(view)`、`get_scene_exposure_normalization()`、`set_next_pre_exposure(view, exposure)`、`request_next_pre_exposure(buffer, view, offset_bytes)`、`set_tonemap_exposure_texture(texture)` |
| 雾与大气 | `set_height_fog_parameters(parameters)`、`get_height_fog_parameters()`、`set_atmosphere_parameters(parameters, light, secondary_light, optical_texture, multiple_texture)`、`get_atmosphere_parameters()` |
| GI 输出 | `_frp_prepare(ctx)` 可调用 `request_sky_light_diffuse()`；在 `draw_deferred_lighting()` 后从 `ctx.get_render_scene_buffers().get_texture("frp_clustered", "sky_light_diffuse")` 读取本帧结果 |

`get_scene_exposure_normalization()` 返回 FRP 当前帧的场景曝光归一化，不含 pre-exposure；FRP eye adaptation 接管曝光时使用 1，再除以 render buffer 的 luminance multiplier。SkyLight diffuse 仅在当前帧显式请求时分配或写入。输出是已经应用全局环境 diffuse、local reflection probe 覆盖权重、材质 AO/albedo/metallic 和 pre-exposure 的屏幕贡献；不含局部 probe、直接光、间接反射或 emission。没有 ready SkyLight 时该纹理为零，可供 GI 继续处理直接发光体和太阳光照。

绘制原语调用与引擎原生 Pass 相同的 Operation。它们目前使用固定签名；逐 Pass 配置
通过 `get_pass_parameters(key)` 读取。通用 `options` 字典、任意 render-list 提交和
framebuffer 构造 API 尚未提供。

`draw_motion_vectors()` 保留操作入口；GBuffer 的几何绘制已同时写入速度附件。
`precompute_shadows()` 绘制阴影贴图；灯光/Cluster、decal 与体积雾由 `prepare_lighting()` 准备。

`tonemap()` 完成色调映射和输出。`tonemap_deferred()` 将结果留在中间纹理，供 LDR 效果
处理后调用 `present(texture)`；空名称呈现引擎 tonemap 结果，命名纹理来自管线 scope。

接口变更须同步 ClassDB 绑定、插件调用和契约测试，已有 ID、名字与参数语义保持兼容。

## 调度与参数

`RenderingServer.compositor_set_frp_pipeline(compositor, pipeline, names, provided, parameters)`
接收五部分：

- compositor RID
- 按执行顺序排列的 token；非负值为原生 ID，负值 `-(effect_index + 1)` 引用 compositor effect
- 与 token 对应的显示名称
- 脚本提供的原生 ID 集合
- 按原生整数 ID 或自定义稳定字符串键索引的参数字典

插件 Texture Manager 占 effect index 0。关闭的脚本 Pass 保留效果槽，执行由其 enabled
状态控制；这保持 token 与 effects 数组对应。原生条目带 implementation 时使用脚本 token
并声明 provided ID，清空 implementation 时使用原生 token。

必需工作为 ID `0,1,2,3,7`，可由原生条目或声明接管的脚本提供。
provided 也参与帧特性查询：例如 ID 6 控制 TAA 和 jitter。无显式调度时使用原生默认顺序。
插件先校验顺序、身份、必需工作和纹理依赖；无效候选不上传，保留上一次有效调度并暂停
不安全的自定义效果。引擎还会校验接收到的调度。

参数优先级为 Pass 声明值、条目覆盖、Volume 结果。引擎传递最终快照，插件负责字段权限、
别名和混合。`RendererViewport` 读取 ID 6 的 `jitter_phases`，范围 1–64、默认 16。
只有当前渲染方法为 `frp` 且视口未由时序上采样器拥有 jitter 时，FRP 调度才接管 jitter。

## 缓冲与时域数据

`frp_clustered` scope 提供：

| 纹理 | 数据 |
|---|---|
| `normal_roughness` | 10:10:10 法线，alpha 保存动态标记 |
| `gbuffer_albedo` | 材质 albedo |
| `gbuffer_orm` | AO、roughness、metallic；alpha 低 4 位为 ShadingModelID，高 4 位预留 selective-output flags |
| `gbuffer_emission` | emission，alpha 为 specular |

ORM 为 RGBA8；ShadingModelID 0 表示 Unlit，1 表示 DefaultLit，未知非零值归一化为
DefaultLit。当前实现默认 BxDF。像素 shading model 与 CPU render-list 的材质排序 ID 独立。

普通 GBuffer 有四个颜色附件，需要运动矢量时在 location 4 增加 velocity。
深度、场景色与 velocity 通过 RenderSceneBuffersRD 的相应接口读取。
framebuffer 变体与 MSAA resolve 由引擎管理，插件声明附件需求后使用 Core 原语。

未被 GBuffer 绘制的像素保留速度标记 `(-1,-1)`。FRP 在 TAA 前、MSAA resolve 后用
`frp_velocity_fill.glsl` 按深度补全这些像素，保留已有逐物体速度。
TAA 历史按当前/历史 pre-exposure 比例重标定；关闭 TAA、切换 compositor 或重建缓冲时清理历史。
曝光读回也绑定视口缓冲生命周期，旧读回不能写入新状态。立体视图共用 view 0 的场景 pre-exposure。

共享 TAA shader 的邻域速度选择仍使用最小深度；在 reverse-Z 下这会选择较远样本，
影响深度边缘的自适应历史裁剪。修改此选择规则需要同时验证 FRP 与 forward_plus。

## 雾与大气的帧内交接

显式调度执行前，引擎对启用且参与调度的脚本调用一次可选 `_frp_prepare(ctx)`。
该钩子用于元数据准备；绘制和 dispatch 留在原位置的 `_frp_execute(ctx)`。
ViewPass、BuiltinPass 和启用的 native overlay 转发准备钩子。
Height Fog 因此可在 Sky 后绘制，同时在 Deferred Lighting 前提交大气数据。

高度雾快照为 28 个 float；空数组清除。大气快照为恰好 64 个有限 float、两个基础灯光 RID
和两个 RD 纹理 RID；空数组清除，非法大气数组被拒绝并保持清空状态。
世界/render target 匹配由插件完成，上下文只持有当前帧数据。

大气的 16 个 vec4 布局：

| 索引 | 内容 |
|---|---|
| 0 | 相机相对行星中心位置与地表半径 |
| 1–3 | Rayleigh、Mie scattering、Mie extinction、密度高度和各向异性 |
| 4–6 | 其他吸收、大气厚度、两层吸收项、多次散射倍率、AP 起始/距离倍率 |
| 7 | 天空/AP RGB 亮度倍率和视线采样数 |
| 8–11 | 两盏光的世界方向、辐照度、RGB 与最小太阳高度 |
| 12 | LUT 有效与启用标志 |
| 13–15 | 保留为零 |

数据中的距离为 km、系数为 km⁻¹；世界空间边界使用米。

- 原生光照按基础灯光 RID 匹配 GPU 槽位，仅对该光的 BRDF 入射项应用 RGB 透射率
- Height Fog 在 Sky 后为有深度的 opaque 像素合成 AP；天空的大气积分由天空路径负责
- 前向 fallback 和透明材质按自己的片元位置合成 AP，再应用高度雾
- `affect_height_fog=false` 停止天空对高度雾的可选贡献，独立快照仍可供直接光与 AP 使用
- 光学/多次散射纹理按世界持有，发布后保持只读；缺失光学 LUT 时使用有界直接积分
- 原生 `atmosphere_inc.glsl` 与插件 `atmosphere_inc.glslinc` 的公式保持一致

第一盏大气光参与多次散射；第二盏参与单次散射与直接透射。当前范围不含大气内地形/云阴影
和折射；无匹配快照的反射探针不注入 AP。实现与 UE 的参数概念对应，像素结果不承诺一致。

## 升级时的集成检查

FRP 自有实现位于 `servers/rendering/frp_pipeline_spec.h`、
`servers/rendering/renderer_rd/frp_clustered/` 和 `servers/rendering/renderer_rd/shaders/frp_clustered/`。
共享代码按职责检查以下触点，具体补丁以目标上游版本的 diff 为准：

| 触点 | 保留的合同 |
|---|---|
| `servers/register_server_types.cpp`、`renderer_compositor_rd.cpp` | FRPPassContext 注册与 `frp` 渲染器创建 |
| `rendering_server.{h,cpp}`、`rendering_server_default.h`、`storage/compositor_storage.{h,cpp}` | spec 查询、调度/provided/参数存储与转发、VT producer 接口 |
| `renderer_scene_render.{h,cpp}` | 原生 spec 驱动的调度校验 |
| `renderer_viewport.cpp`、`renderer_scene_cull.h`、`rendering_method.h` | compositor 查询、FRP TAA/jitter 选择及渲染方法守卫 |
| `renderer_rd/renderer_scene_render_rd.{h,cpp}` | 后处理/Bloom/Tonemap 分段，曝光纹理覆盖、保留其它渲染器的合并入口 |
| `renderer_rd/effects/taa.{h,cpp}`、`shaders/effects/taa_resolve.glsl` | 历史曝光比例、边界采样及有限 HDR 历史处理 |
| `renderer_rd/effects/copy_effects.{h,cpp}`、`shaders/effects/copy.glsl` | Bloom 的 pre-exposure 一致性 |
| `renderer_rd/storage_rd/light_storage.cpp` | FRP 物理灯光单位与曝光处理 |
| `scene/3d/light_3d.cpp` | `set_base(light)` 使公开基础 RID 可用于精确大气灯光匹配 |
| `shader_types.cpp`、`shader_language.cpp`、`shader_preprocessor.cpp` | shading-model 输入与渲染方法能力识别 |
| `main/main.cpp`、`rendering_device.cpp`、编辑器项目创建/构建设置 | 渲染方法选择、名称与项目能力 |
| `scene/resources/environment.cpp`、`scene/3d/fog_volume.cpp`、`scene/3d/visual_instance_3d.cpp`、`storage/environment_storage.cpp`、`editor/editor_node.cpp` | 功能守卫与编辑器显示 |

表中的短路径相对 `servers/rendering/`，显式 `scene/`、`main/`、`editor/` 路径相对仓库根。
FRP 的 Volume、项目默认 compositor 和可选插件查找均留在插件。
共享 GI 的 split-roughness 扩展已移除；FRP 保留基类要求的空 GI 接口和体积雾所需的
RenderBuffersGI 存储对象，voxel GI 注入计数为零。

升级顺序：

1. 移植自有目录和 spec，再核对共享集成点、ClassDB 签名、shader 布局与回调枚举
2. 核对插件 NativeSpec 常量、默认实现表、纹理名称与新引擎 spec
3. 运行 `python misc/scripts/test_frp_pipeline.py --driver d3d12` 和 `--driver vulkan`
4. 验证 `context` 的脚本接管、TAA/曝光/Bloom、MSAA、大气、项目管线及 Volume；
   同时运行 `forward_plus` 对照，确认共享代码的默认路径与 jitter 未受影响

图形测试需要真实 RenderingDevice。历史像素和性能结果保留在对应验证记录中，
升级是否通过以新构建的测试结果为准。
