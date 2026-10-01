# UE 5.8 Atmosphere 参数、传输与验证边界

本次目标版本由用户指定为 **Unreal Engine 5.8**。依据为 [5.8 官方属性文档](https://dev.epicgames.com/documentation/unreal-engine/sky-atmosphere-component-properties-in-unreal-engine?application_version=5.8)、[Sky Atmosphere 概览](https://dev.epicgames.com/documentation/en-us/unreal-engine/sky-atmosphere-component-in-unreal-engine) 与公开研究实现。不是把原单次散射参数改名：RGB Mie 吸收、臭氧、间接散射、地面反弹、物体空气透视和场景太阳透射都进入实际求值。

## 来源与未获得的基准

- 已核实 Epic 官方 5.8 文档存在；本次连接读取 `EpicGames/UnrealEngine` 返回 404，无法访问其私有代码。这不表示该仓库不存在。未发现并验证可合法使用的公开 5.8 引擎 fork
- 可访问的 [Hillaire 研究示例](https://github.com/sebh/UnrealEngineSkyAtmosphere/tree/183ead5bdacc701b3b626347a680a2f3cd3d4fbd) 为独立 MIT 项目，固定版本 `183ead5bdacc701b3b626347a680a2f3cd3d4fbd`（2022-09-11）。参考 `RenderSkyCommon.hlsl`、`RenderSkyRayMarching.hlsl` 的密度、相函数和双散射闭合思路；许可保存在 `feng-sky/THIRD_PARTY_NOTICES.md`
- 未复制、重新许可或发布私有 UE shader；没有声称该示例就是 UE 5.8 源码
- 官方说明未逐项提供当前构造函数值和元数据限制。因此下表默认值是明确的 Feng 地球预设；未获得 UE 5.8 CDO 导出和相同场景渲染前，不能称每一默认值、范围、LUT 精度、色调映射或最终像素完全相同

## 作者参数映射

RGB 系数由真正的 Color Inspector 控件编辑，数值直接表示线性 RGB 系数；不是再做一次 sRGB 转线性。旧 Vector3 序列化仍被 setter 接受。Godot 世界单位是米，物理积分统一使用 km / km⁻¹。UE 世界坐标通常为 cm，迁移位置需除以 100，不能直接照抄位置数字。

| UE 语义 / UI | Feng 作者字段 | 默认值及执行路径 |
| --- | --- | --- |
| Transform Mode | `transform_mode` | 三模式：世界原点海平面、组件位置海平面、组件位置行星中心 |
| Component Transform | `planet_origin` / `planet_transform` | WorldEnvironment 非空间节点；指定世界米坐标，或链接 Node3D 的 global_position；跟随父级移动通过该空间节点实现 |
| Ground Radius / API BottomRadius | `ground_radius`，别名 `bottom_radius` | 6360 km；半径变化自动保持原点为海平面 |
| Ground Albedo | `ground_albedo` | 线性 RGB .4；只参与多次散射反弹，不再绘制虚假的朗伯地面半球 |
| Atmosphere Height | `atmosphere_height` | 60 km |
| MultiScattering | `multi_scattering_factor` | 1；只放大二阶及后续贡献，0 关闭 |
| Rayleigh Scattering / Scale | `rayleigh_scattering` / `rayleigh_scattering_scale` | (.005802,.013558,.0331) km⁻¹ ×1 |
| Rayleigh Exponential Distribution | `rayleigh_exponential_distribution` | 8 km；采用 e-folding 定义；官方“40%”是近似描述，实际 exp(-1)=36.79% |
| Mie Scattering / Scale | `mie_scattering` / `mie_scattering_scale` | (.003996,.003996,.003996) km⁻¹ ×1 |
| Mie Absorption / Scale | `mie_absorption` / `mie_absorption_scale` | (.000444,.000444,.000444) km⁻¹ ×1；消光逐通道等于散射+吸收 |
| Mie Anisotropy | `mie_anisotropy` | .8；归一化 Cornette–Shanks 相函数；不再用 HG 代替实际散射相函数 |
| Mie Exponential Distribution | `mie_exponential_distribution` | 1.2 km |
| Absorption / Scale | `absorption` / `absorption_scale` | (.000650,.001881,.000085) km⁻¹ ×1；`other_absorption` API 别名保留 |
| Tent: Tip Altitude / Tip Value / Width | `absorption_tip_altitude` / `absorption_tip_value` / `absorption_width` | 25 km /1 /15 km；10–25 km 上升、25–40 km 下降，外侧为0；转换成两个夹紧线性层 |
| Sky Luminance Factor | `sky_luminance_factor` | 白色；只改天空散射和天空捕获，不改物体空气透视、消光或太阳圆盘 |
| Sky And Aerial Perspective Luminance Factor | 同名 snake_case 字段 | 白色；同时改天空/空气透视源项 |
| Aerial Perspective Distance Scale | `aerial_perspective_distance_scale` | 1；不透明、前向 fallback、透明物体都使用同一距离缩放；旧 view-distance 别名保留 |
| Aerial Perspective Start Depth | `aerial_perspective_start_depth` | .1 km；近处跳过积分 |
| Height Fog Contribution | `height_fog_contribution` | 1；受 `affect_height_fog` 控制，关闭时不关闭独立天空/物体空气透视 |
| Transmittance Min Light Elevation Angle | `transmittance_min_light_elevation_angle` | -90°；只限制地面/物体直射光透射方向，不移动天空太阳、不改变空气透视 |
| Trace Sample Count Scale | `trace_sample_count_scale` | 1；当前8个视线段，缩放并夹紧；不是 UE scalability/CVar 的同一预算 |
| Atmosphere Sun Light Index 0 / 1 | `sun_light` / `secondary_sun_light` | 每个按真实 light RID 对应；次光不被自动选为主光；依 UE5.8 已记录的限制，只有主光参与多次散射 |
| Directional Light Source Angle | `sun_angular_radius_deg` / 次光对应字段 | Feng 保留半径控制 .26785°；换算直径 .5357°；这是兼容扩展，不谎称 Godot 灯光 Inspector 已变成 UE UI |

## 模型、精度与性能

`feng_sky_parameters.gd` 只负责有限数值合同；`feng_sky_transport.gd` 是纯 CPU 光学；两个 LUT 模块只负责有界采样与缓存；Runtime 负责弱引用的世界发布，不再承担完整光学模型。组件负责资源所有权、作者参数、光源选择和缓存失效。FRP 的 `atmosphere_packet.gd` 是 normalized snapshot → GPU 数据包的唯一适配器。

128×64 RGB32F 光学列包含 Rayleigh、Mie、臭氧。密度变化才重建；太阳、强度、曝光和系数变化不重建该表。过薄剖面回退到直接积分，不能把旧纹理传给空气透视。16×16 RGB32F 多次散射表使用16方向、12段及几何级数闭合，反馈上限 .95。它的生成约 .47 s，是明确的首次/光学参数修改成本；不能拿缓存命中帧掩盖它。每个 provider 保留自己的 CPU image 和 GPU texture，四项共享字节缓存只用于复用初次生成，不会使多世界的后续太阳移动再次生成表。

数值保护范围是 Feng 实现的有限预算，不冒充 UE 的 Inspector ClampMin/Max：半径1–100000 km、高度.1–10000 km、密度高度.001–1000 km、系数0–100 km⁻¹、g∈[-.99,.99]。太阳辐照上限10M，天空最终输出60000以避免RGBA16F溢出。极端预算和多次散射反馈限制有明确画面差异，不能用这些结果声称 UE 逐像素一致。

物理模式仍使用真实60,000 lux场景输入；非物理模式保持 PI×energy 的 FRP约定。曝光只在渲染链处理一次。Fog 的白色基础反照率与独立方向艺术色不被直接光透射逻辑覆盖；不改写用户灯光颜色/强度。引擎准备阶段上传数据后，使用同一过滤顺序匹配光源槽位，再由各表面着色路径求透射。

## 有意保留的实现边界

FRP 使用逐表面太阳透射；UE 的每灯光开关/CVar、云层阴影、地形参与的大气体积阴影、折射、SkyLight 捕获系统、空中透视3D froxel LUT以及材质图专用表达式没有被逐项克隆。Godot Forward+可渲染该天空材质，但本次物体空气透视与太阳透射接入属于FRP，要求当前管线启用现有Height Fog条目。Inspector的Source Angle仍由兼容半径扩展换算；这是组件对照中明确的Godot适配，而不是给未实现的UE字段放一个空控件。

## 迁移与稳定契约

旧 `planet_radius_km`、高度字段、Rayleigh 系数、灰色 Mie scattering/extinction、`mie_asymmetry`、`planet_center_m` 都仍可加载/读写。旧消光换算为非负吸收；新存档只保存规范字段，避免别名重复回写。旧中心坐标自动选择显式中心模式。两个已发布内嵌默认 shader 通过精确SHA256迁移到当前源码；任意用户修改版本继续当作自定义天空，不进行宽泛字符串匹配或覆盖共享资源。

新 prepare hook 通过 ViewPass / BuiltinPass / NativePass 转发，Volume 相机不会失去空气透视数据。默认仍是9个原生条目+5个库条目，13个常规条目开启、Debug Buffers关闭；不添加第14个常规 pass，不改作者覆盖。空气透视随现有 Height Fog 条目的显式启停一起调度。

## 验证说明

可复现入口为 `misc/feng-addons/feng-sky/tests/run_sky_atmosphere_tests.py`。其中包含组件/世界生命周期、旧场景与内嵌shader迁移、RGB系数与tent、CPU光学、LUT/cache、32位GPU非有限值检查、实际天空图像与相机运动、物体空气透视和直射光匹配。最终执行结果见 [验证记录](frp-unreal-atmosphere-validation.md)，架构审查见 [七插件复核](frp-addon-audit.md)；未执行的目标硬件和 UE 基准必须单独列出。

准确比较下一步需要：同一UE5.8构造默认值导出、同一地球/相机位置和姿态、同一线性太阳色与lux、相同曝光/白平衡/tonemapper、关闭未实现云和额外天空项、线性HDR截图及天空/物体区域误差。当前没有这套UE图像，因此本提交提供可检验的参数语义与传输功能对齐，不声称渲染器完全等价。
