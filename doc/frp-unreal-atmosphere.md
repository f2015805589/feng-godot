# UE 5.8 Atmosphere 参数、传输与验证边界

本次目标版本由用户指定为 **Unreal Engine 5.8**。属性与默认值依据 [5.8 官方属性文档](https://dev.epicgames.com/documentation/unreal-engine/sky-atmosphere-component-properties-in-unreal-engine?application_version=5.8)、[Sky Atmosphere 概览](https://dev.epicgames.com/documentation/en-us/unreal-engine/sky-atmosphere-component-in-unreal-engine)，并对照本机只读源码 `F:\ue\ue\UnrealEngine-5.8` 复核。实现包含 RGB Mie 吸收、臭氧、间接散射、地面反弹、物体空气透视和场景太阳透射。

## 来源与未获得的基准

- 本地核对的接口元数据位于 `Engine/Source/Runtime/Engine/Classes/Components/SkyAtmosphereComponent.h`；CDO 构造默认值和组件 setter 位于 `Engine/Source/Runtime/Engine/Private/Components/SkyAtmosphereComponent.cpp`
- Mie 相函数位于 `Engine/Shaders/Private/SkyAtmosphere.usf`，使用标准 Henyey–Greenstein 相函数并按 `-dot(Light, WorldDir)` 取余弦
- 高度雾环境光和方向大气光的注入位于 `Engine/Shaders/Private/HeightFogCommon.ush`；`HeightFogPixelShader.usf` 先计算高度雾、合并体积雾，然后在最终 RGB 合成处乘一次 `View.PreExposure`。Aerial Perspective 替换路径传入 `OneOverPreExposure`，以免重复预曝光
- UE 源码路径只用于核对属性、默认值和渲染链；这里没有复制 UE shader，也不声称 Godot 与 UE 最终像素完全相同
- 可访问的 [Hillaire 研究示例](https://github.com/sebh/UnrealEngineSkyAtmosphere/tree/183ead5bdacc701b3b626347a680a2f3cd3d4fbd) 为独立 MIT 项目，固定版本 `183ead5bdacc701b3b626347a680a2f3cd3d4fbd`（2022-09-11）。参考 `RenderSkyCommon.hlsl`、`RenderSkyRayMarching.hlsl` 的密度、相函数和双散射闭合思路；许可保存在 `feng-sky/THIRD_PARTY_NOTICES.md`
- 未复制、重新许可或发布私有 UE shader；没有声称该示例就是 UE 5.8 源码
- 官方网页没有列出所有构造值和元数据限制；表中默认值、属性范围与 setter 行为已按本机 UE 5.8 CDO 构造函数、头文件元数据和运行代码交叉核对。尚未获得的是相同场景的 UE 线性 HDR 图像，因此没有 LUT 精度、色调映射或最终像素一致性的对照基准

## 作者参数映射

RGB 系数的 Inspector 适配层显示 UE 风格的归一化线性 Color 与物理系数 scale；Color 不做 sRGB 转换。为兼容旧场景和脚本，旧 raw RGB 和 multiplier 的存储/API 含义不变，唯一保存的仍是这组旧 storage，适配字段不会另存一份。编辑新视图时反向换算到原 storage，因此系数有效乘积 `raw RGB × multiplier` 保持兼容。四种归一化基准分别是 Rayleigh `.0331`、Mie scattering `.003996`、Mie absorption `.000444` 和 Other absorption `.001881 km⁻¹`。Godot 世界单位是米，物理积分统一使用 km / km⁻¹。UE 世界坐标通常为 cm，迁移位置需除以 100，不能直接照抄位置数字。

| UE 语义 / UI | Feng 作者字段 | 默认值及执行路径 |
| --- | --- | --- |
| Transform Mode | `transform_mode` | 三模式：世界原点海平面、组件位置海平面、组件位置行星中心 |
| Component Transform | `planet_origin` / `planet_transform` | WorldEnvironment 非空间节点；指定世界米坐标，或链接 Node3D 的 global_position；跟随父级移动通过该空间节点实现 |
| Ground Radius / API BottomRadius | `ground_radius`，别名 `bottom_radius` | 6360 km；Inspector 为1–7000 km软滑块。Feng 保留1–100000 km数值安全范围；UE头文件的ClampMax=10000是编辑器约束，setter/render路径不把它当物理上限 |
| Ground Albedo | `ground_albedo` | 线性 RGB .4；只参与多次散射反弹，不再绘制虚假的朗伯地面半球 |
| Atmosphere Height | `atmosphere_height` | 60 km；Inspector为1–200 km软滑块，运行时仍用原0.1–10000 km安全范围 |
| MultiScattering | `multi_scattering_factor` | 1；只放大二阶及后续贡献，0 关闭 |
| Rayleigh Scattering / Scale | `rayleigh_scattering_color` / `rayleigh_scattering_coefficient_scale` | Inspector显示归一化Color×系数：(.175286,.409607,1) × .0331 km⁻¹。旧 `rayleigh_scattering` 和 `rayleigh_scattering_scale` 原样保留为隐藏存储/API |
| Rayleigh Exponential Distribution | `rayleigh_exponential_distribution` | 8 km；Inspector为.01–20 km软滑块，运行时安全下限.001 km |
| Mie Scattering / Scale | `mie_scattering_color` / `mie_scattering_coefficient_scale` | 白色 × .003996 km⁻¹；旧 `mie_scattering` 和 `mie_scattering_scale` 原样保留 |
| Mie Absorption / Scale | `mie_absorption_color` / `mie_absorption_coefficient_scale` | 白色 × .000444 km⁻¹；消光逐通道等于散射+吸收；旧 raw 字段仍保存 |
| Mie Anisotropy | `mie_anisotropy` | .8；标准归一化 Henyey–Greenstein 相函数，`g` 硬范围0–.999。Godot的 `dot(view,sun)` 对应 UE 的 `-dot(Light,WorldDir)`，因此前向/后向峰位置一致 |
| Mie Exponential Distribution | `mie_exponential_distribution` | 1.2 km；Inspector为.01–10 km软滑块，运行时安全下限.001 km |
| Other Absorption / Scale | `other_absorption_color` / `other_absorption_coefficient_scale` | (.34556,1,.04519) × .001881 km⁻¹；旧 `absorption` / `absorption_scale` 存储与 `other_absorption` API 别名保留 |
| Tent: Tip Altitude / Tip Value / Width | `absorption_tip_altitude` / `absorption_tip_value` / `absorption_width` | 25 km /1 /15 km；Inspector分别为0–60、0–1、0–20软范围。宽度0或TipValue0时整层密度与吸收系数清零，避免除0并关闭臭氧 |
| Sky Luminance Factor | `sky_luminance_factor` | 白色；只改天空散射和天空捕获，不改物体空气透视、消光或太阳圆盘 |
| Sky And Aerial Perspective Luminance Factor | 同名 snake_case 字段 | 白色；同时改天空/空气透视源项 |
| Aerial Perspective Distance Scale | `aerial_perspective_distance_scale` | 1；Inspector为0–3软范围，不透明、前向 fallback、透明物体都使用同一距离缩放；旧 view-distance 别名保留 |
| Aerial Perspective Start Depth | `aerial_perspective_start_depth` | .1 km；Inspector为.001–10 km软范围，运行时最小.001 km；近处跳过积分 |
| Height Fog Contribution | `height_fog_contribution` | 1；Inspector为0–1软范围，UE没有ClampMax/runtime上限，因此大于1的旧值不会被夹到1；Feng只保留有限、非负安全处理。受 `affect_height_fog` 控制，不关闭独立天空/物体空气透视 |
| Transmittance Min Light Elevation Angle | `transmittance_min_light_elevation_angle` | -90°；只限制地面/物体直射光透射方向，不移动天空太阳、不改变空气透视 |
| Trace Sample Count Scale | `trace_sample_count_scale` | 1；Inspector为.25–8软范围，Feng数值预算为.25–8；当前8个视线段缩放后最多64段。UE仍受 `r.SkyAtmosphere.*SampleCountMax` scalability CVar限制，两者不是同一预算 |
| Atmosphere Sun Light Index 0 / 1 | `sun_light` / `secondary_sun_light` | 每个按真实 light RID 对应；次光不被自动选为主光；依 UE5.8 已记录的限制，只有主光参与多次散射 |
| Directional Light Source Angle / Disk Tint | `sun_source_angle_deg` / `secondary_sun_source_angle_deg`；`sun_disk_color_scale` / `secondary_sun_disk_color_scale` | 角度为圆盘直径，主/次默认.5357°；旧 `*_angular_radius_deg` 脚本和场景别名仍表示半径.26785°，保存只写新直径字段，内部 shader uniform 仍接收半径。独立白色默认 disk scale 只改太阳盘，不改太阳直射能量或大气散射 |

## 模型、精度与性能

`feng_sky_parameters.gd` 只负责有限数值合同；`feng_sky_transport.gd` 是纯 CPU 光学；两个 LUT 模块只负责有界采样与缓存；Runtime 负责弱引用的世界发布，不再承担完整光学模型。组件负责资源所有权、作者参数、光源选择和缓存失效。FRP 的 `atmosphere_packet.gd` 是 normalized snapshot → GPU 数据包的唯一适配器。

128×64 RGB32F 光学列包含 Rayleigh、Mie、臭氧。密度变化才重建；太阳、强度、曝光和系数变化不重建该表。过薄剖面回退到直接积分，不能把旧纹理传给空气透视。16×16 RGB32F 多次散射表使用16方向、12段及几何级数闭合，反馈上限 .95。它的生成约 .47 s，是明确的首次/光学参数修改成本；不能拿缓存命中帧掩盖它。每个 provider 保留自己的 CPU image 和 GPU texture，四项共享字节缓存只用于复用初次生成，不会使多世界的后续太阳移动再次生成表。

数值保护范围是 Feng 实现的有限预算，不冒充 UE 的 Inspector ClampMin/Max：行星半径1–100000 km、大气高度.1–10000 km、密度高度.001–1000 km、系数0–100 km⁻¹、`g` 为0–.999、太阳圆盘角半径0–2.5°。多次散射系数有限，反馈权重上限.95；太阳辐照输入上限10M，天空源值上限60000。60000上限发生在预曝光之前，亮度增益与 PreExposure 仍可能放大最终像素，因此它不是 RGBA16F 写入安全界；最终 HDR 写入由 native finite/range guard 限制到65504。Trace Sample Scale 暴露 UE 的.25–8软范围，Feng当前仍以8作为计算预算上限；UE另受 scalability CVar 限制，二者不是同一预算。Height Fog Contribution 的 Inspector 滑块为0–1，但大于1的存档值保持有效，只作有限、非负保护。数值预算有明确画面差异，不能用这些结果声称 UE 逐像素一致。

物理模式仍使用真实60,000 lux场景输入；非物理模式保持 PI×energy 的 FRP约定。UE 源码显示天空环境光和方向大气光先进入 Height Fog 源项，Height Fog 最后合成时对 RGB 乘一次 PreExposure；本项目的FRP高度雾 pass 也把当前 pre-exposure 交给 native 合成路径。该证据说明预曝光的位置与责任，不等价于两边 HDR 像素已逐点验证。太阳圆盘的独立 tint 不参与大气散射、太阳辐照或场景直射光。引擎准备阶段上传数据后，使用同一过滤顺序匹配光源槽位，再由各表面着色路径求透射。

太阳自动选择使用按 `SceneTree` 共享的事件缓存：新 provider 只触发一次初始候选枚举，之后通过节点加入/移除信号维护候选；每帧只检查缓存中的方向光候选及其当前可见性、World3D、天空模式和次光排除条件，不再每个组件重复扫全场景树。CPU 微基准在5,000个普通节点上测得每次旧式全树 `find_children` 约1.02 ms，中位数；新 registry 无太阳时每次 resolve 约0.5 μs，64个方向光候选时约77 μs。初始 seed 为1.43 ms，每个后续 provider attach 约29 μs。这是合成 CPU 基准，不包含渲染线程、GPU、NativePass、Shader 首编译或真实 test-1 场景开销，不能用来解释原生 `run_pass` 的 inclusive 耗时。

## 有意保留的实现边界

FRP 使用逐表面太阳透射；UE 的每灯光开关/CVar、云层阴影、地形参与的大气体积阴影、折射、SkyLight 捕获系统、空中透视3D froxel LUT以及材质图专用表达式没有被逐项克隆。Godot Forward+可渲染该天空材质，但本次物体空气透视与太阳透射接入属于FRP，要求当前管线启用现有Height Fog条目。`sun_source_angle_deg` 表示太阳角直径并转换为 shader 半径；旧 `sun_angular_radius_deg` API 继续表示半径。渲染步骤、采样预算、曝光状态和材质路径不同，所以参数与相函数的对应不构成同像素承诺。

## 迁移与稳定契约

旧 `planet_radius_km`、高度字段、Rayleigh 系数、灰色 Mie scattering/extinction、`mie_asymmetry`、`planet_center_m` 都仍可加载/读写。旧 raw coefficient、颜色乘数的组合与有效系数保持原意；新的 UE 风格 Color/scale 只作为 Inspector 视图，保存不双写。旧消光换算为非负吸收；旧中心坐标自动选择显式中心模式。旧太阳半径属性保留半径语义并可双向赋值，新规范属性 `sun_source_angle_deg` / `secondary_sun_source_angle_deg` 保存直径。两个已发布 shader 默认源和 test-1 中未修改的 e002 内嵌默认 shader 均列入精确 SHA256 迁移白名单；test-1 旧源码的 LF 规范化 SHA256 为 `0f815fb7da56be15db13c180fa6a1de55d5f7383fe22764aa16c6f315ec166fb`。只对精确命中的旧源执行迁移，任意用户修改版本继续当作自定义天空；reference shader 热重载后，owned Sky 必须匹配当前源码。当前 B worktree 的天空 shader 仍是 e002 原码，因此当前 probe 只证明 hash 识别与复制行为；待 C 的新内置 shader 源集成后，再验证该 test-1 场景确实升级到新源码。

新 prepare hook 通过 ViewPass / BuiltinPass / NativePass 转发，Volume 相机不会失去空气透视数据。默认仍是9个原生条目+5个库条目，13个常规条目开启、Debug Buffers关闭；不添加第14个常规 pass，不改作者覆盖。空气透视随现有 Height Fog 条目的显式启停一起调度。

## 验证说明

可复现入口为 `misc/feng-addons/feng-sky/tests/run_sky_atmosphere_tests.py`。本次 headless CPU 运行通过组件/世界生命周期、UE 参数与 migration、CPU optical transport、Sky numerical checks；optimization suite 首轮触发 reference hot-reload identity regression。基线分支同一 test 通过，根因是当前 e002 shader 恰与新增 legacy hash 相同，导致 owned sky 在 reference 变更后仍命中 legacy fallback。现已将旧源 fallback 限定在 reference shader 尚未热重载的兼容阶段；hot reload 后 owned Sky 必须匹配当前源码。修复后 worktree optimization suite 通过。GPU suite 因本轮未运行而未验证。参数契约探针验证旧 raw 有效系数 round-trip、角度 alias、canonical 存储、臭氧关闭条件和硬范围。Registry CPU 探针验证无太阳、大量节点、多 provider、候选加入/删除/排序、world/reparent、多 viewport 的生命周期与选择。GPU 及 native timing 由后续独立验证记录补充。[历史验证记录](frp-unreal-atmosphere-validation.md) 保留先前 Linux 运行原文，不代表这次运行；架构审查见 [七插件复核](frp-addon-audit.md)。未执行的目标硬件和 UE 基准必须单独列出。

准确比较下一步需要：同一UE5.8构造默认值导出、同一地球/相机位置和姿态、同一线性太阳色与lux、相同曝光/白平衡/tonemapper、关闭未实现云和额外天空项、线性HDR截图及天空/物体区域误差。当前没有这套UE图像，因此本提交提供可检验的参数语义与传输功能对齐，不声称渲染器完全等价。
