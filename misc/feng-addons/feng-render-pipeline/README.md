# Feng Render Pipeline

FRP 使用 `FengRenderer` 资源编排原生渲染操作与插件 Pass，使用 `FengCompositor`
连接 Camera3D、WorldEnvironment 或项目默认管线。资源中的列表顺序就是执行顺序。

## 开始使用

1. 将 `rendering/renderer/rendering_method` 设为 `frp`，启用 Feng Render Pipeline 插件。
2. 创建 `FengRenderer`，再创建引用它的 `FengCompositor`。
3. 将 Compositor 赋给 Camera3D、WorldEnvironment，或下文的项目设置。
4. 在 Inspector 的 Passes 数组中编辑参数、Enabled 和顺序。工具菜单
   **Add Pass from Library** 可添加库效果；添加、删除和排序支持 UndoRedo。

### 项目默认管线

**Project Settings → Rendering → Renderer → Compositor** 接受 `FengCompositor`
或 `FengRenderer` 的 `.tres` / `.res` 路径。裸 Renderer 会自动包装为 FengCompositor。

```ini
[rendering]
renderer/compositor="res://render/main_compositor.tres"
```

该设置在 `frp` 渲染方法下显示。插件通过编辑器桥接与 `FengProjectPipeline` autoload
为编辑器 3D 视图和游戏根视口安装默认世界 compositor。优先级是：

**Camera3D compositor → 场景 WorldEnvironment compositor → 项目默认管线**。

项目管线会让位于同一世界中的场景 compositor，并在其移除后恢复。
编辑器自由视角有自己的相机；仅给场景 Camera3D 设置 compositor 只影响该相机。
仅创建或选中 Renderer 资源不会应用管线。清空项目设置可停止安装默认管线；
autoload 注册保留在项目中，可在不需要插件运行时服务时手动移除。

## 默认管线

新 Renderer 包含 **9 个原生条目和 8 个库条目，共 17 个**。
仅 Debug Buffers 默认关闭，其余条目默认开启；已保存资源保留自己的开关和参数。

```text
Shadow → VT → GBuffer → Cloud Shadows → Lighting → Magic GI → Sky
       → Volumetric Cloud Trace → Height Fog → Volumetric Cloud → Transparent
       → Temporal AA → Eye Adaptation → Bloom → Color Grade → Post Process → Debug Buffers
```

原生 ID 是持久身份，列表位置决定执行顺序。原生默认顺序为 `0,1,2,3,4,5,6,8,7`：
Post Process 保持 ID 7，Bloom 使用 ID 8。

| ID | 原生条目 | 工作 |
|---|---|---|
| 0 | Shadow Precompute | 绘制光源阴影贴图 |
| 1 | VT Pass | 执行已注册的虚拟纹理页面生产和材质烘焙 |
| 2 | GBuffer | 写入不透明材质、深度及按需启用的运动矢量 |
| 3 | Lighting | 准备灯光、Cluster、decal 和体积雾；执行 Pre Lighting 回调、延迟光照、次表面/高光合并与不透明附件 resolve |
| 4 | Sky | 绘制天空并 resolve 附件 |
| 5 | Transparent | 绘制前向 fallback 材质，准备屏幕/深度副本，再绘制透明物体 |
| 6 | Temporal AA | TAA 与时序上采样 |
| 7 | Post Process / Tonemap | 最终 resolve、历史副本、后处理、色调映射与输出 |
| 8 | Bloom | 准备 Environment Glow 纹理，交给 Tonemap 合成 |

Pass 是可排序的资源条目；Operation 是条目内部的渲染步骤。resolve、副本和高光合并由
所属 Pass 执行。GBuffer 在同一遍几何中写运动矢量，velocity 位于 shader location 4。
前向 fallback 与透明物体使用 Lighting 准备的 Cluster 灯光列表。

### 顺序与开关

校验器检查依赖，不自动重排：Shadow → Lighting；VT → GBuffer → Lighting → Sky →
Transparent → Temporal AA → Bloom → Post Process。可选条目关闭时跳过其依赖边；
Transparent 和 Eye Adaptation 也必须先于已启用的 Bloom。自定义纹理先生产、后消费。

完整帧必须提供 ID `0,1,2,3,7` 的工作。可通过原生条目或声明接管的自定义 Pass 提供。
无效配置会显示告警，保留上一次有效调度并暂停不安全的自定义效果；修正后恢复。

有显式 FRP 管线时，Temporal AA 条目同时控制 TAA 和视口 jitter。
`jitter_phases` 默认 16，设为 1 可冻结采样位置。项目/视口的 `use_taa` 只用于没有
FRP 管线的视口。FSR 2 / MetalFX 使用自己的 jitter，与 TAA 互斥；即使关闭 Temporal AA
条目，上采样结果也会在 Bloom 或 Post Process 消费前生成。

### 默认库效果

- **Magic GI**：在 Lighting 后把有效 surface PRT 烘焙与当前太阳/环境 SH 组合为漫反射间接光。
  按当前 render target 匹配快照；没有匹配的有效烘焙时保持场景色不变，贡献纹理清零。
  光照变化更新 SH，无需重烘焙。烘焙由可选的 feng-magic-gi 插件提供。
- **Cloud Shadows**：在 GBuffer 后准备云阴影与 Sky AO；组件上的两项功能默认关闭。
- **Volumetric Cloud Trace**：在 Sky 后追踪云辐射、透射和深度；**Volumetric Cloud** 在
  Height Fog 后合成，透明表面可通过材质的 Cloud Fogging 参与深度相关云传输。
  三个阶段消费可选 feng-cloud 的同世界快照，缺少有效云源时跳过。
- **Height Fog**：位于 Sky 后，消费匹配世界的雾与大气快照。大气的准备数据通过帧前钩子
  交给原生光照；天空后的 compute 处理 opaque 像素，前向材质使用自身片元位置合成。
- **Eye Adaptation**：在 TAA 后、Bloom 前测量 HDR 场景色。支持 Histogram、Basic、Manual，
  Volume 模块提供测光范围、速度、补偿、曲线、遮罩及手动相机参数。
- **Color Grade**：位于 Bloom 与 Post Process 之间，默认参数 `(1,1,1,1)` 为中性值。
- **Debug Buffers**：位于 Post Process 后，显示 albedo、view-space normal、AO、roughness、
  metallic、运动矢量或 Magic GI 贡献。关闭时不分配自己的输出纹理。

Tint、Blur H/V、FXAA 和 Bloom-lite 是按需添加的模板，添加后默认关闭。
FXAA 使用独立源颜色副本读取邻域；Blur 和 Bloom-lite 的缩放输出覆盖完整画面。

### 曝光与 Bloom

Eye Adaptation 的 `extend_default_luminance_range` 选择传统亮度或 EV100 范围；
`pre_exposure` 使用上一帧完成的曝光值编码场景 HDR 颜色。补偿 CurveTexture 的 X 轴
0–1 对应 -10–20 EV100。启用项目物理光照单位时，FRP 点光、聚光与矩形光使用其 UE 式单位换算。

Bloom 条目控制 Glow 准备，Environment 的 Glow 开关、levels、strength、blend mode、
intensity 和 glow map 配置效果。默认在 DoF 前准备 Glow，并在 Tonemap 合成。
关闭 Bloom 条目会关闭该帧的 Glow 合成。

### UE Film Tonemap

FRP 的现有 **Post Process / Tonemap** pass 默认使用 **Unreal Filmic (ACES)**：固定的 UE 5.8
SDR/Rec.709 Film 曲线（ACES 派生），不增加 Pass ID 或改变执行顺序。可在该 pass 或 Volume
中选择 `Inherit Environment`（`-1`）恢复 Environment 色调映射，或显式选择原生 Linear、
Reinhard、Filmic、ACES、AgX。该选项是 SDR Film 输出变换；它不提供 PQ/HLG 或 UE HDR Display ODT。
即使目标纹理以线性 HDR 格式存储，也仍应用这套 SDR Film 曲线。

Film 曲线使用按需生成并缓存的 32³ LUT；HDR 高光 headroom 保留在 LUT texel 中。采样后解码回
线性空间，交给现有输出编码路径做一次最终 gamma 转换。启用 Bloom 时，此模式在曲线前以
Additive 方式合成 Bloom；Bloom 生成、强度和其它 pass 的设置仍由现有配置控制。

TAA 按当前/历史 pre-exposure 比例重标定历史颜色；Bloom 的亮度阈值也使用一致的曝光空间。
切换 pre-exposure 只改变 HDR 缓冲编码范围，Glow 参数含义保持一致。时序历史、异步曝光读回
随视口缓冲管理；resize、compositor 切换与相关开关变化会使旧状态失效。立体视图使用 view 0
的场景 pre-exposure。

### 渲染范围

FRP 原生光照支持环境光和聚簇反射探针，插件可通过 Magic GI 增加烘焙间接光。
Environment 的 SSAO、SSIL、SSR、SDFGI、VoxelGI 以及原生调试几何不属于 FRP 管线；
开启这些选项不会为 FRP 生成对应效果。材质与缓冲调试使用 Debug Buffers。

## 编写 Pass

### 执行与纹理

- 继承 `FengPass`，实现 `_frp_execute(ctx: FRPPassContext)` 调用 Core 原语，或实现
  `_setup(rd)`、`_render(buffers, view, rd)`、`_cleanup(rd)` 编写 RenderingDevice 效果。
- `FengShaderPass` 支持 Compute 和全屏 Raster，可配置 `shader_file`、vec4 `parameters`、
  工作组、纹理输入输出及目标。
- `FengPassTexture` 声明 Color、Depth、GBuffer、Motion Vectors、Tonemapped、管线纹理或
  自定义 scope。`custom_name` 指定管线/自定义纹理名。
- `FengPassOutput` 用 `name`、`data_format`、`usage`、`scale` 声明输出。
  隐藏的 Texture Manager 在 `frp_pipeline` scope 分配纹理，并随内部尺寸重建。
- `Source.COLOR` 是内部 HDR 场景色。处理它的效果通常放在 Lighting 后、Tonemap 前。
  同一 Pass 的 storage-image 绑定可引用自身输出；邻域采样应使用独立输入纹理。

在 FengRenderer 中，`stage` 保留为回调参数和旧资源迁移提示，位置由列表决定。
普通 Compositor 仍按回调阶段执行。显式管线会在自定义 Pass 所需位置 resolve 附件，
并将颜色写回 MSAA 附件；普通 Compositor 的阶段路径不提供这项回写。
回调在渲染线程运行，场景树操作应交给主线程。纹理 RID 的寿命随视口缓冲变化。

### 替换原生实现

`FengBuiltinPass.implementation` 默认引用 `passes/native/*.gd` 中的脚本。
这些脚本通过 Core 原语执行原生操作，并向引擎声明提供对应 ID。
复制或继承它们并重写 `_frp_execute()` 即可改变实现；清空 `implementation` 使用引擎实现。

条目与 implementation 的作者开关共同控制该 Pass。`FengNativePass.overlay` 是实现内的
附加效果：关闭 overlay 仅停止附加工作及其纹理声明，原生操作继续执行。
Renderer 观察这些嵌套资源的 `changed` 信号。

独立自定义 Pass 可用 `provides_native_ids` 声明接管的工作。例如提供 `[0,1,2,3,7]`
并实际执行这些操作，可以组成单条目的整帧管线。提供 ID 6 也会启用对应的 TAA/jitter
特性查询；声明提供工作时，脚本必须完成该工作。

### Tonemap 前后的 overlay

Post Process 实现的 `overlay_after_tonemap` 决定 overlay 处理 HDR 或 LDR。
LDR overlay 需要声明自己的命名输出，使用 `Source.TONEMAPPED` 读取色调映射结果：

```gdscript
# HDR overlay
ctx.post_process()
overlay._frp_execute(ctx)
ctx.tonemap()

# LDR overlay
ctx.post_process()
ctx.tonemap_deferred()
overlay._frp_execute(ctx)
ctx.present("post_ldr")
```

默认 Post 实现还会完成 resolve/history，并将 specialization constant 0
`POST_AFTER_TONEMAP` 传给 overlay。`FengShaderPass.shader_keywords` 或
`set_shader_keyword()` 修改 specialization 常量时会重建 GPU pipeline。
将读写 HDR Color 的效果直接拖到 Post 后不会自动把它改成 LDR 效果。

### 参数协议

Pass 的带类型 `@export` 参数由基类收集，也可重写 `get_frp_parameters()`。
运行时通过 `get_resolved_parameters(ctx)` 读取最终值，优先级从低到高是：

**Pass 资源值 → 条目 `pass_parameters` → Volume 混合结果**。

原生参数键为整数 ID，自定义 Pass 使用持久 `stable_id`，也可重写 `get_parameter_key()`。
同一管线中的独立模块键必须唯一，不能使用列表位置作为身份。
参数 setter 调用 `emit_changed()` 后，FengCompositor 合并通知并自动应用。
脚本原位修改 `passes` 数组后应重新赋值数组或调用 `renderer.emit_changed()`；
原位增删 `inputs` / `outputs` 后重新赋值数组，以更新声明的观察关系。

```gdscript
@tool
extends FengPass

@export_range(0.0, 4.0, 0.01) var strength := 1.0:
    set(value):
        strength = value
        emit_changed()

func get_volume_parameter_names() -> PackedStringArray:
    return PackedStringArray(["strength"])

func _frp_execute(ctx: FRPPassContext) -> void:
    var settings := get_resolved_parameters(ctx)
    # 使用 settings["strength"] 执行效果。
```

## Volume

Pass 作者通过 `get_volume_parameter_names()` 声明允许覆盖的字段，默认空列表。
管线全局参数和 Volume 字段独立：Volume 只能编辑已声明字段。
在 FengVolume 或 FengVolumeProfile 检查器中选择模块，编辑字段并勾选 `overrides/字段名`。
取消勾选保留编辑值、继承较低优先级结果；模块和整个 Volume 也可关闭。

`enabled` 只有被 Pass 明确声明为 Volume 布尔字段时才可覆盖，`false` 表示关闭 Pass。
TAA 开放 `enabled` 与 `jitter_phases`。添加模块本身不会打开作者关闭的 Pass，必需工作仍受校验。

- 有限 Volume 是可平移、旋转、缩放的盒子，`size` 定义外边界。
- `blend_distance` 向盒内过渡：外边界影响为 0，内盒影响为 `weight`。
  设为 0 时盒内直接应用；过渡宽于盒子时可能没有完整影响区。
- `unbound` 表示所在视口的全局 Volume。
- 按 priority 从低到高混合，同优先级保持注册顺序。连续数值、颜色与浮点向量插值；
  布尔、枚举、资源等离散字段在权重达到 0.5 时切换。

每个相机按自身位置求值；只看到盒内物体不会使相机受该 Volume 影响。
编辑器 3D 视图提供范围 Gizmo 和逐相机预览，游戏不创建范围网格。
退出范围、切换场景或卸载插件时恢复原 compositor/全局设置。

各相机的参数、开关、效果 RID 和纹理管理保存在独立 ViewState 中。
需要不同结果的相机使用不同 FengCompositor，可共享同一 Renderer。
默认标准原生实现和精确类型的 FengShaderPass 可共享执行对象；自定义 Pass 默认隔离，
可通过 `can_share_view_execution()` 显式声明整个携带对象图可共享。
配置未变时复用编译字段和有界缓存，相机移动仅更新权重；Volume 数量不会增加效果绘制次数。

## 库同步与旧资源

`pipeline/library_manager.gd` 的 manifest 定义库身份、模板、默认开关和插入位置。
`DEFAULT_LIBRARY_SEEDED` 控制默认管线中的库条目；其它模板只通过 Library 菜单添加。
同步保留作者参数、已识别条目的顺序和显式删除记录。缺少对应 GBuffer/Lighting/Sky 锚点时，
依赖该锚点的库效果由作者手动添加并放在对应工作之后。

当前 Renderer schema 为 10。迁移处理旧原生 ID、合并后的 Operation、默认实现和 Bloom 位置，
并尽量保留开关与自定义条目的相对位置。仅含旧阶段效果的资源会补齐原生调度。
若 Inspector 仍报告原生 ID/名称不匹配，创建当前 Renderer 并迁入自定义效果和参数。

- 老 FXAA 资源若仍使用标准 shader 与绑定，会替换为带独立源副本的 FengFXAAPass，
  保留身份、顺序、参数和开关；自定义 shader、子类或绑定由作者维护。
- 老纹理声明中的 `pipeline_name` / `format` / `usage_bits` / `size_divisor` 已改为
  `custom_name` / `data_format` / `usage` / `scale`。尚未按新字段保存的资源需在 Inspector 重设。
- 旧 Profile 的 `pass_parameters` 和 `enabled_passes` / `disabled_passes` 可加载，
  同样受当前 Pass 的字段权限过滤；新界面使用模块和逐字段覆盖开关。

## 定位与验证

RenderDoc 事件按 `列表序号 + Pass 名称 → 内部操作 → Commands (L…)` 分组。
Pass 边界建立命令依赖，内部仍按资源依赖优化。`L` 是底层命令图层级。
禁用条目不执行；启用但无 GPU 工作的条目保留轻量 marker，便于对照 Inspector。
VT Pass 空闲时不提交烘焙，编辑器最后的 Scene-to-UI 合成也不属于场景几何绘制。

可视分析器提供 `FRP <名称>` 的 CPU/GPU 范围。脚本分析器中 `FRPPassContext.run_pass()`
的 CPU 包含时间是原生调用入口耗时；分析时分别查看提交、编译和 GPU 执行。
`Performance.PIPELINE_COMPILATIONS_DRAW` 可检查已预热 Lighting 组合是否重复编译。

```text
python misc/scripts/test_frp_pipeline.py --driver d3d12
python misc/scripts/test_frp_pipeline.py --driver vulkan
python misc/scripts/test_frp_volume_cpu.py
```

图形套件使用隔离项目和真实 GPU，覆盖调度、纹理、库效果、迁移、MSAA、TAA、项目管线、
Volume、编辑器预览与 UndoRedo。CPU 套件测量 Volume 的静止、移动和进出范围成本。
`--headless` 不能验证 GPU 画面。

实现职责见 [插件架构](../../../doc/frp-addon-architecture.md)，引擎接口和升级触点见
[引擎契约](../../../doc/frp-engine-contract.md)。
