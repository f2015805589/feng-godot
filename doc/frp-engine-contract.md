# FRP 引擎契约（升级引擎时的最小改动面）

本文回答一个问题：**把 FRP 搬到新版本 Godot 上，需要动哪些地方？**
它列出引擎侧必须保留的 Core 表面、FRP 在共享文件里的全部触点、以及双方的数据契约。

## 硬边界：优先与引擎解耦

能在插件侧完成就必须放在插件侧，保持低耦合、高内聚。参数声明、Volume 模块及字段权限、混合、检查器和范围
Gizmo 都属于插件。仅在现有 Core 无法提供必要的底层能力，或确认缺陷位于引擎时，才做最小引擎改动；
不为添加效果、模块或编辑器界面扩大引擎策略层。

参数快照的键支持原生整数 id 和自定义稳定字符串 id；`FRPPassContext.get_pass_parameters(key)` 接受 Variant。
这只扩展现有数据通道和入口键校验，不把 Volume 注册表或混合逻辑放进引擎。原生整数键保持兼容。

## 1. Core 表面（脚本可见，尽量不改）

`FRPPassContext`（`servers/rendering/renderer_rd/frp_clustered/frp_pass_context.{h,cpp}`）是插件
pass 唯一依赖的引擎接口。它的每个方法都转发到引擎内置 pass 调用的同一个 operation：

| 类别 | 原语 |
| --- | --- |
| 帧状态 | `get_render_data()`、`get_render_scene_buffers()`、`get_view_count()`、`get_internal_size()`、`get_pass_name(id)`、`is_valid_pass_id(id)`、`get_pass_parameters(id)` |
| 提交与绘制 | `draw_gbuffer()`、`draw_motion_vectors()`、`draw_deferred_lighting()`、`draw_sky()`、`draw_transparent()`、`draw_opaque_fallback()` |
| 准备与收尾 | `precompute_shadows()`、`execute_virtual_texture_updates()`、`prepare_lighting()`、`merge_subsurface_and_specular()`、`resolve_opaque()`、`resolve_sky()`、`resolve_final()`、`copy_screen_and_depth()`、`copy_history()` |
| 时域与后处理 | `temporal_aa_and_upscale()`、`post_process()`、`tonemap()`、`tonemap_deferred()`、`present(texture)`、`post_process_and_tonemap()` |
| 组合 | `run_pass(id)`、`stage_compositor_effects(type)` |

`precompute_shadows()` 是 pass 0：绘制所有投影阴影的 shadow map。它是唯一与帧内其它工作无关的准备
步骤（从光源视角绘制，不读场景深度、G-buffer 或材质页），所以排在 VT 与 G-buffer 之前。
`prepare_lighting()` 属于 Lighting pass：灯光/Cluster buffer、decal 与体积雾在那被消费。

FRP 没有屏幕空间效果（SSAO/SSIL/SSR）、全局光照（SDFGI/VoxelGI）与调试几何原语：它们不是 FRP 的
pass，`FRPPassContext` 也不暴露对应入口。渲染器内部同样没有它们的位置——SSAO/SSIL/SSR/GI 的生成
代码、附件与调试视图都不在 `frp_clustered` 里（只剩引擎纯虚接口要求的 no-op 重载与 SDFGI 的空实现）。

pass 集与顺序约束来自 `servers/rendering/frp_pipeline_spec.h`（pass → operation 展开表，
插件通过 `RenderingServer.get_frp_pipeline_spec()` 读回）。**pass id 连续且就是执行顺序**，
资源里的条目顺序就是引擎的执行顺序（与 URP 的 RendererFeature 列表一致）。引擎侧 8 条，
插件侧再补一条 Color Grade，管线共 9 条 —— 一个新 Renderer 的列表正好是这 9 条。

**约定**：新增原语只能追加；已有原语的名字与语义不变。删除或改名属于破坏性变更，必须同时改
`frp_pipeline_spec.h`、`FRPPassContext` 绑定与插件 `FengNativeSpec`。

## 2. FRP 在共享文件里的全部触点

| 文件 | 为什么必须改 | 规模 |
| --- | --- | --- |
| `servers/rendering/frp_pipeline_spec.h` | pass/operation 表（新增文件，FRP 自有） | 全文件 |
| `servers/rendering/renderer_rd/frp_clustered/*` | 渲染器本体（FRP 自有目录） | 目录 |
| `servers/rendering/renderer_rd/shaders/frp_clustered/*` | FRP 自有 shader | 目录 |
| `servers/register_server_types.cpp` | 注册 `FRPPassContext` | +2 行 |
| `servers/rendering/renderer_rd/renderer_compositor_rd.cpp` | 把 `frp` 注册为渲染方法 | ~4 行 |
| `servers/rendering/rendering_server.{h,cpp}` + `rendering_server_default.h` | `get_frp_pipeline_spec()` + `compositor_set_frp_pipeline()`（第 4 个参数为插件提供的 pass id 集、第 5 个为逐 pass 参数）等绑定，以及默认服务器的转发签名 | ~60 行 |
| `servers/rendering/renderer_scene_render.{h,cpp}` | 调度校验（id/重复/依赖 + 提供 id 合法性 + 缺必需条目的警告按 provided 判定）；**pass 表本身改从 `frp_pipeline_spec.h` 读**（原先在这里被复制了一遍：0..16 的 id、必需集与 34 条依赖） | ~50 行 |
| `servers/rendering/storage/compositor_storage.{h,cpp}` | 合成器上保存 FRP 调度 + 插件提供的 pass id 集 | ~30 行 |
| `servers/rendering/renderer_viewport.{h,cpp}` | TAA 条目决定 jitter（`jitter_owned_by_upscaler` + 派生；含"插件提供的 6"）；渲染器侧的 `using_taa` 用同一条规则（有条目时以条目为准），所以"条目关掉"不会留下没有 jitter 的时序 resolve | ~20 行 |
| `servers/rendering/renderer_scene_cull.h` | `render_get_compositor()` 覆写 | +2 行 |
| `servers/rendering/rendering_method.h` | 上述访问器的基类声明 | +3 行 |
| `servers/rendering/renderer_rd/storage_rd/render_scene_buffers_rd.{h,cpp}` | **已回到上游形态**：FRP 的粗糙度布局不再向共享代码声明（FRP 不跑任何解码它的共享代码） | 0 行 |
| `servers/rendering/renderer_rd/environment/gi.{h,cpp}` + `shaders/environment/gi.glsl` | **已删除 fork 的 split-roughness 机制**（FRP 不跑 GI，共享 GI 代码只保留打包布局） | −53 行 |
| `servers/rendering/renderer_rd/renderer_scene_render_rd.{h,cpp}` | 后处理与 tonemap 拆成两段（FRP 需要分别执行；合并入口保留，其它渲染器行为不变） | ~20 行 |
| `scene/resources/environment.cpp`、`scene/3d/fog_volume.cpp`、`scene/3d/visual_instance_3d.cpp`、`editor/editor_node.cpp` | `frp` 加入渲染方法守卫 / 显示名 | 各 1–4 行 |

除上表之外**没有**任何 FRP 痕迹；`forward_clustered/` 与
`shaders/forward_clustered/` 必须保持与上游逐字节一致（这是硬约束，也是双向回归的一部分）。

## 3. 数据契约（插件读得到的东西）

* G-buffer（scope `RB_SCOPE_FRP_CLUSTERED`）：`normal_roughness`（10:10:10 直接法线 + 动态标记
  在 alpha）、`albedo`、`orm`（**粗糙度在 `orm.g`**）、`emission`（specular 在 alpha）、
  `orm.a`（按 Unreal legacy GBufferB 约定，低 4 位保存 ShadingModelID，高 4 位预留 selective-output flags）。
  当前 `orm` 仍是 RGBA8，ID 0=Unlit、1=DefaultLit，未知非零 ID 归一化到 DefaultLit；这是接入接口，
  现阶段仅实现默认 BxDF。ID 是 G-buffer 像素语义，不能与 CPU render-list 的 sort material ID 混用。
  普通 G-buffer 仍为 4 个颜色附件；开启运动矢量时 velocity 为 shader location 4。
* 颜色 framebuffer 变体由 `separate_specular × motion_vectors` 决定，插件通过 Core 原语间接使用，
  不自己拼附件。
* 运动矢量在 GBuffer pass 内产生（同一遍几何）；`frp_taa.gd` 的 draw call 守卫保证不会回退成两遍。
  该附件只有这一遍写：没被它画到的像素保留 clear 值 `(-1, -1)`（引擎的"无数据"标记，调试视图与
  FSR2 都会为它回退到按深度推导）。TAA 必须看到**有效**速度才能重投影，所以在时序 resolve 前，
  FRP 用自己的一遍 `shaders/frp_clustered/frp_velocity_fill.glsl` 把标记像素按深度补上
  （只改带标记的像素，逐物体速度原样保留；排在 MSAA resolve 之后，所以 MSAA 也成立）。
  共享的 `effects/motion_vectors_store.*` 保持上游形态，forward_plus 与 MetalFX 都不受影响；
  `frp_taa_background.gd` 守卫它：静态帧必须收敛（色背景 changed 0/76800、细节天空 changed 0/76800，
  修复前分别是 156 与 1631），转动相机时天空的位移要跟得上无 TAA 的位移（0.1718 vs 0.1739）。
* 时序：TAA 的开关是管线里的 Temporal AA 条目，视口 jitter 跟随它；项目设置
  `rendering/anti_aliasing/quality/use_taa` 只对**没有 FRP 管线**的视口生效。
* 调度除了 token 列表，还带一份**插件提供的 pass id 集**（`compositor_set_frp_pipeline` 的第 4 个
  参数）。引擎的逐帧特性查询（`schedule_has`：6）与视口 jitter 都把它当作"该 pass 在帧里"，
  所以插件可以删掉引擎条目而由自己的 pass 完成工作。空调度（无合成器/无管线）仍然是"默认顺序"。
  FRP 不运行的特性（SSAO/SSIL/SSR/GI）连 shader 代码都没有：`_setup_environment` 的
  `ss_effects_flags` 恒为 0，而且 `frp_clustered` 的 shader 已不再声明 SSAO/SSIL/SSR/GI 的附件
  binding（那 10 个 binding 已从 uniform set 与 shader 中一并删除）。
  实测：插件 pass 声明 4 并调用 `ctx.run_pass(4)` 跑 Sky 时与内置条目**逐像素一致**（toggles：
  control delta 0.6561，takeover delta 0.0000）；声明 6 时视口 jitter 照常生效
  （taa：同一 pass 声明前后帧不同）。
* 插件侧的调度模型（schema 6）：每个原生条目（`FengBuiltinPass`）可以带一个 `implementation`
  pass 脚本。带实现时条目按自定义条目派发（自定义 token + provided id），不带实现时发引擎 token。
  因此引擎侧的契约只有两条：token 列表 + provided id 集；"谁执行这个 pass"完全由插件决定。
* 逐 pass 参数：调度还带一份 `{native_pass_id: {参数名: 值}}`（`compositor_set_frp_pipeline` 的
  第 5 个参数，`Dictionary`）。pass 脚本用 `FRPPassContext.get_pass_parameters(id)` 读自己的参数；
  引擎自己消费的目前只有 Temporal AA 条目的 `jitter_phases`（`RendererViewport` 用它决定 jitter
  相位，1 = 冻结采样、16 = 默认）。插件侧的层次是：pass 脚本声明（`get_frp_parameters()`）<
  条目 `pass_parameters` 覆盖 < `FengVolume` 运行时覆盖。

## 4. 搬到新版本 Godot 的清单

1. 带上 `frp_pipeline_spec.h` + `frp_clustered/`（渲染器与 shader）——这两个是 FRP 的全部实现。
2. 按第 2 节表格重放触点；每处都是小块、机械的补丁。
3. 跑 `python misc/scripts/test_frp_pipeline.py --driver d3d12`（import / gpu / taa / taa_background /
   project_pipeline / toggles /
   transparent / context / editor / forward_plus），双向都必须绿。forward_plus 那一项是本轮新增的探针：它在
   forward_plus 下挂一个带 FRP 调度的合成器，要求 forward_plus 仍然按自己的 jitter 抖动
   （即 jitter 规则留在渲染方法守卫之内），并记录 4 种配置的亮度。
4. 若上游改了 shader 变体索引、`RenderSceneBuffersRD` 命名或 CompositorEffect 回调枚举，
   只需同步 `scene_shader_frp_clustered.*`、`frp_pass_context.cpp` 的枚举绑定与插件
   `FengNativeSpec`——插件 pass 脚本本身不动。

## 5. 尚未打通的部分（诚实清单）

* **上游 TAA 的深度方向（已发现，故意不动）**：`shaders/effects/taa_resolve.glsl` 的
  `depth_test_min`（注释写 "velocity with closest depth"）是 2022 年按"深度越小越近"写的，而
  2024-02 上游改成 reverse-Z（`d950f5f838`：`Projection::set_depth_correction` 默认
  `p_reverse_z = true`、几何 pass 用 `COMPARE_OP_GREATER_OR_EQUAL`、清屏深度 0 = 远）时没同步改它，
  于是它取到的是邻域里**最远**的像素（天空）。这个速度只喂给自适应方差盒的 `box_size`，所以它只在
  深度不连续处出错：物体在静止背景前移动时，盒子按背景速度取到"最宽"，正是那次 "greatly reduces
  ghosting" 的改动想消除的拖影又回来了。FRP 的边界修复不依赖它（静态相机下所有运动矢量都是 0，
  两种取法给出同一个盒子），而改它必须动 forward_plus 也在用的这份 shader，所以**保持与上游逐字节
  一致**：想修的话是一处 12 行的改动，或者让 FRP 走自己的 resolve。

* **整帧完全脚本化已打通**：引擎侧对缺失的必需条目只 `WARN_PRINT_ONCE`
  （`RendererSceneRender::_validate_frp_pipeline`），addon 侧由自定义 pass 的 `provides_native_ids`
  声明它接管了哪些必需 pass。声明齐全时校验零告警、`_normalize_native_entries()` 不再补条目；
  不声明时，不含任何引擎条目的列表按旧格式数组处理（重新种子化，引擎条目全部补回），因此不会
  静默产生残缺帧。实测（`misc/scripts/tests/frp_context.gd`）：单条目调度的 tokens 为 `[-1, -2]`、
  帧 0.4160 与引擎默认顺序 0.4160 一致，直接上传 `PackedInt32Array([-1])` 的裸路径同样 0.4160；
  未声明的同型调度被补回全部 5 个必需条目。
* **Stage C（C1/C2 已落地）**：能力通道（C1）让插件 pass 声明 `provides_native_ids` 后，引擎把该 pass
  当作帧的一部分（附件/特性标志/jitter 全部照旧）；pass 脚本化（C2）让默认调度完全由插件实现——
  8 个原生条目各持有 `implementation`（`passes/native/*.gd`，`FengNativePass`），脚本通过
  `ctx.run_pass(id)` 执行引擎的同一批 operation，条目因而以 provided 的形式上报、不再发引擎 token；
  清空 `implementation` 即回到引擎自带 pass（无插件项目的默认路径）。实测（`frp_context.gd`）：
  默认调度 8 条全是脚本、provided=[0,1,2,3,4,5,7]、token 全为自定义，与清空 implementation 的同一
  调度逐像素一致（changed=0）；引擎的"缺必需条目"警告现在把 provided 算作存在。
* `params` 逐 pass 暴露：pass 脚本自己的 `@export` 参数随资源进检查器已经可用；但引擎内部 shader
  仍不可逐 pass 替换，Core 原语的 options/params 通道还没有接到检查器（这是 C 剩下的部分）。
* **GI 的现状（已清空）**：SDFGI 与 VoxelGI 都不在 FRP 里。SDFGI：`sdfgi_update()` /
  `sdfgi_get_pending_region_count/bounds/cascade()` / `_render_sdfgi()` 是空的纯虚重载（返回"没有待
  更新区域"），引擎侧不会请求 SDFGI 区域渲染，Environment 里的 SDFGI 开关对 FRP 既不改画面也不再
  产生 GPU 工作。VoxelGI：G-buffer 的 voxel-GI 附件、`ensure_voxelgi()`、实例与探针配对、
  `use_voxelgi` 管线变体、`pair_voxel_gi_instances()` 的配对体全部删除（后者按引擎纯虚契约保留为
  空实现）。FRP 自己的 shader 里已经**没有** GI/SS 代码：SDFGI/VoxelGI 的采样块、GI buffer 混合、
  SSAO/SSIL/SSR 块、`#include "../scene_forward_gi_inc.glsl"` 与对应 uniform 声明（set 0 binding 14、
  set 1 binding 8/27/28/29/30/31/32/34/35/36）全部删除，uniform set 里也不再绑这些默认值。
  残留只有两处**引擎契约**要求的：`RendererRD::GI gi`（`RendererSceneRenderRD` 的基类成员，所有 RD
  渲染器都有）与 `RB_SCOPE_GI` 的 `RenderBuffersGI` 存储对象（体积雾的 compute uniform set 无条件
  绑定它，否则建不出 set；FRP 的 voxel GI 计数恒为 0，雾的 GI 注入不会执行）。
* **后处理的 tonemap 前后（已打通）**：`renderer_scene_render_rd.cpp` 里后处理与 tonemap 拆成了两段
  （`_render_buffers_post_process()` / `_render_buffers_tonemap(p_defer_present)`，合并入口保留），
  FRP 因此能暴露 `post_process()` / `tonemap()` / `tonemap_deferred()` / `present(texture)` 四个原语：
  pass 可以把自己的效果放在 tonemap 之前（写 HDR 帧缓冲）或之后（推迟 present、写自己的纹理、
  再 `present()`），并用 shader 关键字（specialization 常量）告诉 shader 自己在哪一侧。这是上游
  文件里的**一个**小触点（一次函数拆分），其它渲染器的行为不变。
