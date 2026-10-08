# UE 5.8 Atmosphere 参数与传输契约

Feng Sky 对应 UE 5.8 的作者参数语义，提供 RGB Mie 吸收、臭氧、多次散射、地面反弹、
物体空气透视和逐表面太阳透射。使用方式与参数单位见
[Feng Sky](../misc/feng-addons/feng-sky/README.md)，FRP 数据布局见[引擎契约](frp-engine-contract.md)。

## 来源与比较范围

参数依据 [UE 5.8 属性文档](https://dev.epicgames.com/documentation/unreal-engine/sky-atmosphere-component-properties-in-unreal-engine?application_version=5.8)
和 [Sky Atmosphere 概览](https://dev.epicgames.com/documentation/en-us/unreal-engine/sky-atmosphere-component-in-unreal-engine)，
并曾对照本机只读 `F:\ue\ue\UnrealEngine-5.8` 的组件头文件、CDO 构造与 setter：
`SkyAtmosphereComponent.{h,cpp}`、`SkyAtmosphere.usf`、`HeightFogCommon.ush` 和 `HeightFogPixelShader.usf`。

数值模型参考 Sébastien Hillaire 的独立 MIT
[研究示例](https://github.com/sebh/UnrealEngineSkyAtmosphere/tree/183ead5bdacc701b3b626347a680a2f3cd3d4fbd)，
固定版本 `183ead5bdacc701b3b626347a680a2f3cd3d4fbd`。许可保存在
[THIRD_PARTY_NOTICES.md](../misc/feng-addons/feng-sky/THIRD_PARTY_NOTICES.md)。
UE 私有 shader 仅用于核对接口与链路，没有复制、重新许可或发布。

尚无同场景 UE 线性 HDR 基准；参数映射与数值测试支持功能对齐，像素等价仍待验证。
Feng 的采样预算、曝光和材质路径独立。

## 作者参数

Godot 世界单位为米；物理积分用 km / km⁻¹。UE 位置通常为 cm，迁移位置需除以100。
Inspector 的线性 Color × 系数 scale 是旧 raw RGB × multiplier 的适配视图；
存储只保留 canonical 字段，有效乘积和旧脚本语义保持兼容。

| UE 语义 / UI | Feng 作者字段 | 默认值及执行路径 |
| --- | --- | --- |
| Transform Mode | `transform_mode` | 三模式：世界原点海平面、组件位置海平面、组件位置行星中心 |
| Component Transform | `planet_origin` / `planet_transform` | WorldEnvironment 非空间节点；指定世界米坐标，或链接 Node3D 的 global_position；跟随父级移动通过该空间节点实现 |
| Ground Radius / API BottomRadius | `ground_radius`，别名 `bottom_radius` | 6360 km；Inspector 为1–7000 km软滑块。Feng 保留1–100000 km数值安全范围；UE头文件的ClampMax=10000是编辑器约束，setter/render路径不把它当物理上限 |
| Ground Albedo | `ground_albedo` | 线性 RGB .4；参与多次散射反弹；虚拟地面仅遮挡视线 |
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

## 模块与数值边界

`feng_sky_parameters.gd` 归一化有限输入；`feng_sky_transport.gd` 负责纯 CPU 光学；
LUT 模块负责有界采样/缓存；组件负责资源与光源所有权，Runtime 发布世界快照。
FRP `atmosphere_packet.gd` 将归一化快照适配为 GPU 数据。

光学列为128×64 RGB32F，存储 Rayleigh/Mie/臭氧密度积分；几何或密度改变才重建。
薄剖面采用直接积分。多次散射为16×16 RGB32F，采用16方向、12段和几何级数闭合，
反馈上限0.95。每个 provider 拥有 CPU image/GPU texture，有界共享字节缓存复用同参构建。
光源移动、能量与曝光复用光学表；首次生成和光学参数修改有独立成本。

运行时有限预算：半径1–100000 km，大气高度0.1–10000 km，密度高度0.001–1000 km，
系数0–100 km⁻¹，g为0–0.999，太阳圆盘角半径0–2.5°，输入辐照上限10M。
天空/圆盘源值上限60000；最终原生 HDR 写入另有有限值和65504范围保护。
Inspector 软滑块、Feng 硬预算和 UE scalability 限制分别生效。
Height Fog Contribution 允许有限非负且大于1的值。

物理模式保留场景 lux；非物理模式采用 FRP 的 PI×energy 约定。Height Fog 在组合源项后
施加一次 pre-exposure。太阳盘 tint 仅调整盘面；主光参与多次散射，两盏光都参与单次散射
与直接透射。太阳候选按 SceneTree 共享事件缓存，逐帧检查同世界、可见性和天空模式。

FRP 空气透视和逐表面太阳透射经现有 Height Fog 条目准备/执行。Forward+ 可显示天空
材质；该组件没有实现 UE 的全部每灯光开关、体积阴影、折射、3D AP froxel LUT 或材质图
表达式。FengSkyLight 的独立捕获功能见组件 README。

## 兼容与验证

旧半径、高度、Rayleigh、标量 Mie scattering/extinction、`mie_asymmetry` 和
`planet_center_m` 可加载/读写。旧消光转为非负吸收；旧中心选择显式中心模式。
旧 `*_angular_radius_deg` 继续表示半径，新 `*_source_angle_deg` 保存直径。
只有精确命中迁移白名单的已发布默认 shader 源会更新；用户修改的 shader 保留。
具体历史 hash 与二进制证据见 [Windows 验证](frp-unreal-atmosphere-windows-validation.md)。

```sh
python misc/feng-addons/feng-sky/tests/run_sky_atmosphere_tests.py --editor /path/to/godot
```

CPU 检查覆盖参数/别名往返、资源和世界生命周期、太阳候选、光学传输与缓存。
追加 `--gpu-driver d3d12` 或 `--gpu-driver vulkan` 覆盖 GPU 数值、雾、空气透视和移动场景。
图形结果需要真实驱动；headless 只验证 CPU 契约。

[Linux 历史记录](frp-unreal-atmosphere-validation.md)、[Windows 历史记录](frp-unreal-atmosphere-windows-validation.md)
保存各构建的通过项目、HDR 压力与性能范围。test-1 完整地形/编辑器默认黑斑在这些记录中
未复现；通用 HDR 压力结果不能归因或替代该场景复现。

UE 图像比较需要匹配构造默认值、地球/相机姿态、线性太阳色/lux、曝光、白平衡和
色调映射，并对共同实现范围的线性 HDR 天空/物体区域计算误差。
