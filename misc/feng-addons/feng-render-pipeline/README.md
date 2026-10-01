# Feng Render Pipeline

FRP 使用一个 `FengRenderer` 资源编排引擎原生操作与自定义 Pass。`FengCompositor`
把该资源连接到 Camera3D / WorldEnvironment。列表顺序直接驱动 FRP 原生渲染器，
不再只是按 CompositorEffect 阶段分组的后处理列表。

## 使用

1. 设置 `rendering/renderer/rendering_method = "frp"`，启用 Feng Render Pipeline 插件。
2. 创建 `FengRenderer`，默认包含 9 个引擎 Pass 与 `Color Grade`、`Magic GI`、`Height Fog`、`Eye Adaptation`、
	`Debug Buffers` 五个库 Pass，共 14 个条目；仅 Debug Buffers 默认关闭，其余 13 个条目默认开启。Color Grade 使用中性参数（1, 1, 1, 1）；已保存资源的开关和参数不被覆盖。Bloom 条目默认开启，具体 Glow 效果仍由 Environment 的 Glow 设置控制。
3. 创建 `FengCompositor`，设置 Renderer，赋给 Camera3D 或 WorldEnvironment（或者用项目设置，
   见下文"项目级管线"）。
4. 在 Inspector 的 Passes 数组中拖动排序，编辑条目的 Enabled。条目显示具体名称，
	例如 `Lighting`、`Bloom`、`Blur Horizontal`、`Bloom Composite`。
5. 在 Inspector 选中 Renderer 或 FengCompositor 后，使用工具菜单
   **Add Pass from Library** 添加库效果。添加和排序支持编辑器撤销、重做。

## 插件结构

| 位置 | 内容 |
|---|---|
| `renderer.gd` | `FengRenderer`：管线资源、条目变更观察、库同步和旧资源迁移入口 |
| `compositor.gd`、`project_pipeline.gd` | 把 Renderer 接到 Camera3D / WorldEnvironment / 项目设置 |
| `world_compositor.gd` | 引擎"世界用哪个 compositor"的规则（WorldEnvironment 分组）的唯一落点 |
| `editor_plugin.gd` + `editor/` | 编辑器那一半：工具菜单、检查器告警、项目设置行、autoload 注册 |
| `pipeline/` | `execution_plan`（纯调度计划）、`compositor_binding`（引擎绑定）、`parameter_resolver`（参数协议），以及`native_spec`（引擎 pass 表）、`library_manager`（内置库与同步）、`pipeline_migrator`（旧资源迁移）、`pipeline_validator`（校验）、`addon_layout`（插件自身路径） |
| `passes/` | Pass 的类：`pass_base`（`FengPass`）、`builtin_pass`、`shader_pass`、`pass_texture`、`pass_output`、`texture_manager`（输出纹理分配） |
| `passes/native/` | 9 个引擎 Pass 的默认实现脚本 |
| `volume/` | 空间节点与模块资源、`volume_runtime`（注册和相机生命周期）、`volume_resolver`（混合） |
| `library/` | 内置效果模板（`*.tres` + `*.glsl`），从 **Add Pass from Library** 添加 |
| `examples/` | 示例与测试用 shader / 资源 |

与引擎的耦合只有三处，而且每一处都只写在插件的一个地方：`RenderingServer.get_frp_pipeline_spec()`
（Pass 表 → `pipeline/native_spec.gd`）、`RenderingServer.compositor_set_frp_pipeline()`
（调度 + provided + 逐 pass 参数 → `pipeline/compositor_binding.gd`）、`FRPPassContext`（Pass 脚本的 Core 原语）。
`world_compositor.gd` 是唯一例外：WorldEnvironment 的 `_world_compositor_<scenario>` 分组名在引擎里
没有脚本接口，只能在插件里写一次，再由项目管线与 Volume 共用。

职责边界、依赖和新增功能的落点见 [FRP 插件架构](../../../doc/frp-addon-architecture.md)。

## 引擎 Pass

一个 **Pass** 是你在管线资源里看到、可以开关和排序的条目；一个 **Operation** 是渲染器内部
的一个组合步骤。Pass 展开成一个或多个 Operation，所以 resolve、拷贝、历史帧、高光合并这类
记账步骤不再是可独立开关的 Pass，而仍然照常执行。

**Native ID 是稳定身份，执行顺序来自资源里的条目顺序**。Post Process 保留旧 ID 7，新增 Bloom 使用 ID 8，
所以默认执行顺序是 `0,1,2,3,4,5,6,8,7`。渲染器按**资源里的条目顺序**逐个执行；在 Inspector 拖动条目就是改执行顺序。
依赖约束只做校验（例如 Transparent 必须先于 Bloom，Bloom 必须先于 Post），不会替你重排。

| ID | 名称 | 内容 |
|---|---|---|
| 0 | Shadow Precompute | 绘制所有投影阴影的 shadow map。它不读场景深度、G-buffer 或材质页，所以放在最前（VT 之前） |
| 1 | VT Pass | 运行已注册的虚拟纹理页面生产者和材质烘焙回调 |
| 2 | GBuffer | 不透明材质数据、深度，以及运动矢量（同一遍几何） |
| 3 | Lighting | 灯光/Cluster buffer、decal、体积雾准备 → PRE_LIGHTING 阶段 → 全屏延迟光照、次表面散射与分离高光合并、不透明附件 resolve |
| 4 | Sky | 天空及其后附件 resolve |
| 5 | Transparent | 不适合 GBuffer 的前向材质、屏幕/深度副本、透明物体 |
| 6 | Temporal AA | TAA（**打开该条目即开启**，视口 jitter 跟随该条目）；FSR 2 / MetalFX 按视口请求运行，若该条目关闭则在 Bloom 或 Post Process 首次需要结果时运行 |
| 7 | Post Process / Tonemap | 最终颜色/深度/运动矢量 resolve、引擎后处理与输出 |
| 8 | Bloom | 根据 Environment 的 Glow 设置准备原生 Gaussian Glow 纹理；最终混合仍由 Post Process 中的 Tonemap 完成 |

引擎侧有 9 条；默认的五个库 Pass 按各自的 native 锚点插入，顺序为
`Shadow → VT → GBuffer → Lighting → Magic GI → Sky → Height Fog → Transparent → TAA → Eye Adaptation → Bloom → Color Grade → Post Process → Debug Buffers`。
SSAO、SSIL、SSR、全局光照（SDFGI / VoxelGI）与调试几何**不是 FRP 的 pass**：FRP 不声明、
不分配、也不合成它们，光照 shader 对这些附件始终用引擎默认（黑色）纹理。

颜色分级不是引擎条目，而是库里的 `Color Grade` Pass——它的 shader 和参数因此可以随插件更新，
不需要改引擎。**一个新 Renderer 的列表正好是这 14 条**：9 个引擎条目 + 五个默认库条目。
库里的其它模板（Tint / Blur H,V / FXAA / Bloom-lite×3）**不进默认列表**，只从检查器的
**Add Pass from Library** 添加；它们默认关闭，打开条目即生效。

Blur 和 Bloom-lite 的缩放纹理始终覆盖完整画面。FXAA 使用专用 `FengFXAAPass`，先把场景色复制到管线管理的临时纹理，再读取邻域，避免同一 dispatch 读写场景色产生反馈。该复制仅在启用 FXAA 时执行，不增加默认 Pass。旧资源中仍使用原始默认 shader 和纹理绑定的 `library:fxaa` 会在库同步时安全替换，保留参数、开关、稳定 ID 和顺序；自定义 shader、子类或修改过的绑定不会自动迁移。

`Magic GI` 在 Lighting 后、Sky 前将 surface PRT 的传输系数与当前太阳/环境 SH 点积，作为漫反射间接光加回 HDR；它只使用当前视口匹配的最新有效烘焙，动态光照变化不需要重烘焙。没有有效烘焙或当前 viewport 不匹配时，该 pass 清零自己的诊断纹理并保持画面不变。`Debug Buffers` 默认关闭且不分配输出，可切换到 albedo、view-space normal、AO、roughness、metallic、motion vectors 或 Magic GI 贡献；启用时在 Post Process 后直接显示所选原始缓冲。

`Eye Adaptation` 在 TAA 后测量 HDR 场景色，位于 native Bloom 和 Color Grade 前；默认顺序及依赖校验都保证 Eye Adaptation 先于 Bloom。Bloom 条目负责执行 Environment Glow 的模糊准备，Environment 的 `glow_enabled`、levels、strength、blend mode、intensity 与 glow map 继续配置具体效果；关闭 Bloom 条目会禁用这帧的 Environment Glow 合成。FRP 默认在 Post Process 前准备 Bloom，因此 Glow 使用 DoF 处理前的 HDR 颜色；FRP 的无资源默认调度也使用这个顺序。其它渲染器的旧 Post Process helper 仍按 DoF 后 Glow 的顺序运行。没有 FRP 管线资源时，引擎原生 Glow 路径照常工作。UE 也是先计算曝光，再做 Bloom，并在 Tonemap 中应用曝光和颜色分级。该 Pass 自身有两个全局开关：`extend_default_luminance_range` 切换 UE 的传统亮度范围与 EV100 范围，`pre_exposure` 用上一帧已完成的曝光值预缩放场景光照。相机曝光参数放在该 pass 的 Volume 模块中，包括 Histogram / Basic / Manual 测光、Low/High Percent、亮度或 EV100 上下限、Speed Up/Down、曝光补偿、补偿曲线、测光遮罩，以及手动模式的光圈、快门和 ISO。`CurveTexture` 的 X 轴 0 到 1 对应 UE 默认的 -10 到 20 EV100 曲线区间。开启项目的物理光照单位后，FRP 的点光、聚光与矩形光按 UE 的流明立体角和 π 系数换算。

TAA 的历史 HDR 颜色在裁剪和混合前按 `本帧 pre-exposure / 历史帧 pre-exposure` 重标定，避免自动曝光变化被误判为颜色变化。该历史因子随视口保存；关闭 TAA、切换 compositor 或重建视口缓冲会丢弃旧 TAA 历史。预曝光读回状态也随视口缓冲保存，resize、compositor 切换及预曝光开关变化会退休旧读回，不会将旧回调写进新状态。立体视图仍共用 view 0 的场景预曝光（现有引擎约定）。自动曝光的指数插值权重限制在 0 到 1，长帧及高速适应不会越过目标 EV 后来回振荡。单帧产生的 Inf/NaN 时序历史会被丢弃并使用当前颜色恢复，不会继续当作黑色参与混合；直方图把正向 FP16 溢出归到最亮桶，避免把过亮场景误当成黑色后进一步增加曝光。

Bloom 使用 Eye Adaptation 的当前曝光纹理准备 Glow，并将 firefly 压缩及逆变换的亮度上限按本帧 pre-exposure 同比例缩放，使阈值计算不受场景缓冲 pre-exposure 编码影响。因此 Eye Adaptation 的 `pre_exposure` 开关不会改变 Environment Glow threshold、bloom 与 exposure 参数的含义；它只改变 HDR 场景缓冲在 Tonemap 前的编码范围。

这些条目执行真实的原生操作，但粒度是上述组合步骤，不是逐个 GPU draw/dispatch。
"光照预计算"只指**绘制**阴影这一步；灯光/Cluster buffer 与体积雾属于 Lighting pass（它们在那
被消费），没有单独拆成条目。反射探针和普通 Compositor 保留原有阶段调度。

**默认的 pass 集是插件侧代码**（当前 schema 8）：上表每一条都有一个 `FengNativePass` 脚本
（`passes/native/*.gd`），每个原生条目（`FengBuiltinPass`）通过 `implementation` 指向它。
条目默认由脚本驱动——脚本调用 Core 原语执行该 pass 的 operation，并把该 pass 声明为
"provided" 交给引擎，因此引擎不再为它发 token；把 `implementation` 清空该条目就退回引擎自带的
pass（无插件项目的默认路径）。关闭其他库效果且没有有效 Magic GI 烘焙时，整条默认调度与引擎自带 pass **逐像素一致**（实测 changed=0）。
要改某个 pass 的实现，复制/继承对应的 `passes/native/*.gd` 并覆盖 `_frp_execute()` 即可：
可以只调其中几个 Core 原语，也可以加上自己的 `@export` 参数（检查器会显示）。

**挂上去的 pass 也有 `enabled`，但两个位置含义不同**：

* `FengBuiltinPass.implementation` 是这条 pass 的**实现脚本**——条目的活就是它干的。它的 `enabled`
  和条目的 `enabled` 因此是同一个开关：关掉任一个，这条 pass 就不跑（不再出现在交给引擎的 provided
  集合里，Temporal AA 就不会再开 jitter，也照常触发"必需条目被禁用"的校验）。想**换**成引擎自带的
  pass 则清空 `implementation`——那是换实现，不是关掉。
* `FengNativePass.overlay` 是这条 pass 的**额外工作**（自己的 shader、参数与纹理，例如 Post 的
  overlay）。它的 `enabled` 只关掉这份额外工作：pass 自己的 operation 照跑，overlay 声明的纹理也不再
  创建。overlay 不是调度里的 pass，所以它不影响条目的开关。

这些嵌套的 pass 资源由 renderer 直接监听（`FengPass.carried_passes()`），所以在检查器里改它们的参数
（例如 `jitter_phases`）或勾选框会**立刻**生效，不需要别的操作去"顺带"触发一次应用。

FRP 不做屏幕空间效果，也不做全局光照：`_setup_environment` 里的 `ss_effects_flags`
永远是 0，光照 shader 因此不会采样 SSAO / SSIL / SSR / GI 附件。在 Environment 里打开
这些特性不会改变 FRP 的画面，也不会让 FRP 去分配它们的 attachment。渲染器侧连实现都没有：
SSAO/SSIL/SSR 的生成代码、它们的附件状态、调试视图都已经从 `frp_clustered` 删除；光照 shader 里
那几个 sampler（27/34/35/36）永远绑引擎的黑色默认纹理。`environment_set_ssao_quality()` 等
纯虚重载保留为 no-op（和 `forward_mobile` 一样），否则引擎的环境设置就没法落到渲染器上。
全局光照（SDFGI / VoxelGI）不是 FRP 的 pass，也不参与 FRP 的画面：**SDFGI 已经从 `frp_clustered`
里完全删除**（不再创建、更新、渲染 cascade，也不再为它绑定 lightprobe/occlusion 纹理；引擎要求
的 `sdfgi_update()` / `sdfgi_get_pending_region_*()` 重载保留为"永远没有待更新区域"的空实现，
`_render_sdfgi()` 永远不会被调用），所以在 Environment 里打开 SDFGI 既不会改变 FRP 的画面，也不会
让 FRP 白跑 SDFGI 的渲染。共享 GI 代码里那套"split roughness"（为解码 FRP 的 `orm.g` 布局而加）
也一并删除——FRP 不跑 GI，它没有消费者，删掉之后 `render_scene_buffers_rd.{h,cpp}` 回到上游形态。
VoxelGI 同样已经清掉：G-buffer 不再有 voxel-GI 附件（少一张每帧分配的渲染目标），实例/探针配对、
`use_voxelgi` 管线请求、probe 纹理与实例 UBO 绑定全部删除，`pair_voxel_gi_instances()` 保留为空实现
（引擎纯虚契约）。**FRP 自己的 shader 里也已经没有 GI / SS 代码**：SDFGI 与 VoxelGI 的采样块、
GI buffer 混合、SSAO/SSIL/SSR 块、`scene_forward_gi_inc.glsl` 的引用与那 10 个 uniform 声明
（set 0 binding 14、set 1 binding 8/27/28/29/30/31/32/34/35/36）全部删除，uniform set 里也不再绑
默认值；间接光只剩环境光与聚簇反光探针。残留只有引擎契约要求的两处：基类的 `RendererRD::GI gi`
与 `RB_SCOPE_GI` 的 `RenderBuffersGI` 存储对象（体积雾的 compute uniform set 无条件绑定它，
FRP 的 voxel GI 计数恒为 0，所以雾的 GI 注入不会执行）。

Temporal AA 与库里的 Color Grade 默认开启，可以按需关闭。Bloom 原生条目默认开启，但 Environment Glow 关闭时不做 Glow 工作。**Temporal AA 条目就是 TAA 的开关**：
视口 jitter 跟随该条目（`RendererViewport` 在把相机的合成器管线读出来后决定 16 相位还是 0 相位），
所以不会出现"条目开着却没有 jitter（糊）"或"条目关着却被抖动（闪）"。项目设置
`rendering/anti_aliasing/quality/use_taa` 与 `Viewport.use_taa` 只对**没有配置 FRP 管线的视口**生效
（例如未安装插件的项目、或引擎默认顺序路径）。视口的时序上采样器（FSR 2 / MetalFX）自带 jitter，
不受该条目影响，也不与该条目同时启用 TAA；其上采样结果仍会在 Bloom 或 Post Process 消费前生成。

排序受数据依赖约束：Shadow 必须先于 Lighting（光照采样阴影贴图），VT Pass 必须先于 GBuffer，
GBuffer 必须先于 Lighting（PRE_LIGHTING 阶段与光照都读 G-buffer），Lighting 必须先于 Sky，
Sky 必须先于 Transparent，Transparent 必须先于 Bloom；如果启用 TAA，则 TAA 也必须先于 Bloom；Bloom 必须先于 Post。
Eye Adaptation 也必须先于 Bloom。0、1、2、3、7 是完整输出必需的条目，不能删除或禁用
（除非由自定义 pass 声明接管，见下）；Bloom 可关闭，TAA 默认开启且可选。

运动矢量由 GBuffer Pass 在**同一遍几何**里写出：该 Pass 的 framebuffer 带上速度附件，shader
使用带 `MOTION_VECTORS` 的 G-buffer 变体，速度写在 4 个 G-buffer 附件之后的位置 4。TAA、3D 上采样与
运动矢量调试视图因此不再需要第二遍不透明几何。旧资源（schema < 5）中的独立 Motion Vectors
条目会在迁移时折叠进 GBuffer。

**半透明（以及不适合 G-buffer 的前向材质）走 forward+ 的逐物体聚簇光照**：它们用的是
`RENDER_LIST_ALPHA` / `RENDER_LIST_OPAQUE_FALLBACK` + `PASS_MODE_COLOR`，读取的正是 Lighting
pass 里 `bake_cluster()` 算出的那份 cluster 灯光列表（和 `forward_clustered` 的透明绘制完全同一条
调用）。所以不存在"再跑一遍全屏光照"或"再画一遍不透明几何"的开销：N 个透明物体就是 N 个 draw call。
`frp_transparent.gd` 在真机上锁住了这一点（点光只照亮透明 quad、光源移出范围后 delta 0.0000、
显示该 quad 只增加 1 个 draw call）。

其余条目可以关闭；条目之间的顺序必须满足依赖约束，否则 Inspector 会显示配置依赖错误。
无效配置保留上次有效的原生顺序，并暂停该 Renderer 的自定义效果，避免禁用上游纹理生产者后，
下游继续读取失效纹理；修正配置后恢复。

旧版本（pass 集还没定下来的那几版）存下来的 Renderer 资源会带着当时的 id 与名字进来：条目按 id 认，
所以"旧的 0 号"会顶掉现在的 0 号（Shadow Precompute）。插件不静默重排这种资源，而是把它报出来——
某个条目的名字正好是引擎**另一条** pass 的名字（例如条目 0 叫 `VT Pass`，而引擎的 `VT Pass` 是 1），
Inspector 就会提示"这是按旧 pass 集写的资源"。这种资源不能靠拖动修好（它连 Temporal AA 条目都没有），
要在当前引擎上重新建一个 Renderer（新建的资源直接就是现在这 11 条），再把库效果从
**Add Pass from Library** 加回去。

`FengPass.provides_native_ids` 让自定义 pass 接管必需条目：声明 `[0, 1, 2, 3, 7]` 之后，该
Renderer 可以只含这一个 pass——校验零告警，规范化也不会把条目补回来（引擎侧对这些条目只发
一次警告）。不声明时，只含自定义 pass 的列表会被当作 schema < 5 的旧数组重新种子化（引擎条目
全部补回），所以"漏掉条目"不会静默产生残缺帧。配合 `_frp_execute(ctx)` 的 Core 原语，整帧可以
由脚本驱动；关闭其他库效果且没有有效 Magic GI 烘焙时，实测与引擎默认顺序逐像素一致。

这个声明同时也是**接管**的开关：声明 6（Temporal AA）后引擎仍把该条目当成帧的一部分，
视口 jitter 照常生效，插件 pass 的 `ctx.temporal_aa_and_upscale()` 才有抖动的历史可累积；
不声明则该条目的位置由引擎条目自己跑。声明通过 `compositor_set_frp_pipeline` 的第四个参数
（provided pass ids）交给引擎。

## 性能定位与高亮历史

脚本分析器里的 `FRPPassContext.run_pass()` 是执行原生操作的调用入口，
其 CPU 包含时间不能直接当成某个 GPU pass 的耗时。启用可视分析器后，
原生条目与库条目都有成对的 `FRP <名称>` CPU / GPU 时间范围；未启用时间捕获时
不增加这些查询。先看具体 Lighting、Sky、Temporal AA 或库效果，再区分
CPU 提交/编译与 GPU 执行；不要把同一层级的包含时间重复相加。

全屏 Lighting 保留深度雾模式、方向软阴影、区域光可见性三个视图标志的
8 个有界组合。多个相机交替渲染或区域光进出视野时，已预热的组合直接复用；
全局质量变化会在下次使用对应组合时刷新。实际同步创建计入
`Performance.PIPELINE_COMPILATIONS_DRAW`，因此预热后继续增长是明确的编译排查信号。
`misc/scripts/tests/frp_lighting_cache.gd` 保持默认 13 个非调试条目开启，
同时验证反复切换后的编译计数、有效像素，并分别报告 CPU、GPU 和墙钟时间。
不同设备和软件 Vulkan 的绝对耗时不能直接横比。

TAA 的最近深度与速度读取使用同一像素坐标，并在视口边界钳制采样；
历史坐标越界或无效时直接使用当前像素，避免从边缘历史或无效速度
继续混合；HDR 压缩的逆变换遵守实际 RGBA16F 的有限存储范围。Color Grade
按像素精确读取其原位附件，在颜色运算前修复非有限分量，避免单个过曝太阳
像素的 Inf 经中性饱和度变成 NaN 并扩散。普通有限、可表示的 HDR 值保持原有
颜色运算。`frp_hdr_sun.gd` 使用实际生产 shader 验证高亮、运动和历史曝光极值。

## Pass 参数与 Volume 模块

**硬规则：能在插件侧完成的工作必须留在插件侧；只有现有 Core 接口无法表达的必要能力或已确认的引擎缺陷才修改引擎。**
参数声明、Volume 模块、混合策略、检查器和范围线框均不进入引擎。引擎只传递帧参数快照并提供渲染原语。

Pass 可以自由添加带类型的 `@export` 属性，基类自动收集自定义导出参数；需要不同名称或计算值时也可重写
`get_frp_parameters()`。**哪些参数可进入 Volume 由 Pass 作者在代码中通过 `get_volume_parameter_names()` 规定**。
默认空列表表示不提供 Volume 模块；Volume 使用者只能选择模块和修改已声明的字段，并通过 `overrides/字段名` 勾选是否覆盖。覆盖开关不能扩大 Pass 声明的暴露权限。

管线全局参数与 Volume 字段是两份独立声明：只出现在 `get_frp_parameters()` 中的字段不会进入 Volume。
例如 TAA 的代码明确将 `enabled` 与 `jitter_phases` 开放给 Volume；其他 Pass 不会自动得到这些字段。
Volume 中的 `enabled = false` 是该 Pass 参数的关闭覆盖，仍高于管线的 `true`，不是取消覆盖。
取消单个字段的覆盖请取消对应的 `overrides/字段名` 勾选，保留字段值并继承较低优先级的结果；也可以移除模块或关闭整个 Volume。旧模块默认覆盖全部已声明字段，存储的关闭状态会按 TAA 的新声明兼容读取。

```gdscript
@tool
extends FengPass

@export_range(0.0, 4.0, 0.01) var strength := 1.0:
    set(value):
        strength = value
        emit_changed()
@export var pipeline_only_setting := 8

func get_volume_parameter_names() -> PackedStringArray:
    return PackedStringArray(["strength"]) # 由 Pass 代码固定，Volume 不显示另一个字段

func _frp_execute(ctx: FRPPassContext) -> void:
    var settings := get_resolved_parameters(ctx)
    # 自己的渲染代码使用 settings["strength"]，不要再直接读取作者态字段。
```

在 `FengVolume` 或 `FengVolumeProfile` 检查器中选择当前管线的模块并添加，随后在 `modules` 中编辑字段。
字段类型、范围、枚举沿用 Pass 导出定义。模块可整体禁用；增加模块不会自动把管线中关闭的 Pass 打开。
独立 Profile 可以在编辑器的 Renderer 选择器中指定模块来源。

优先级从低到高是 **Pass 资源值 → 管线条目 `pass_parameters` → Volume 混合结果**。
Volume 按 priority 从低到高应用，同优先级保持注册顺序；数值、颜色和浮点向量连续混合，布尔、枚举及资源等离散值
在权重达到 0.5 时切换。`get_resolved_parameters(ctx)` 同时支持原生 Pass、自定义 Pass 和 overlay。
即使旧 Profile 字典中塞入未允许的字段，运行时也会按当前 Pass 的声明过滤。

普通自定义 Pass 加入 Renderer 时获得持久化 `stable_id`，原生槽位保持整数 id。
需要由脚本控制模块身份时可重写 `get_parameter_key()`；同一管线内独立模块的 key 必须唯一。
不要用可变的列表位置作为模块身份。导出属性修改仍需在 setter 调用 `emit_changed()`，通知管线更新帧快照。

## Volume 范围和运行时边界

`FengVolume` 是局部空间盒子，`size` 定义外边界，支持平移、旋转和缩放。
`blend_distance` 是**向盒子内部**的过渡距离：外边界影响为 0，内盒尺寸为 `size - 2 * blend_distance`，
内盒影响为 `weight`（weight 为 1 时是完整覆盖）。过渡太宽导致不存在完整影响区时，不画虚假的内盒。
`blend_distance = 0` 表示盒内直接应用；`unbound` 表示该视口中的全局 Volume，没有有限盒子边界。

启用插件后，**仅编辑器 3D 视图**通过 `EditorNode3DGizmoPlugin` 绘制内外线框和对应八个角的连线；
运行游戏不创建范围网格，也不显示线框。Gizmo 与运行时使用同一个范围定义。

编辑器预览由 `editor/volume_preview.gd` 将当前编辑场景的 Volume 应用于各个 3D 视图相机，
按每个视图相机的位置独立混合。修改模块字段会更新预览；切换场景或禁用插件会恢复原相机管线。
有限 Volume 要求观察相机进入盒内才生效，仅看到盒内物体不等于相机处于影响范围；`unbound` 可用于全局预览。

静止时只做轻量变更检查；参数、范围或管线变化才重新解析。隐藏视图和范围外相机跳过预览计算，
进出范围复用已创建的运行时效果，避免重复编译着色器。Pass 作者的参数 setter 仍需调用 `emit_changed()`。

每个相机的结果保存在其 `FengCompositor` 的独立 ViewState 中，不再深复制整套 Renderer，也不改作者态；退出范围或关闭 Volume
会恢复全局设置。不同相机若需要不同结果，应使用不同 `FengCompositor`，它们可以共享同一个 Renderer 资源。
默认无 overlay 的原生 Pass 和标准 FengShaderPass 共享定义/执行对象；每相机的效果 RID、开关、
参数和纹理管理独立。未知自定义子类及带 overlay 的条目保留独立执行实例，避免脚本状态相互污染。
自定义 Pass 可覆写 `can_share_view_execution() -> bool` 返回 `true`，明确允许跨视图共享执行实例。
这要求整个执行对象及其携带的 Pass 不保存跨相机可变状态，逐视图参数从 `FRPPassContext` 获取；
仅实现此接口不会合并相机的效果 RID、开关或纹理。默认返回 `false`，无需修改 Renderer 中的类型白名单。
输入、输出声明的字段变更通过 `Resource.changed` 传播至 Pass 和 Renderer，使视图快照失效；
替换声明数组会重新连接依赖。脚本原位增删 `inputs` / `outputs` 后应重新赋值数组以更新观察关系。
`volume_resolver.gd` 只负责混合，`pipeline/parameter_resolver.gd` 负责参数收集、模块身份关联和暴露权限，
编辑器插件负责模块选择与 UndoRedo。新增模块无需修改这些服务或引擎。
运行时在配置变化时将参与覆盖的字段编译为槽位和混合操作，预先解析权限、别名、默认值及枚举规则。
`volume_runtime.gd` 负责路由和生命周期，每个视图的 `volume_evaluator.gd` 独立持有有界求值缓存；
求值器只需要位置和设置来源，游戏及编辑器共用该实现。
相机移动只更新权重并混合槽位，最后生成一份参数快照；多个 Volume 不会增加该 Pass 的渲染次数。
为兼容直接修改公开字典，配置变更检测仍保留字典哈希；此实现没有将动态参数接口改为 C++ 结构。

旧 Profile 的 `pass_parameters` 数据仍可加载；新界面使用 `FengVolumeModule`。
旧 `enabled_passes` / `disabled_passes` 仅保留为兼容存储，不在新界面显示；运行时也要求当前 Pass
明确向 Volume 声明布尔 `enabled` 字段，影响权重达到 0.5 时应用。必需 Pass 仍受调度校验约束。

## Pass 自带 shader（overlay）

引擎 pass 的脚本可以带一个 `overlay`（通常是一个 `FengShaderPass`）：它的 `shader_file` 与参数就显示
在这一条 pass 下面，运行位置由脚本自己决定——比如 Post 的实现先 `resolve_final()`、`copy_history()`，
再跑 overlay，最后 `post_process_and_tonemap()`，这样自己的 shader 作用于 HDR 颜色并被呈现。
overlay 的 `inputs`/`outputs`/附件标志会被当作这条 pass 的资源契约交给引擎和纹理管理器，
所以 overlay 声明的纹理会照常创建；overlay 自己的 `enabled` 关掉时它既不跑、也不声明纹理
（契约退回实现脚本本身），而 pass 自己的 operation 照常执行——见上文"挂上去的 pass 也有
`enabled`"。

## 后处理在 tonemap 前还是后（shader 关键字）

后处理阶段与 tonemap 是**两个独立的 Core 原语**，所以 Post 条目里的 overlay 由 pass 脚本决定跑在哪一侧：

```gdscript
# 前：overlay 写进帧的 HDR 颜色缓冲，随后的 tonemap 会读它
ctx.post_process(); overlay._frp_execute(ctx); ctx.tonemap()
# 后：tonemap 不自己 present（写进引擎的中间纹理），overlay 写自己的纹理，再由 pass present
ctx.post_process(); ctx.tonemap_deferred(); overlay._frp_execute(ctx); ctx.present("post_ldr")
```

`post_process_pass.gd` 用 `overlay_after_tonemap` 选择位置（它是逐 pass 参数：`get_frp_parameters()`，
所以管线资源或 `FengVolume` 都能在运行时切换），并且**把位置作为 shader 关键字告诉 overlay**：

```glsl
layout(constant_id = 0) const bool POST_AFTER_TONEMAP = false;
```

`FengShaderPass` 现在支持 shader 关键字（specialization 常量）：`shader_keywords = {0: true}` 或在运行时
`set_shader_keyword(0, true)`——关键字变化会重建 pipeline，所以那个分支真的会被特化掉。要读"已经被
tonemap 过的图像"，把输入声明成 `FengPassTexture.Source.TONEMAPPED`。

实测（`frp_post.gd`）：overlay 按关键字写纯色，放在 tonemap **前**得到被 AgX 处理过的红
`(0.8706, 0.251, 0.1098)`，放在 tonemap **后**得到原样呈现的纯绿 `(0.0, 1.0, 0.0)`——后者同时证明了
关键字到达了 shader、tonemap 被推迟、以及 pass 自己的 `present()` 真的把结果放上了屏幕。

## 内置库

`DEFAULT_LIBRARY_ENTRIES` 是库清单，每项包含稳定 `id`、模板 `path` 和显示 `name`。
新增效果时放入 GLSL + `.tres`，在清单登记：

```gdscript
{"id": "library:my_effect", "path": "my-effect/my_effect.tres", "name": "My Effect"},
```

`DEFAULT_LIBRARY_SEEDED` 决定哪些条目**进入**新 Renderer 的默认列表：目前只有
`library:color_grade`、`library:magic_gi`、`library:height_fog`、`library:eye_adaptation`、`library:debug_buffers`。其余是模板——它们不会自动推进任何已有 Renderer，
也不会出现在新 Renderer 的列表里，只能从检查器的 **Add Pass from Library** 添加；添加后
由 manifest（`_synced_library` / `_deleted_library`）记录身份与删除墓碑，不会重复插入，
也不会把你删掉的条目加回来。Eye Adaptation 缺失时会同步到 native Bloom 前；Color Grade
缺失时会同步到 Bloom 与 Post Process 之间（它的锚点）。

稳定 ID 应保持不变。同步补充身份与显示名，不会强行合并已实例化模板的参数改动。旧版只有
自定义效果的 `.tres` 会迁移为完整列表，并按原 Stage 安排初始位置，保留旧的库删除记录。
旧版用旧原生 id 的 `.tres`（schema < 5）会按旧 id → 新条目的映射折叠：已消失的条目
（Motion Vectors、Opaque Resolve、Sky Resolve、Subsurface、Screen/Depth Copy、Final Resolve、
History Copy、Opaque Forward Fallback）不再作为条目存在，它们的工作由对应 Pass 内部的
Operation 承担，开关状态和自定义条目的相对位置都会被保留。

## 自定义 Pass

- 继承 `FengPass` 实现 `_setup(rd)`、`_render(buffers, view, rd)`、`_cleanup(rd)`。
- 或创建 `FengShaderPass`，配置 Compute / 全屏 Raster、`shader_file`、`parameters`
  （vec4 push constant）、`inputs`、`outputs` 和目标纹理。
- `FengPassTexture` 支持 Color、Depth、GBuffer、管线中间纹理及自定义 scope。
  `FengPassOutput` 声明名称、格式、用途和尺寸比例，隐藏的 Texture Manager 管理分配。
  字段就叫 `custom_name`（管线/自定义纹理的名字）、`data_format`、`usage`、`scale`
  （相对内部尺寸的比例）；早期版本用的 `pipeline_name` / `format` / `usage_bits` /
  `size_divisor` 是同一批字段的旧拼法，已经删掉——**重命名之后被保存过的资源不受影响**
  （`.tres` 里同时带着新名字），只有重命名之前保存、且从未被重新保存过的资源会留下无效的旧行
  （Godot 对不存在的属性名是**静默忽略**的，看 `scene/resources/resource_format_text.cpp`），
  在检查器里按新名字重设一次即可。
- 在 FengRenderer 中，自定义效果按列表位置运行。`stage` 仅保留为回调参数及旧资源
  迁移提示；在普通 Compositor 中仍按原 Stage 调度。
- 当前 `Color` 指内部 HDR 颜色；依赖它的效果应位于 Deferred Lighting 后、Tonemap 前。
  `Magic GI` 由 manifest 锚定在 Lighting 后，`Color Grade` 在 Bloom 后，`Debug Buffers` 在 Post Process 后。
  自定义纹理必须先生产再消费。同一 Pass 的 storage-image 输出绑定可以引用自身输出。

禁用的自定义 Pass 仍保留在 effects 中，重新启用不再需要重新插入。FengCompositor
合并资源 changed 通知后自动 apply。脚本直接修改数组内容时，使用整个数组重新赋值
或在修改后调用 `renderer.emit_changed()`；手动使用普通 Compositor 时显式 apply。

## 项目级管线（Scene 视图与运行中的游戏同一套）

编辑器自由视角用的是**编辑器自己的相机**，运行中的游戏用的是你场景里的 Camera3D——两台相机，所以挂在
Camera3D 上的 FengCompositor 只影响游戏，而"只创建/选中 Renderer 资源"两者都不影响。要让两边看起来
一样，管线必须挂在**世界**上（WorldEnvironment 走的就是这条路），而不是某台相机上。

与其给每个场景都放一个 WorldEnvironment，不如把管线放进项目设置——**一个地方设置，编辑器与游戏都读它**：

```ini
[rendering]

renderer/compositor="res://render/test_compositor.tres"
```

位置在 **Project Settings → Rendering → Renderer → Compositor**，就在渲染器选择（`rendering_method`）
下面。插件启用时自动注册这一项：默认可见（不需要打开 Advanced Settings，也不用搜索），文件选择器只列
`.tres`/`.res`，而**只有当项目渲染器选的是 frp 时才显示**——换到 `forward_plus`/`mobile` 时它会被隐藏
（`set_as_internal`），值仍留在 `project.godot` 里，换回来即恢复。值就是管线本身：FengCompositor 直接
用；指向裸的 FengRenderer（管线资源）时运行时自动套一层 FengCompositor。

两半都在插件里，引擎没有为此加任何东西：

* **编辑器**：`editor_plugin.gd` 把编辑器自由视角渲染的那个根 World3D 同步到该设置——插进去的是一个只带
  compositor 的隐形 WorldEnvironment（`project_pipeline.gd` 的 `install()`），所以 Scene 视图跑的就是
  项目管线。
* **运行中的游戏**：插件启用时注册一个 autoload（`FengProjectPipeline` → `project_pipeline.gd`），它在
  游戏根视口做同一件事。设置为空时它什么都不做；这条 autoload 注册后一直保留（`_exit_tree` 在编辑器
  退出时也会跑，每次退出都改写 `project.godot` 才是麻烦），不想用删掉 `project.godot` 里那一行即可。

优先级用的是引擎自带的规则，插件不覆盖：**Camera3D 的 compositor > 世界（WorldEnvironment）的
compositor > 项目管线**。项目管线还会**让位**：同一世界里只要有别的 WorldEnvironment 提供 compositor，
插件就退出这个世界，等那个节点消失再接管——所以"某个场景单独用另一套管线"依旧成立。

开关也只有一个：世界里有管线时，**Temporal AA 条目就是 TAA 的开关**（视口 jitter 跟着它；
`rendering/anti_aliasing/quality/use_taa` 与 `Viewport.use_taa` 只对没有管线的视口生效）。这条保证是
排他的：条目关掉时即使视口的 `use_taa` 是开的，FRP 也不会去跑一个没有 jitter 的时序 resolve（那是糊，
不是抗锯齿）。Scene 视图与游戏因此共用同一个开关。

验证：`frp_project_pipeline.gd`（游戏侧：设置决定画面、条目是开关、场景自带 compositor 优先、清空设置
后还原）与 `frp_editor.gd`（编辑器侧：设置注册成文件选择器、autoload 注册、Scene 视图渲染的世界确实带
着项目 compositor）。

## RenderDoc 对照

Renderer 资源需要通过 FengCompositor 挂到 WorldEnvironment、Camera3D，或者放进上面的项目设置。
仅创建、选中 Renderer 资源不会改变场景。编辑器自由视角使用编辑器自己的相机，所以相机上的
compositor 只影响游戏；要用同一套，用项目设置或 WorldEnvironment。

GPU 事件按 `列表序号 + Pass 名称 → 内部操作 → Commands (L…)`
分组。自定义名称来自 `resource_name`，与 Inspector 列表一致。显式管线在 Pass
边界建立命令依赖，防止渲染图把命令移到其他 Pass 前后；单个 Pass 内部仍按资源
依赖优化。`L` 是底层命令图层级，不是列表序号。

禁用的 Pass 不会运行。启用但当前帧没有 GPU 工作的 Pass 仍有一个轻量 RenderDoc
事件，名称和列表位置保持与 Inspector 一致；事件中的空 driver callback 不提交
dispatch、draw、clear 或资源上传。例如未开启 MSAA 时的 Post Process、场景没有透明物体时的
Transparent 仍可通过配置名称定位。VT Pass 只在有注册的页面生产工作时提交 GPU
工作，空闲时只保留这个 marker。GBuffer 内含普通场景几何 draw（需要时同一遍同时写出
运动矢量），也支持地形自定义 Shader 的
`vertex()` 位移和法线输出；只有不适合 GBuffer 的材质才会归入 Transparent 里的前向队列。
Deferred Lighting 的全屏 draw 消费 GBuffer，不代表所有物体只画了一次全屏三角形。
编辑器最后把 Scene 纹理绘制到 UI 的步骤也不是场景几何绘制。

## 验证

```text
python misc/scripts/test_frp_pipeline.py --driver d3d12
python misc/scripts/test_frp_pipeline.py --driver vulkan
```

测试使用隔离项目和真实 GPU，覆盖延迟渲染、库效果、保存迁移、新增条目插入位置、
开关、原生/自定义排序、MSAA、TAA 与运动矢量、项目级管线，以及编辑器资源选择、
库菜单、撤销和重做。
