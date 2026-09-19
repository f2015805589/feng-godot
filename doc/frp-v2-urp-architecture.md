# FRP v2 — URP 式架构（Core 原语 + 插件 pass）

本文是 FRP 从"引擎内 21 条原生 pass"改为"引擎只留 Core 原语、全部 pass 由插件提供"的
设计契约。目标是：**升级引擎时只需要维护 Core 原语的小接口，pass 集与 pass 实现都在插件里。**

## 1. 与 URP 的对应关系

| URP / SRP | FRP v2 |
| --- | --- |
| SRP Core（原生：CullingResults、ScriptableRenderContext.DrawRenderers、材质/着色器绑定、CommandBuffer） | 引擎侧 `FRPCore`：几何提交（DrawRenderList）、环境/uniform 绑定、缓冲 ensure/get、shadow 预计算与灯光/Cluster 准备、deferred lighting、sky、透明、TAA、post/tonemap、resolve、VT 更新 |
| URP 包里的内置 pass（DrawObjectsPass、DepthOnlyPass、MainLightShadowCasterPass、ForwardPass、TransparentPass、CopyColorPass、FinalBlitPass…） | 插件 `passes/native/*.gd`：Shadow Precompute、VT、GBuffer、Lighting、Sky、Transparent、TAA、Post |
| `ScriptableRenderPass` / `ScriptableRendererFeature` | `FengPass`（同基类）+ `FengRenderer` 管线资源里的条目 |
| `UniversalRenderData`（管线资源，含每条 feature 的设置） | `FengRenderer` 资源：条目顺序、`enabled`、逐 pass `params` |
| `RenderingData` / `LightingData` 上下文 | `FRPPassContext`（脚本可见，持有当帧 RenderDataRD + 缓冲 RID） |
| Material/Shader 暴露参数 | 每条 pass 的 `params`（类型化、检查器可见）+ 引擎 shader 的 `global_shader_parameter` |

**边界说明**：留在引擎的只有 Core——它不做任何"渲染策略"决定。任何"画什么、按什么顺序、
开关是什么"都在插件里。Core 里不再有 pass 表、不再有 `run_builtin_pass` 的 switch。

## 2. Core 原语（引擎侧，脚本可见）

新增脚本类 `FRPPassContext`（`RefCounted`，注册到 ClassDB），当帧创建、逐条 pass 传递。
所有原语都是"薄包装"：内部复用 FRP 渲染器已有的实现，不含策略。

### 2.1 帧状态与缓冲

```gdscript
ctx.get_render_scene_buffers() -> RenderSceneBuffersRD
ctx.get_view_count() -> int
ctx.get_internal_size() -> Vector2i
ctx.get_frame_index() -> int

# 缓冲（缺失时按需创建；名字与 FRP 布局一致）
ctx.ensure_gbuffer(use_motion_vectors: bool) -> void
ctx.get_gbuffer_texture(name: StringName, msaa: bool, view: int) -> RID
ctx.get_depth_framebuffer(kind: int) -> RID        # DEPTH / ROUGHNESS / GBUFFER / GBUFFER_MOTION
ctx.get_color_framebuffer(separate_specular: bool, motion_vectors: bool) -> RID
ctx.get_velocity_only_framebuffer() -> RID
ctx.get_specular_only_framebuffer() -> RID
ctx.has_velocity_buffer() -> bool
```

### 2.2 提交与画 pass

```gdscript
# 一次几何提交（URP: ScriptableRenderContext.DrawRenderers + DrawingSettings）
ctx.draw_render_list(list: int, framebuffer: RID, pass_mode: int,
                     color_pass_flags: int, options: Dictionary) -> void

# 全屏 lighting（FRP 的核心：读 G-buffer 算光照写 color）
ctx.draw_deferred_lighting(options: Dictionary) -> void
ctx.draw_sky(options: Dictionary) -> void

# 准备：pass 0 绘制 shadow map；Lighting pass 准备灯光/Cluster buffer 与体积雾
ctx.precompute_shadows(options: Dictionary) -> void
ctx.prepare_lighting(options: Dictionary) -> void

# 时序与后处理
ctx.temporal_aa_and_upscale(options: Dictionary) -> void   # TAA / FSR2 / MetalFX
ctx.post_process_and_tonemap(options: Dictionary) -> void

# 解析与拷贝
ctx.resolve_msaa(target: int) -> void                      # COLOR / DEPTH / GBUFFER / VELOCITY
ctx.prepare_transparent() -> void                          # screen/depth copy + PRE_TRANSPARENT 回调
ctx.execute_virtual_texture_updates() -> void

# 合成器回调（CompositorEffect 阶段）
ctx.stage_compositor_effects(callback_type: int) -> void
```

FRP 没有屏幕空间效果（SSAO/SSIL/SSR）、全局光照（SDFGI/VoxelGI）与调试几何：它们不是 FRP 的 pass，
Core 表面不提供对应原语（早先版本曾把它们当可选条目，现已全部移除）。

枚举以常量形式挂在 `FRPPassContext` 上：`RenderList`、`PassMode`、`DepthFramebuffer`、
`ResolveTarget`、`ColorPassFlag`、`EffectStage`。插件不接触引擎内部的 bit 值。

### 2.3 参数

`options: Dictionary` 是 Core 原语唯一的参数通道，键即"暴露的 shader 参数"
（例：`draw_deferred_lighting({"use_separate_specular": true})`、
`temporal_aa_and_upscale({"blend": 0.1, "jitter": true})`）。未知键产生一条一次性警告，
不静默忽略。

## 3. 插件 pass 协议

```gdscript
@tool
class_name FengPass
extends CompositorEffect

@export var enabled := true          # 打开 = 该功能开启（TAA 打开就是开），关闭 = 不执行
@export var params := {}             # 逐 pass 暴露的参数，检查器可见，传给 _frp_execute
@export var shader: FengPassShader   # 可选：pass 自带 RD shader（全屏 compute/raster）

func _frp_execute(ctx: FRPPassContext) -> void:   # 引擎优先调用（存在即用）
    pass

func _render(buffers, view, rd) -> void:          # 兼容路径：手写 CompositorEffect
    pass
```

* 引擎执行管线条目时：若资源有 `_frp_execute`，传入 `FRPPassContext`；否则退回
  `_render_callback(stage, data)`（现有手写 CompositorEffect 不受影响）。
* `enabled == false` 的条目不进当帧执行，且**其对应的特性按关闭处理**
  （不再有"条目关了但 Viewport 开关还开着"的双控）。
* 顺序即依赖：管线里的位置就是执行位置，Validator 只做"必须存在的 pass 是否缺失"与
  "重复/非法 id"检查，不再替用户猜顺序。

## 4. Pass 集与 Operation 展开

一个 **Pass** 是管线资源里的条目（可开关、可排序）；一个 **Operation** 是渲染器内部的组合步骤。
Pass 展开成一个或多个 Operation，因此 resolve、屏幕/深度副本、高光合并、运动矢量
这些记账步骤不再是条目，但仍然照常执行。这一层拆分就是"21 → 8"能保持全部已验证渲染代码不变的原因。

**id 顺序就是执行顺序**：pass id 连续、按执行顺序编号，默认调度就是 `0,1,2,…,7`；渲染器按
**资源里的条目顺序**执行（与 URP 的 RendererFeature 列表一致），拖动条目即改变执行顺序，
依赖边只做校验、不替你重排。

**引擎条目（8 条，按执行顺序编号）**

| id | Pass | Operations |
| --- | --- | --- |
| 0 | Shadow Precompute | 绘制所有投影阴影的 shadow map（不读深度/G-buffer/材质页，所以排在最前） |
| 1 | VT Pass | 虚拟纹理页面更新 |
| 2 | GBuffer | G-buffer 绘制（含运动矢量） |
| 3 | Lighting | 灯光/Cluster/decal/体积雾准备 → PRE_LIGHTING 阶段 → deferred lighting + 次表面/分离高光合并 + 不透明附件 resolve |
| 4 | Sky | 天空 + 天空后 resolve |
| 5 | Transparent | 前向队列（不适合 G-buffer 的材质）+ 屏幕/深度副本 + 半透明 |
| 6 | Temporal AA | resolve（需要时）+ TAA/时序上采样 |
| 7 | Post Process / Tonemap | 最终 resolve + tonemap/后处理 |

**管线里的第 9 条不是引擎条目**：`Color Grade` 是插件库里的 pass，默认种子在 Temporal AA 与
Post Process 之间（位置 7）。它的 shader 与参数因此可以随插件更新而不改引擎——这正是 URP 里
"效果属于包"的形态。整条管线因此是 9 条：
`0 Shadow → 1 VT → 2 GBuffer → 3 Lighting → 4 Sky → 5 Transparent → 6 TAA → 7 Color Grade → 8 Post`。
一个新 FengRenderer 的列表**正好是这 9 条**：`DEFAULT_LIBRARY_SEEDED` 只包含 `library:color_grade`，
其余库模板（Tint / Blur / FXAA / Bloom-lite）不会推进任何 Renderer，只能从
**Add Pass from Library** 添加；Color Grade 与 Temporal AA 一样默认关闭（look 与画质是开关），
所以开箱即用的画面就是引擎自带 pass 的画面。

**没有可选效果条目**：SSAO、SSIL、SSR、全局光照（SDFGI/VoxelGI）与调试几何不是 FRP 的 pass。
FRP 不声明、不分配、也不合成它们的附件，`_setup_environment` 的 `ss_effects_flags` 恒为 0，
所以 Environment 里打开这些特性不会改变 FRP 的画面（实测开关它们帧间 delta 0.0000）。

顺序约束（Validator 只校验，不重排）：Shadow → Lighting、VT → GBuffer → Lighting、
Lighting → Sky → Transparent → TAA → Post。
"顺序即语义"：Color Grade 想放到 tonemap 之后，把条目拖到 Post 之后即可，不需要 shader 关键字。

## 5. 数据契约

* G-buffer：`normal_roughness`（10:10:10 直接法线 + roughness 在 `orm.g`）、`orm`
  （occlusion/roughness/metallic）、`albedo`、`emission`（specular 在 `.a`）、`depth`、
  `velocity`。运动矢量在 GBuffer pass 内产生（同一遍几何）。
* 颜色 framebuffer 变体：`separate_specular` × `motion_vectors`，用
  `COLOR_PASS_FLAG_*` 表达，插件通过 `get_color_framebuffer()` 获取，不自己拼附件。
* MSAA：resolve 由 Core 原语负责；插件只需在需要 resolved 数据前调用 `resolve_msaa()`。

## 6. 迁移阶段与状态

* **A1 已落地** 运动矢量并入 GBuffer：新的 G-buffer shader 变体（速度写在 location 5），
  `DEPTH_FB_GBUFFER_MOTION`，独立 Motion Vectors 几何 pass 删除。TAA/FSR2/debug-MVS 下不再有
  第二遍不透明几何。验证：`test_frp_pipeline.py --driver d3d12` 全绿，并由 `frp_taa.gd` 的
  **draw call 守卫**锁死（TAA 与运动矢量调试视图相对无 TAA 基线的新增 draw call ≤ 2，且计数器本身非零
  以保证断言不空转；A1 之前这两者都会重画一遍不透明几何）。
* **A2 已落地** Pass/Operation 分层，21 条原生条目收敛为 8 个引擎 Pass + 5 个默认关闭的可选条目
  （D1 已把这 5 个可选条目全部删除，见下）；
  Color Grade 变成插件 pass；repair 逻辑只剩 TAA 一条；插件 schema 5 迁移（旧 id 折叠、开关与自定义
  条目位置保留）。验证：套件全绿（import/gpu/taa/toggles/gi/editor），forward_plus 探针与本轮改动前
  完全一致（none 0.1415 / taa 0.1442 / fsr2 0.1435 / debug_mvs 0.1455）。
* **B2 已落地** TAA 条目成为唯一开关：`RendererViewport` 在把相机的合成器管线读出来后决定 jitter
  相位（条目在 → 16，条目不在 → 0；时序上采样器自带 jitter 时不覆盖，且只在 FRP 是当前渲染器时
  生效），FRP 侧 `using_taa` 同样跟随条目。最后那条 repair 已删除。验证：`frp_taa.gd` 断言
  "条目关闭 ⇒ 帧与无 TAA 基线逐像素相同"、"条目打开且 `Viewport.use_taa` 关闭 ⇒ TAA 真正开启"。
* **B 进行中** `FRPPassContext` 已落地：脚本可见的 Core 原语（shadow 预计算 / VT / GBuffer / 运动矢量 /
  延迟光照 / 次表面与高光合并 / 不透明 resolve / Sky / Sky resolve / 前向队列 / 屏幕与深度副本 /
  半透明 / TAA 与上采样 / 最终 resolve / 历史 / tonemap / SSAO·SSIL·SSR·GI / Debug 几何 / `run_pass` /
  `stage_compositor_effects`）全部转发到引擎内置 pass 调用的同一批 operation；条目执行时若资源实现了
  `_frp_execute(ctx)` 就走脚本路径（`FengPass` 默认转发回 CompositorEffect 回调，所以现有 pass 不受影响）。
  实测：脚本 pass 通过 Core 原语接管引擎条目时**与内置条目逐像素一致**——Sky 接管 0.4160 vs 内置
  0.4160（对照：条目关且无脚本 pass 时 0.0628），Transparent 接管 0.4160 vs 0.4160（对照 0.4087，
  证明透明 quad 的贡献确实被脚本复现）。第 4~5 轮报告过的"Sky/Transparent 接管差异"经查是**测试自身的
  问题**：测试用的 renderer 没有关掉种子库里的 tint/blur/fxaa/color-grade/bloom，比较对象因此带着库观感；
  排除后差异消失，Core 原语不需要额外的 `prepare_sky()` 之类补丁。
  "整帧完全由脚本驱动"也已打通：引擎对缺失的必需条目只警告，addon 侧由自定义 pass 的
  `provides_native_ids` 声明接管，实测单条目调度（tokens `[-1, -2]`）与引擎默认顺序逐像素一致
  （0.4160 vs 0.4160）；未声明的同型调度会被当作旧格式数组重新种子化，条目全部补回。
  **能力通道**（C1，已落地）：调度除 token 外还带一份插件提供的 pass id 集
  （`compositor_set_frp_pipeline` 第 4 参数），引擎的 `schedule_has(6)` 与视口 jitter
  都把它算作"该 pass 在帧里"，因此插件删掉引擎条目后附件与特性标志不会被关掉。验证：插件 pass
  声明 4 并调 `run_pass(4)` 跑 Sky 与内置条目逐像素一致（control 0.6561，
  takeover 0.0000）；同一 pass 在声明 6 前后帧不同（TAA + jitter 生效）；forward_plus
  探针证明该规则仍在渲染方法守卫内（forward_plus 挂上 FRP 调度后仍按自己的 jitter 抖动，
  none 0.2282 / taa 0.2292 / fsr2 0.2294 / debug_mvs 0.2314，控制组与挂调度组的
  帧间差异分别是 279 与 278 像素）。
* **C 进行中** 8 个引擎 Pass 变成插件 pass 脚本，`params` 暴露与检查器，原生 token 降级为兼容迁移路径。
  C1（能力通道）已完成，见上。**C2（pass 脚本化）已落地**（schema 6）：8 个引擎条目各自持有
  `implementation`（`passes/native/*.gd`，基类 `FengNativePass`，与自定义 pass 同一个 `FengPass` 基类），
  默认由脚本通过 `ctx.run_pass(id)` 驱动并把该 pass 作为 provided 上报，引擎不再为它发 token；
  清空 `implementation` 即退回引擎自带 pass。验证：默认调度 8 条全部为脚本、provided=[0,1,2,3,4,5,7]、
  token 全为自定义、与"清空 implementation 的同一调度"**逐像素一致**（changed=0）；引擎侧对
  "缺必需条目"的警告现在会把 provided 算作存在，所以默认管线不再报缺 VT Pass。
  剩下的是 `params` 通道：引擎内部 shader 仍不可逐 pass 替换，Core 原语的 options 未接检查器
  （pass 脚本自己的 `@export` 参数已经可用）。
* **C3 已落地（逐 pass 参数 + Volume）**：pass 脚本用 `get_frp_parameters()` **选择暴露**哪些参数
  （带类型的 `@export`，检查器里就是这几个字段），条目上的 `pass_parameters` 是覆盖层，运行时的
  `FengVolume`/`FengVolumeProfile` 是最高层。参数随调度（`compositor_set_frp_pipeline` 第 5 个参数）
  交给引擎，`FRPPassContext.get_pass_parameters(id)` 让 pass 脚本读自己的参数。第一个引擎消费者是
  Temporal AA 的 `jitter_phases`（1 冻结抖动采样、16 默认；`RendererViewport` 读取）。验证：
  `frp_taa.gd` 实测 declared 0 / authored 48 / overridden 0 像素帧间差异，Volume 进出时 0 vs 48。
  Volume 是 FRP 自己定义的类型（不碰引擎的 Environment）；第一版只做参数覆盖 + priority/weight 混合，
  逐参数混合模式与"用 Volume 开关 pass"待后续。
* **C4 已落地（pass 自带 shader + 虚幻式体积控制）**：引擎 pass 的脚本可以带 `overlay`
  （一个 `FengShaderPass`），运行位置由脚本决定，overlay 的 `inputs`/`outputs`/附件标志作为该条 pass 的
  资源契约（`get_contract_source()`）交给引擎与纹理管理器。验证：`frp_context.gd` 的 Post 实现
  在 resolve/history 与 tonemap 之间跑 tint overlay（luma 0.3653 vs 原样 0.4160），移除 overlay 后
  与原样逐像素一致。体积补齐虚幻 Post Process Volume 的语义：`unbound`（全局）、
  `blend_distance`（边缘权重渐变）、`priority`、`weight`、`enabled`，只有 profile 里列出的参数才覆盖
  （即逐字段 override）。验证：`frp_taa.gd` 实测 unbound 在盒外仍生效、blend distance 把
  `jitter_phases` 混成 13.0（16→1 的 20%）。
* **C5 已落地（体积开关整条 pass）**：`FengVolumeProfile.enabled_passes` / `disabled_passes` 让体积在
  运行时开关任意条 pass，作者态不被修改；调度、`compositor_effect_set_enabled` 与交给引擎的 provided
  集合都走 `_is_entry_enabled()`（作者 enabled + 体积覆盖），所以默认关闭的 Temporal AA 可以在某个区域
  打开（`schedule_has` 也跟着变）。布尔不插值：影响 ≥ 0.5 生效，同优先级 enabled 覆盖 disabled；
  必需条目被关掉仍按"不完整调度"报警。验证：`frp_taa.gd` 里体积关 Temporal AA 后帧与无 TAA 基线
  逐像素一致、作者态保持 enabled；反向（作者关、体积开）帧重新出现 TAA。

* **D1 已落地（移除与 FRP 无关的 pass）**：SSAO、SSIL、SSR、全局光照（SDFGI/VoxelGI）与调试几何这 5 条
  条目连同它们的 operation、`FRPPassContext` 原语、addon pass 脚本、依赖边与测试套件全部删除。
  引擎条目从 13 条收敛为 8 条，`DEFAULT_PASS_ORDER` 从 13 项收敛为 8 项，`Operation` 枚举从 21 项收敛为
  16 项（`case` 标签改为符号名，不再依赖数字）。`_setup_environment` 的 `ss_effects_flags` 恒为 0，
  帧循环里的 `using_ssao/ssil/ssr/sdfgi/voxelgi` 恒为 false，因此光照 shader 对这些附件始终用引擎默认
  （黑色）纹理。旧资源里携带这些 id 的条目在迁移时被丢弃（`LEGACY_NATIVE_ID_MAP` 不再包含 6/17/18/19/20）。
  验证：`frp_lighting_toggles.gd` 断言"Environment 打开 SSAO/SSIL/SSR 后帧与关闭时 delta 0.0000"、
  "8~12 号条目不再可授权"，`toggles` 套件绿；`frp_gi.gd` 与 `gi` 套件已删除。
  注：`frp_clustered/` 里从 forward_clustered 复制过来的 SS/GI 实现函数（`_process_ssao` 等）已随后删除
  （见 D4/D7/D8）；只剩引擎纯虚接口要求的 no-op 重载（`environment_set_ssao_quality()` 等）与 SceneState
  UBO 里必须与 shader 对齐的字段。

* **D2 已落地（id 顺序 = 执行顺序 + shadow 预计算成为 pass 0）**：pass id 连续且就是执行顺序，
  `DEFAULT_PASS_ORDER` 就是 `{0,1,2,3,4,5,6,7}`，资源里的条目顺序即引擎执行顺序（和 URP 的
  RendererFeature 列表一致，拖动条目就改顺序，依赖边只校验）。"光照预计算"只包含**绘制 shadow map**
  （`OP_SHADOW_PRECOMPUTE` / `ctx.precompute_shadows()`）：它不读场景深度、G-buffer 或材质页，
  所以排在 VT 与 GBuffer 之前；灯光/Cluster buffer、decal 与体积雾属于 Lighting pass
  （`OP_LIGHTING_PREPARE` / `ctx.prepare_lighting()`），PRE_LIGHTING compositor 阶段也在 Lighting
  pass 内（G-buffer 写入之后）。Color Grade 的种子位置从 Temporal AA 之前改到 Temporal AA 与 Post
  之间，管线因此正好是 9 条、顺序与编号一致。实测：`frp_lighting_toggles.gd` 新增
  "Shadow Precompute 画出了阴影（阴影开关 delta 0.1017）"与"插件 pass 声明 0 并调
  `ctx.precompute_shadows()` 与内置条目逐像素一致（delta 0.0000）"；`frp_passes.gd` 断言
  `spec.default_order == [0..7]`、mandatory `== [0,1,2,3,7]`、库条目位于 TAA 与 Post 之间。
* **D3 已落地（默认列表就是这 9 条）**：`DEFAULT_LIBRARY_SEEDED` 只把 `library:color_grade` 放进新
  Renderer 的默认列表，其余库模板改成"只在 Add Pass from Library 时进入"，
  `DEFAULT_LIBRARY_SEEDED` 之外的模板不再被 `_sync_library` 推进已有资源。实测（探针）
  新 Renderer = 9 条：`Shadow / VT / GBuffer / Lighting / Sky / Transparent / Temporal AA(关) /
  Color Grade(关) / Post`；默认开启的是 7 个引擎条目，默认画面与引擎自带 pass 一致。
  注：Color Grade 的模板默认参数是暖色调 look（`Vector4(1.1,1.05,1.02,1.0)`），所以它随
  Temporal AA 一起默认关闭——要默认开启只需把它的 `enabled` 置 true。

* **D5 已落地（SDFGI 彻底删除）**：SDFGI 从 `frp_clustered` 移除——不再创建/更新/渲染 cascade、不再
  设置 `use_sdfgi` 管线变体与 SDFGI 深度 pass、不再绑定 lightprobe/occlusion 纹理、不再有 SDFGI 调试
  视图、不再维护 instance 的 `can_sdfgi` 与 framebuffer 缓存。引擎要求的纯虚重载
  （`sdfgi_update()`、`sdfgi_get_pending_region_count/bounds/cascade()`、`_render_sdfgi()`）保留为
  空实现/返回"没有待更新区域"，`RendererSceneCull` 因此永远不会请求 SDFGI 区域渲染。
  行为影响：**在 Environment 里打开 SDFGI 现在既不改画面、也不再让 FRP 白跑一遍 SDFGI 的 GPU 工作**
  （之前 `_update_sdfgi()` 会真的渲染 cascade）。验证：scons 重建 + 全套件（含 forward_plus 对照）绿。
  剩下的是 VoxelGI（与 G-buffer 的 voxel-GI 槽耦合）与 `render_scene_buffers_rd` 的分离粗糙度契约，
  随后分别由 D8 与 D7 处理。
* **D4 已落地（SS 死代码删除 + 半透明 forward+ 锁定）**：SSAO / SSIL / SSR 的生成代码、
  `ss_effects_data` 附件状态、`RB_SCOPE_SSAO/SSIL/SSR` 清理由、调试视图与 uniform set 里的附件查找
  全部从 `frp_clustered` 删除（光照 shader 的 sampler 27/34/35/36 恒绑黑色默认纹理）；
  `environment_set_ssao_quality()` / `ssil_quality()` / `ssr_half_size()` 保留为 no-op 重载
  （`RendererSceneRender` 声明为纯虚，`forward_mobile` 同样处理）。半透明与不透明前向 fallback
  **本来就是 forward+ 逐物体聚簇光照**：FRP 的透明绘制与 `forward_clustered` 的那一行完全相同
  （同一 render list、`PASS_MODE_COLOR`、同一 uniform set），读的就是 Lighting pass
  `bake_cluster()` 的 cluster 灯光列表，没有再跑一遍全屏光照或第二遍几何。验证：新增
  `frp_transparent.gd`（红点光照亮透明 quad 1.0/0.4235/0.4235，关灯回到 0.4235 灰，光源移出范围
  delta 0.0000，显示 quad 只增加 **1** 个 draw call：opaque 1 → 2）。

* **D6 已落地（后处理可控在 tonemap 前/后 + shader 关键字）**：引擎的
  `_render_buffers_post_process_and_tonemap()` 拆成 `_render_buffers_post_process()`（glow / DoF /
  自动曝光 / AA 预处理）与 `_render_buffers_tonemap(p_defer_present)`（tonemap + SMAA + 缩放/present）；
  合并入口保留并调用两段，所以其它渲染器行为一字不变（全套件回归通过）。FRP 侧新增 Core 原语
  `post_process()` / `tonemap()` / `tonemap_deferred()` / `present(texture)`（Post 条目的 operation 也
  随之拆成 `OP_POST_PROCESS` + `OP_TONEMAP`）。插件侧：`Post Process / Tonemap` 的 pass 脚本用
  `overlay_after_tonemap`（逐 pass 参数，可被管线资源或 Volume 切换）决定 overlay 跑在 tonemap 前
  （写进 HDR 帧缓冲，被 tonemap 读取）还是后（`tonemap_deferred()` → overlay 写自己的纹理 →
  `present()` 呈现），并通过 **shader 关键字**（specialization 常量 0 `POST_AFTER_TONEMAP`）告诉 overlay
  自己在哪一侧；`FengShaderPass` 新增 `shader_keywords` / `set_shader_keyword()`（关键字变化重建
  pipeline），`FengPassTexture.Source.TONEMAPPED` 用来读引擎 tonemap 后的图像。
  实测（新增 `frp_post.gd`）：同一个 overlay shader 在前位得到 AgX 处理过的红
  `(0.8706, 0.251, 0.1098)`、在后位得到原样呈现的纯绿 `(0.0, 1.0, 0.0)`、移除 overlay 恢复引擎画面
  `(0.7098, 0.7098, 0.7098)`。

* **D7 已落地（split-roughness 机制删除 → 共享文件回到上游形态）**：fork 为了让 GI 解码 FRP 的
  "粗糙度在 `orm.g`" 布局，在共享文件里加了一套 split-roughness 机制（`RenderSceneBuffersRD` 的
  `set_separate_roughness_target()`/`has_separate_roughness()`、`gi.cpp` 的第二套 pipeline 变体与
  binding 20、`gi.glsl` 的 `sc_split_roughness` 分支）。FRP 现在完全不跑 GI，这套机制没有任何消费者，
  因此整体删除：`render_scene_buffers_rd.{h,cpp}` **与 HEAD（上游形态）零差异**，
  `gi.{h,cpp}` + `gi.glsl` 相对 HEAD 反而**少了 53 行 fork 代码**（更接近上游）。
  rebase 触点表因此少了两行（那两个文件不需要再同步）。验证：scons 重建 + 9 个套件（含
  forward_plus 对照）全绿；`forward_clustered/` 与 `shaders/forward_clustered/` 仍逐字节一致。

* **D8 已落地（VoxelGI 从 FRP 彻底删除 → G-buffer 少一个附件）**：FRP 的 G-buffer 原来照抄
  `forward_clustered`，多带一个 voxel-GI 附件（`RB_TEX_VOXEL_GI`，每帧分配 + 每帧作为 framebuffer
  第 5 个颜色附件 + 运动矢量因此排在 location 5）。现在整条链路删除：G-buffer framebuffer 只剩
  4 个附件（normal_roughness / albedo / orm / emission），运动矢量 shader 输出从 location 5 回到
  **location 4**（材质 pass 仍占 4，其运动矢量留在 5，两种组合不会同时编译）；`MODE_RENDER_VOXEL_GI`
  不再出现在 GBUFFER 与 GBUFFER+MOTION 两个变体里；`ensure_voxelgi()` / `get_voxelgi*()` /
  `DEPTH_FB_ROUGHNESS_VOXELGI` / `PASS_MODE_DEPTH_NORMAL_ROUGHNESS_VOXEL_GI` / `_setup_voxelgis()` /
  `GeometryInstanceFRPClustered::voxel_gi_instances[]` / 每个实例的 probe 配对与
  `INSTANCE_DATA_FLAG_USE_VOXEL_GI`|`USE_SDFGI` / `GlobalPipelineData.use_voxelgi` / FRP 对 voxel GI 管线
  变体的请求  全部删除；`pair_voxel_gi_instances()` 按引擎纯虚契约保留为空实现。uniform set 里两处
  voxel GI 绑定（set 1 binding 8 的探针纹理数组、binding 32 的实例 UBO）改成恒绑引擎默认值——shader
  的 voxel GI 采样路径因此不可达（`_fill_render_list` 不再给任何 surface 打 `uses_forward_gi`）。
  顺带修掉一个**潜在编译错误**：`scene_frp_clustered_inc.glsl` 的 `NORMAL_USED` 判定里没有
  `MODE_RENDER_GBUFFER`，G-buffer 变体此前是靠 `MODE_RENDER_VOXEL_GI` 顺带把 `NORMAL_USED` 打开的；
  去掉它之后 G-buffer 的 decal 代码会因为 `geo_normal` 未声明而编译失败，所以判定条件里显式
  加上 `defined(MODE_RENDER_GBUFFER)`（G-buffer 本来就写 normal，语义正确）。实测：第一次重建后
  import 阶段报 `'geo_normal' : undeclared identifier`，加上这一条后 9 个套件全绿。
  行为影响：**每帧少分配一张 R8G8_UINT（MSAA 时两张）渲染目标、G-buffer framebuffer 少一个附件、
  不再有每实例的 probe 查找与 VoxelGI 实例更新**；画面不变（voxel GI 在 FRP 里本来就是死路径）。
  残留（诚实记录）：`RendererRD::GI gi` 成员仍在，只服务三处引擎共享 shader 声明的死绑定——
  体积雾的 `settings.gi`/`settings.rbgi`、光照 shader set 0 binding 14 的 `gi.sdfgi_ubo`、
  `SDFGI_OCT_SIZE` define；SDFGI 的空纯虚重载仍在。这些都不产生 GPU 工作，但要清掉得连
  `scene_frp_clustered_inc.glsl` 的 SDFGI/voxel-GI uniform 声明一起删。
  验证：scons 重建 + 9 个套件全绿（含 GBuffer 逐像素对照与 forward_plus 对照）；
  `forward_clustered/` 与 `shaders/forward_clustered/` 仍逐字节一致。
  另一处残留（不影响运行）：`scene_shader_frp_clustered` 的变体表里仍留着
  `SHADER_VERSION_DEPTH_PASS_WITH_NORMAL_AND_ROUGHNESS_AND_VOXEL_GI(_MULTIVIEW)` 两个变体与对应的
  `PIPELINE_VERSION_*` 枚举值，但已经没有任何代码请求它们（删掉要重排变体编号，收益只有省两次编译）。

* **D9 已落地（FRP 自己的 shader 里再也没有 GI / SS 代码）**：D7/D8 之后 FRP 已经不再产生 GI
  工作，但 `frp_clustered` 的 shader 仍带着从 `forward_clustered` 抄来的 SDFGI / VoxelGI / GI buffer /
  SSAO / SSIL / SSR 采样代码与 uniform 声明（靠 `ss_effects_flags == 0` 和恒为 0 的实例标志在运行时
  短路）。这一轮把它们整段删除：
  - `scene_frp_clustered.glsl`：删掉 SDFGI 采样块、VoxelGI 采样块、GI buffer 混合块、SSAO/SSIL/SSR 块，
    以及 `#include "../scene_forward_gi_inc.glsl"`（`sdfgi_process()` / `voxel_gi_compute()` 的来源，
    该文件本身是共享文件，保持上游原样）、`MODE_RENDER_VOXEL_GI` 的两个输出槽与两个写出块。
  - `frp_lighting.glsl`：删掉 GI buffer / SSAO / SSIL / SSR 块；间接光只剩环境光与聚簇反光探针。
  - `scene_frp_clustered_inc.glsl`：删掉 SDFGI UBO（set 0 binding 14）、`SDFVoxelGICascadeData`、
    `VoxelGIData`、`voxel_gi_textures`（set 1 binding 8）、`voxel_gi_instances`（32）、
    `sdfgi_lightprobe_texture`（30）、`sdfgi_occlusion_cascades`（31）、`ao_buffer`/`ambient_buffer`/
    `reflection_buffer`（27/28/29）、`ssil_buffer`/`ssr_buffer`/`ssr_mip_level_buffer`（34/35/36）、
    对应的一批 `INSTANCE_FLAGS_*` / `SCREEN_SPACE_EFFECTS_FLAGS_*` 宏与 `sc_use_forward_gi()`。
  - C++：uniform set 里这 10 个 binding 全部删除（不再需要"绑默认值让死代码合法"），
    `SDFGI_OCT_SIZE` define 与 `gi.` 的最后一处调用（`enable_vrs_shader_group()`）删除，
    体积雾改成 `settings.gi = nullptr`（SDFGI 从未创建、voxel GI 计数恒为 0，fog 不会解引用它）。
  - 变体表：删掉 `..._WITH_NORMAL_AND_ROUGHNESS_AND_VOXEL_GI(_MULTIVIEW)` 两个死变体并重排
    `ShaderVersion`（`SHADER_VERSION_COLOR_PASS` 10 → 8，motion 变体 52 → 48）与 `PipelineVersion`，
    同时把 `blend_state_gbuffer`/`_motion` 的附件数从 5/6 修正为 **4/5**（与 D8 少一个附件后的实际
    G-buffer 一致）。
  行为影响：**间接光与阴影/直光不变**（这套代码在 FRP 里本来就不可达），收益是 FRP 的 shader 与
  uniform set 里不再有 GI/SS 的一行代码，rebase 时不必再跟着上游的 GI 改动同步这 10 个 binding。
  实测：scons 重建 + 9 个套件全绿（toggles/transparent/post 都是逐像素对照，且 SSAO/SSIL/SSR/SDFGI
  的 inertness 断言仍是 delta 0.0000）；`forward_clustered/` 与 `shaders/forward_clustered/` 零差异。
  残留（诚实记录）：`RendererRD::GI gi` 是 **引擎基类**（`RendererSceneRenderRD`）的成员，所有 RD
  渲染器都有，不属于 FRP；FRP 侧只剩 `RB_SCOPE_GI` 的 `RenderBuffersGI` 存储对象——引擎的体积雾
  compute uniform set 无条件绑定 voxel GI 实例 buffer 与纹理数组，必须有这个对象才能建 set
  （FRP 的 voxel GI 计数恒为 0，所以雾的 GI 注入路径不会执行）。另外 `ImplementationData` 里的
  `ss_effects_flags` / `ssao_*` / `gi_upscale_for_msaa` 字段与 specialization 的 `use_forward_gi` 位
  仍然存在（shader 与 C++ 都声明了、布局必须一致），但已无人读取。

每阶段的验证：`scons platform=windows target=editor arch=x86_64` 重建 +
`python misc/scripts/test_frp_pipeline.py --driver d3d12`（import/gpu/taa/toggles/transparent/post/context/editor/forward_plus）全绿 +
forward_plus 对照不回退。
