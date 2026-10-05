# 地形材质与 FRP 使用指南

## 创建和扩展地形

新建 Terrain3D，选择项目内的数据目录。空目录会打开 **Create Terrain Grid**：
输入 **Width (X blocks)** 与 **Depth (Z blocks)**，点击 **Create Terrain**。
每块为 512×512 米（`region_size = 512`、`vertex_spacing = 1`）；20×20 块覆盖
10.24×10.24 公里。网格围绕编辑器视图对齐，靠近世界边界时移入合法范围。

创建按批次保存 `terrain3d*.res` 并显示进度，停止时保留已完成地块。
一次创建上限取材质的驻留 region 上限与 1024 的较小值。
新地形关闭 World Background；按 Ctrl+S 保存场景中的数据目录和材质设置。
之后保存场景也会保存地形编辑。

选择已有区域文件的目录会加载原数据及其区域设置。取消选择不创建文件，
可用 **Terrain → Initialize Terrain…** 重试。扩展已有地形时，选择 **Add Region (E)**
并点击空白地面；该工具通过地面平面定位。

## 材质数组

选中 Terrain3D，在底部资产面板打开 **Terrain → Texture Array**。
每个地形独立持有材质数组和设置，按 Layer ID 排列，最多 32 层。
Albedo/Height 与 Normal/Roughness 使用两张 Texture2DArray，共用层序号。

- **Size**：Auto 使用第一个有效贴图尺寸，也可指定统一尺寸
- **Mipmaps**：默认开启，法线 mip 重新归一化
- **Compression**：默认 BC7；支持 Uncompressed、BC1/3/4/5/6H/7、ETC1、ETC2 RGB/RGBA、
  EAC R11/RG11、ASTC 4×4/8×8（LDR/HDR）
- **Info**：显示层数、尺寸、实际格式、mip、编码字节数和估算 GPU 字节数

新增 Layer、替换贴图或修改设置后自动更新。源贴图保持原样，缺失通道使用占位图；
准备失败保留上一套可用数组。内存缓存复用未变层，首次加载仍需处理源图。

### 格式选择

高度与粗糙度存于 Alpha。BC7、BC3、ETC2 RGBA、ASTC RGBA 可保留这些通道；
RGB/R/RG 格式会丢失相应通道，Info 的 `channel_warning` 会提示。
BC4/BC5 适合通道数据，不能完整保存这套地形材质。

HDR 输入可用 Uncompressed（RGBAF）、BC6H 或 HDR ASTC。BC6H 不保存 Alpha，
同一数组内也不能混用带负值和全非负层；不兼容输入会报告原因。
显卡不支持所选编码时解压上传，`gpu_fallback` / `gpu_note` 显示状态；
`encoded_bytes` 与 `gpu_bytes` 分别反映文件编码和实际上传大小。
源材质数组的压缩设置与 VT 页面压缩是独立配置。

## 笔刷与地图

用 Region 工具建立区域后，在材质笔刷选择 Background / Overlay：

| 模式 | 行为 |
|---|---|
| Set | 按权重绘制 |
| Add / Sub | 按坡度增加/减少覆盖层比例 |
| Mix | 按坡度混合；Weight Level 决定阈值，Background 的 Slope Blend Sharpness 决定锐度，Overlay 的 Slope Based Damp 决定衰减 |

切换材质或笔刷尺寸保留材质自身的坡度参数。
**Terrain → Terrain Maps** 查看数据，**Terrain → Debug Views** 显示 Heightmap、Material IDs、
Material Weight 和 Slope。

| 地图 | 内容 |
|---|---|
| Height Maps | RF 几何高度 |
| Surface Maps | R16 UNORM，编码两个 5 位材质 ID、2 位混合模式、3 位权重等级与 1 位 UV 标志 |
| Control Maps | 洞、自动材质等控制元数据 |

材质笔刷和吸管使用 Surface Maps，权重已编码在其中。Albedo Alpha 的材质微观高度与
Height Maps 的几何高度独立。

**Surface Density** 为 1/2/4/8 texel·m⁻¹，默认 1，控制 R16 Surface Maps 存储密度。
每块存储边长为 `region_size × density`：region 256、density 4 时为 2 MiB，
region 1024、density 4 时为 32 MiB，撤销快照也承担相应成本。
修改密度会按块最近邻重采样现有 Surface Maps。直接材质路径的 GPU 数组保留每个密度块的
块首 texel；AVT/SVT 的材质纹素密度由各自设置控制。

## Surface VT

**Terrain → Surface VT Editor…** 打开配置和诊断窗口。
VT Setting 中的四个 delivery 选项分别决定近/远景的 Material 与 Height 如何送到 shader：

| 通道 | 可选方式 | 默认近景 / 远景 |
|---|---|---|
| Material（diffuse、normal、AO/roughness） | Direct、AVT、Clipmap、SVT | AVT / SVT |
| Height | Direct、Clipmap | Direct / Direct |

Direct 读取区域数组。AVT 按 64 米世界 sector 分配近景虚拟地址，SVT 使用世界页网格；
两者共享物理页池。Clipmap 为所选通道建立自己的多级缓存，可选 LOD 或 Atlas 实现，
不使用 AVT/SVT 页池。服务和 shader 路径按所选 delivery 组装。

### 密度、预算与缺页

AVT 默认最高密度 1024 纹素/米，SVT 默认 1 纹素/米。AVT 按屏幕需求选择 mip，
CPU 计划与 shader 的像素覆盖规则配合；虚拟分辨率表示地址空间，实际驻留由物理缓存和
生产预算决定。VT Setting 提供页大小、页数、自动容量、每次生产预算和 worker 设置。

AVT/SVT 默认允许用已驻留的较粗层级服务缺页；关闭相应反馈选项可查看严格缺页诊断。
正常分页材质路径不以原始材质求值遮盖缺页。视野变化、缓存压力和编辑会触发增量生产。
VT Page 可查看驻留页、SVT cell 和 Clipmap 状态，并定位对应区域数据。

### 编辑预览与 SVT 烘焙

`vt_editor_preview` 默认开启，直接显示实时材质/表面编辑，暂停 VT 请求和 SVT 自动烘焙。
关闭预览会合并刷新脏区域并恢复 VT；手动 Bake 仍可使用。此选项只作用于编辑器。

SVT 的 **Auto Bake** 默认开启，在修改停止 500 ms 后增量更新受影响 cell。
**Bake All SVT Cells** 强制重烘所有 cell。默认 512 米地块、1 纹素/米产生
512×512 的三通道源贴图及完整 mip 链，保存于 `svt_cells/<x>_<z>_0.vtcell`。
运行时由 worker 读取 cell 或准备源数据，驻留 GPU cell 可直接复制/组合为物理页；
缺少有效烘焙时也可从驻留区域数据生产。

Cell 源分辨率上限为 8192。保存地形与更新离线 SVT 缓存分别执行；发布需要离线 cell 时，
应手动烘焙，或关闭预览后等待自动烘焙完成并检查状态。

详细设置与资源寿命见 [VT 架构](../misc/feng-addons/feng-idweight-terrain/docs/vt_architecture_review.md)
和 [delivery 配置](../misc/feng-addons/feng-idweight-terrain/docs/vt_delivery_assembly.md)。

## 接入 FRP

使用 [FRP 插件说明](../misc/feng-addons/feng-render-pipeline/README.md) 创建 Renderer 和 Compositor，
将其挂到 WorldEnvironment、Camera3D 或项目默认管线。编辑器自由视角使用独立相机，
项目设置或 WorldEnvironment 可让它与游戏共享配置。

FengRenderer 保存 Pass 顺序和开关，FengPass 声明效果及纹理，FengCompositor 负责自动绑定。
原生 ID 保持稳定，执行顺序来自列表位置。默认条目、参数与库同步规则以插件说明为准。

地形页面生产由 GBuffer 前的原生 **VT Pass** 执行。GBuffer 支持地形 shader 的
`vertex()` 位移与法线，按需在同一遍几何写出运动矢量。
自定义效果可使用 FengShaderPass 的 Compute/Raster 模式，或继承 FengPass 调用 Core 原语。

读取材质缓冲示例：

```gdscript
var buffers = render_data.get_render_scene_buffers()
var albedo = buffers.get_texture("frp_clustered", "gbuffer_albedo")
var orm = buffers.get_texture("frp_clustered", "gbuffer_orm")
var emission = buffers.get_texture("frp_clustered", "gbuffer_emission")
var normal = buffers.get_texture("frp_clustered", "normal_roughness")
var depth = buffers.get_depth_texture()
```

这些数据在 GBuffer 后可用；MSAA 下读取 resolved 附件，声明相应访问需求。
纹理 RID 随分辨率和视口生命周期变化，渲染线程回调不直接修改场景树。

RenderDoc 以 **Pass 名称 → 内部操作** 展示场景。启用的空闲 VT Pass 保留 marker，
有页面生产时才提交 GPU 工作；禁用条目不执行。D3D12 可直接显示标签，Vulkan 非开发构建
使用 `--verbose` 启用 debug utils。编辑器将 Scene 纹理合成到 UI 的绘制与场景几何分开。

## 旧资源与验证

- 无 Surface Density 字段的旧 Surface Maps 加载时按当前密度升采样，保留已编辑材质
- 旧 `.vtpage` 烘焙需重新 Bake 为当前 `.vtcell` 格式
- FRP 的旧 ID、字段和模板迁移说明集中在插件 README 的“库同步与旧资源”一节

验证入口：

- `misc/feng-addons/feng-idweight-terrain/native/tests/texture_layers.gd`：数组、笔刷、撤销和坡度画面
- `misc/feng-addons/feng-idweight-terrain/native/tests/idweight/`：R16 编码与坡度算法
- `misc/feng-addons/feng-idweight-terrain/native/tests/vt_delivery_runner.py`：delivery 组合与资源组装
- `misc/scripts/test_frp_pipeline.py`：FRP 调度、真实帧、MSAA/TAA 与编辑器集成

图形验证需要实际 D3D12 / Vulkan 驱动。性能测量的设备、场景与覆盖范围见
[地形优化审计](../misc/feng-addons/feng-idweight-terrain/docs/terrain_optimization_audit.md)。
