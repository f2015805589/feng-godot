# Feng Render Pipeline

FRP 使用一个 `FengRenderer` 资源编排引擎原生操作与自定义 Pass。`FengCompositor`
把该资源连接到 Camera3D / WorldEnvironment。列表顺序直接驱动 FRP 原生渲染器，
不再只是按 CompositorEffect 阶段分组的后处理列表。

## 使用

1. 设置 `rendering/renderer/rendering_method = "frp"`，启用 Feng Render Pipeline 插件。
2. 创建 `FengRenderer`，默认包含下列 8 个引擎 Pass（外加可选的 5 个效果条目，默认关闭）
   和 8 个库 Pass。

## 插件结构

| 位置 | 内容 |
|---|---|
| `renderer.gd` | `FengRenderer`：管线资源本身（条目列表、库同步、旧资源迁移、调度构建） |
| `compositor.gd`、`project_pipeline.gd` | 把 Renderer 接到 Camera3D / WorldEnvironment / 项目设置 |
| `world_compositor.gd` | 引擎"世界用哪个 compositor"的规则（WorldEnvironment 分组）的唯一落点 |
| `editor_plugin.gd` + `editor/` | 编辑器那一半：工具菜单、检查器告警、项目设置行、autoload 注册 |
| `pipeline/` | 调度的模型：`native_spec`（引擎 pass 表）、`library_manager`（内置库与同步）、`pipeline_migrator`（旧资源迁移）、`pipeline_validator`（校验）、`addon_layout`（插件自身路径） |
| `passes/` | Pass 的类：`pass_base`（`FengPass`）、`builtin_pass`、`shader_pass`、`pass_texture`、`pass_output`、`texture_manager`（输出纹理分配） |
| `passes/native/` | 8 个引擎 Pass 的默认实现脚本 |
| `volume/` | `FengVolume` / `FengVolumeProfile`：运行时逐 pass 覆盖 |
| `library/` | 内置效果模板（`*.tres` + `*.glsl`），从 **Add Pass from Library** 添加 |
| `examples/` | 示例与测试用 shader / 资源 |

与引擎的耦合只有三处，而且每一处都只写在插件的一个地方：`RenderingServer.get_frp_pipeline_spec()`
（Pass 表 → `pipeline/native_spec.gd`）、`RenderingServer.compositor_set_frp_pipeline()`
（调度 + provided + 逐 pass 参数 → `renderer.gd`）、`FRPPassContext`（Pass 脚本的 Core 原语）。
`world_compositor.gd` 是唯一例外：WorldEnvironment 的 `_world_compositor_<scenario>` 分组名在引擎里
没有脚本接口，只能在插件里写一次，再由项目管线与 Volume 共用。

## 引擎 Pass

一个 **Pass** 是你在管线资源里看到、可以开关和排序的条目；一个 **Operation** 是渲染器内部
的一个组合步骤。Pass 展开成一个或多个 Operation，所以 resolve、拷贝、历史帧、高光合并这类
记账步骤不再是可独立开关的 Pass，而仍然照常执行。

**ID 顺序就是执行顺序**：pass id 连续、按执行顺序编号，默认调度就是 `0,1,2,…,7`；渲染器按
**资源里的条目顺序**逐个执行，所以你在 Inspector 里拖动条目就是在改执行顺序（和 URP 一样）。
依赖约束只做校验（例如阴影必须在 Lighting 之前），不会替你重排。

| ID | 名称 | 内容 |
|---|---|---|
| 0 | Shadow Precompute | 绘制所有投影阴影的 shadow map。它不读场景深度、G-buffer 或材质页，所以放在最前（VT 之前） |
| 1 | VT Pass | 运行已注册的虚拟纹理页面生产者和材质烘焙回调 |
| 2 | GBuffer | 不透明材质数据、深度，以及运动矢量（同一遍几何） |
| 3 | Lighting | 灯光/Cluster buffer、decal、体积雾准备 → PRE_LIGHTING 阶段 → 全屏延迟光照、次表面散射与分离高光合并、不透明附件 resolve |
| 4 | Sky | 天空及其后附件 resolve |
| 5 | Transparent | 不适合 GBuffer 的前向材质、屏幕/深度副本、透明物体 |
| 6 | Temporal AA | TAA（**打开该条目即开启**，视口 jitter 跟随该条目）；视口的时序上采样器（FSR 2 / MetalFX）也在这里运行（默认关闭） |
| 7 | Post Process / Tonemap | 最终颜色/深度/运动矢量 resolve、引擎后处理与输出 |

引擎侧只有这 8 条；管线里的第 9 条是库里的 `Color Grade` Pass，默认种子在 Temporal AA 与
Post Process 之间，所以整条管线正好是 9 条、顺序为
`0 Shadow → 1 VT → 2 GBuffer → 3 Lighting → 4 Sky → 5 Transparent → 6 TAA → 7 Color Grade → 8 Post`。
SSAO、SSIL、SSR、全局光照（SDFGI / VoxelGI）与调试几何**不是 FRP 的 pass**：FRP 不声明、
不分配、也不合成它们，光照 shader 对这些附件始终用引擎默认（黑色）纹理。

颜色分级不是引擎条目，而是库里的 `Color Grade` Pass——它的 shader 和参数因此可以随插件更新，
不需要改引擎。**一个新 Renderer 的列表正好是这 9 条**：8 个引擎条目 + Color Grade。库里的其它
模板（Tint / Blur H,V / FXAA / Bloom-lite×3）**不进默认列表**，只从检查器的
**Add Pass from Library** 添加；它们和 Color Grade 一样默认关闭，打开条目即生效。

这些条目执行真实的原生操作，但粒度是上述组合步骤，不是逐个 GPU draw/dispatch。
"光照预计算"只指**绘制**阴影这一步；灯光/Cluster buffer 与体积雾属于 Lighting pass（它们在那
被消费），没有单独拆成条目。反射探针和普通 Compositor 保留原有阶段调度。

**默认的 pass 集是插件侧代码**（schema 6）：上表每一条都有一个 `FengNativePass` 脚本
（`passes/native/*.gd`），每个原生条目（`FengBuiltinPass`）通过 `implementation` 指向它。
条目默认由脚本驱动——脚本调用 Core 原语执行该 pass 的 operation，并把该 pass 声明为
"provided" 交给引擎，因此引擎不再为它发 token；把 `implementation` 清空该条目就退回引擎自带的
pass（无插件项目的默认路径）。整条默认调度与引擎自带 pass **逐像素一致**（实测 changed=0）。
要改某个 pass 的实现，复制/继承对应的 `passes/native/*.gd` 并覆盖 `_frp_execute()` 即可：
可以只调其中几个 Core 原语，也可以加上自己的 `@export` 参数（检查器会显示）。

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

6（Temporal AA）与 7（Color Grade）默认关闭，打开条目即生效。**Temporal AA 条目就是 TAA 的开关**：
视口 jitter 跟随该条目（`RendererViewport` 在把相机的合成器管线读出来后决定 16 相位还是 0 相位），
所以不会出现"条目开着却没有 jitter（糊）"或"条目关着却被抖动（闪）"。项目设置
`rendering/anti_aliasing/quality/use_taa` 与 `Viewport.use_taa` 只对**没有配置 FRP 管线的视口**生效
（例如未安装插件的项目、或引擎默认顺序路径）。视口的时序上采样器（FSR 2 / MetalFX）自带 jitter，
不受该条目影响，也不与该条目同时启用 TAA。

排序受数据依赖约束：Shadow 必须先于 Lighting（光照采样阴影贴图），VT Pass 必须先于 GBuffer，
GBuffer 必须先于 Lighting（PRE_LIGHTING 阶段与光照都读 G-buffer），Lighting 必须先于 Sky，
Sky 必须先于 Transparent，Transparent → Temporal AA → Post 依次成立。0、1、2、3、7 是完整输出
必需 的条目，不能删除或禁用（除非由自定义 pass 声明接管，见下）；只有 Temporal AA 可以关闭。

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
要在当前引擎上重新建一个 Renderer（新建的资源直接就是现在这 9 条），再把库效果从
**Add Pass from Library** 加回去。

`FengPass.provides_native_ids` 让自定义 pass 接管必需条目：声明 `[0, 1, 2, 3, 7]` 之后，该
Renderer 可以只含这一个 pass——校验零告警，规范化也不会把条目补回来（引擎侧对这些条目只发
一次警告）。不声明时，只含自定义 pass 的列表会被当作 schema < 5 的旧数组重新种子化（引擎条目
全部补回），所以"漏掉条目"不会静默产生残缺帧。配合 `_frp_execute(ctx)` 的 Core 原语，整帧可以
由脚本驱动，实测与引擎默认顺序逐像素一致。

这个声明同时也是**接管**的开关：声明 6（Temporal AA）后引擎仍把该条目当成帧的一部分，
视口 jitter 照常生效，插件 pass 的 `ctx.temporal_aa_and_upscale()` 才有抖动的历史可累积；
不声明则该条目的位置由引擎条目自己跑。声明通过 `compositor_set_frp_pipeline` 的第四个参数
（provided pass ids）交给引擎。

## 逐 pass 参数（URP 风格）

Pass 脚本自己决定暴露哪些参数：覆盖 `get_frp_parameters()`，列出带类型的 `@export` 属性，管线资源里
该条目就会显示这几个字段——而不是一个自由字典（这也就是"可以选择暴露出来的"）。目前的一个实例是
Temporal AA 的 `jitter_phases`（1 = 冻结抖动采样，TAA 仍然 resolve；16 是引擎默认值，视口 jitter 跟着它）。

优先级从低到高：

1. pass 脚本声明的值（`get_frp_parameters()`，资源字段）；
2. 条目上的 `pass_parameters` 字典（管线资源里的覆盖层，不用改 pass 资源）；
3. 运行时的 Volume（见下）。

参数随调度（`compositor_set_frp_pipeline` 的第 5 个参数）交给引擎；pass 脚本用
`ctx.get_pass_parameters(pass_id)` 读自己这一条 pass 的参数，不管当前是引擎条目还是别的 pass 在跑它。

## Volume（FRP 自己定义的后处理体积，类似虚幻的 Post Process Volume）

`FengVolume` 就是虚幻那种后处理体积：

* 一个 `Node3D` 盒子，`size` 是局部空间的尺寸，可以平移/旋转/缩放；
* `unbound`（虚幻的 **Unbound**）勾上就影响所有相机，用来放全局默认值；
* `priority` 越大越后应用（同优先级按场景顺序）；
* `weight` 是混合强度；`blend_distance`（虚幻的 **Blend Radius**）让权重从盒子边缘 0 平滑升到
  中心的 `weight`；
* `enabled` 关掉就停止影响，但节点留在场景里。

体积每帧解析一次（取当前相机所在的体积，按 priority 从小到大混合），结果推给相机上的
`FengCompositor`。**只有 profile 里列出的参数会覆盖**——没列出的继承上一层，这就是虚幻每个属性
旁边的 override 勾选（在这里体现为"字典里有没有这个 key"，以后可以做成逐字段的勾选控件）。

体积还可以**开关整条 pass**（`enabled_passes` / `disabled_passes`，按 native pass id）：条目的作者态
不动，体积在相机进入时覆盖它，调度和交给引擎的 provided 集合一起跟着变——所以默认关闭的
Temporal AA 可以在某个房间里打开，出了房间自动关掉。布尔状态不插值：影响权重 ≥ 0.5
时生效，同优先级下 `enabled_passes` 覆盖 `disabled_passes`。必需条目（0/1/2/3/7）不能在体积里关掉：
那会产生不完整帧，校验会照常报出来。

```
FengVolume (profile = FengVolumeProfile)
    pass_parameters = { 6: {"jitter_phases": 1} }
    enabled_passes  = [6]        # 这个房间里开 TAA
```

引擎的 Environment 不动：这些参数属于 FRP 的 pass，所以体积和参数都在 FRP 里定义。这是第一版；
逐参数的混合模式（URP 那种 min/max/add）以后再加。

## Pass 自带 shader（overlay）

引擎 pass 的脚本可以带一个 `overlay`（通常是一个 `FengShaderPass`）：它的 `shader_file` 与参数就显示
在这一条 pass 下面，运行位置由脚本自己决定——比如 Post 的实现先 `resolve_final()`、`copy_history()`，
再跑 overlay，最后 `post_process_and_tonemap()`，这样自己的 shader 作用于 HDR 颜色并被呈现。
overlay 的 `inputs`/`outputs`/附件标志会被当作这条 pass 的资源契约交给引擎和纹理管理器，
所以 overlay 声明的纹理会照常创建。
3. 创建 `FengCompositor`，设置 Renderer，赋给 Camera3D 或 WorldEnvironment。
4. 在 Inspector 的 Passes 数组中拖动排序，编辑资源的 Enabled。条目显示具体名称，
   例如 `Deferred Lighting`、`Blur Horizontal`、`Bloom Composite`；`FengShaderPass`
   是它们共用的资源类型，不是效果名称。
5. 在 Inspector 选中 Renderer 或 FengCompositor 后，使用工具菜单
   **Add Pass from Library** 添加库效果。添加和排序支持编辑器撤销、重做。

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
`library:color_grade`（管线的第 9 条）。其余是模板——它们不会自动推进任何已有 Renderer，
也不会出现在新 Renderer 的列表里，只能从检查器的 **Add Pass from Library** 添加；添加后
由 manifest（`_synced_library` / `_deleted_library`）记录身份与删除墓碑，不会重复插入，
也不会把你删掉的条目加回来。Color Grade 缺失时会被同步回 Temporal AA 与 Post Process
之间（它的锚点）。

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
- 在 FengRenderer 中，自定义效果按列表位置运行。`stage` 仅保留为回调参数及旧资源
  迁移提示；在普通 Compositor 中仍按原 Stage 调度。
- 当前 `Color` 指内部 HDR 颜色；依赖它的效果应位于 Deferred Lighting 后、Tonemap 前
  （默认库把库效果放在 Temporal AA 与 Post Process 之间，因此也在 Tonemap 之前）。
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
