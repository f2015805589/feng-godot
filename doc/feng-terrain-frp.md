# 地形数组与 FRP Pass

## 地形材质

选中 Terrain3D，在底部资产面板打开 **Terrain → Texture Array**。

- 每个地形独立持有数组和设置。数组按 Layer ID 自动排列，最多 32 层。
- Albedo/Height 与 Normal/Roughness 分别存为一张 Texture2DArray，共用层序号。它们是同一套地形材质的两个通道数组。
- Size：Auto 使用第一个有效贴图的尺寸，也可指定统一尺寸。
- Mipmaps：默认开启；法线 Mipmap 会重新归一化。
- Compression：默认 BC7；可选 Uncompressed、BC1/3/4/5/6H/7、ETC1、ETC2 RGB/RGBA、EAC R11/RG11、ASTC 4×4/8×8（LDR/HDR）。覆盖当前 Image 编码接口能生成的格式；BC2、带符号 EAC、ETC2 Punchthrough 等仅可解码的格式不作为生成选项。
- BC7、BC3、ETC2 RGBA、ASTC RGBA 保留 Alpha 中的高度与粗糙度；RGB/R/RG 选项会丢失相应通道，Info 的 channel_warning 会提示。BC4/BC5 并不适合直接保留完整地形材质。
- HDR 输入可选择 Uncompressed（RGBAF）、BC6H 或 HDR ASTC。BC6H 不保存 Alpha，且数组内不能混用带负值与全非负的层；不兼容的输入会保留上一套数组并报告原因。
- 显卡不支持选定格式时，插件解压后上传；Info 的 gpu_fallback/gpu_note 显示回退状态，encoded_bytes 与 gpu_bytes 分别显示编码数据大小和上传数据大小。压缩格式能生成不代表当前显卡能节省对应显存。
- Info 显示层数、尺寸、实际格式、Mipmap 和两张数组的估算 GPU 数据字节数。

新增 Layer、替换贴图、调整数组设置会自动更新。源贴图不被修改；缺失通道使用占位图。准备失败会保留上一套可用数组。准备好的层在内存中缓存，修改某层不会重新压缩其他未变化的层；第一次加载仍需处理源图，尚无磁盘烘焙缓存。

## 笔刷、坡度与地图

先用 Region 工具建立地形区域，再使用材质笔刷选择 Background / Overlay。

- Set：按权重绘制，不随坡度变化。
- Add / Sub：坡度增加 / 减少覆盖层的占比。
- Mix：按坡度混合。阈值来自 Weight Level，过渡锐度使用 Background 的 Slope Blend Sharpness，坡度衰减使用 Overlay 的 Slope Based Damp。
- 切换材质或修改笔刷尺寸不会覆盖材质保存的坡度参数。

**Terrain → Terrain Maps** 打开实际地图数据；**Terrain → Debug Views** 可显示 Heightmap、Material IDs、Material Weight、Slope。管理入口收在单个菜单内，避免窄列换行抬高整个底部面板；仍可拖动面板边界调整高度。

- Height Maps：地形几何高度图，RF。
- Surface Maps：实际材质 ID 图，R16 UNORM。它同时编码两个 5 位材质 ID、2 位混合模式、3 位权重等级与 1 位 UV 标志。没有另一张独立的 Weightmap。
- Control Maps：保留洞、自动材质等旧控制元数据。材质笔刷与吸管使用 Surface Maps。
- 贴图 Albedo Alpha 中的 Height 是材质微观高度，与地形几何 Height Maps 不同。

## 自定义 FRP Pass

随引擎提供 **FengPass** 系列资源，可在 Inspector 配置 Shader、纹理输入输出、参数和工作组。`addons/feng-render-pipeline/library/` 提供 tint/blur/fxaa/color-grade/bloom-lite 内置模板；`examples/tint.tres` 是可直接拖入的示例；复杂效果仍可继承 CompositorEffect。

### 三层架构

- **FengRenderer**（Resource）：`passes` 包含 16 个原生组合步骤与自定义效果；`apply(compositor)` 上传列表顺序及名称，自动挂载隐藏的 `FengTextureManager`。满足数据依赖的条目可跨原生步骤移动。
- **FengPass**（CompositorEffect）：单个 pass，`stage` + `inputs` + `outputs`；子类实现 `_render()`。`FengShaderPass` 提供 compute 与全屏光栅两种模式。
- **FengCompositor**（Compositor）：绑定 renderer 后自动同步 effects；pass 的 `enabled` 由引擎原生即时生效。

中间纹理由 `FengTextureManager` 在 Pre GBuffer 阶段按 `FengPassOutput` 声明自动创建（scope `"frp_pipeline"`），分辨率切换自动重建；pass 通过 `Source.PIPELINE` 按名引用。

把 FengCompositor 挂到 WorldEnvironment 或当前 Camera3D，并为其 Renderer 指定资源。仅在文件系统创建或选中 FengRenderer 不会应用到场景；编辑器自由视角使用自己的相机，WorldEnvironment 可让它也使用同一配置。完整列表、约束和自动同步规则见 [FRP 插件说明](../misc/feng-addons/feng-render-pipeline/README.md)。

以下阶段表用于普通 Compositor 的兼容路径：在 Compositor Effects 添加脚本资源，Effect Callback Type 选择阶段，同阶段按数组顺序执行。FengRenderer 的显式列表以实际位置为准。

| 实际执行顺序 | 可用数据 |
| --- | --- |
| FRP: Pre GBuffer | 可准备自定义资源；当前帧的深度和颜色尚不可读 |
| GBuffer + MSAA Resolve | 引擎必要阶段 |
| FRP: Post GBuffer | 深度、法线、材质数组 |
| Pre Opaque | 保留原有回调，位于屏幕空间效果之前 |
| SSAO / SSIL / GI 等 | 按启用状态运行 |
| FRP: Pre Lighting | 可修改 GBuffer；本帧光照颜色尚不可读 |
| FRP Lighting | 引擎必要阶段 |
| FRP: Post Lighting | 已有延迟光照颜色，还不包含 Forward Fallback 和天空 |
| Forward Fallback、Motion → Post Opaque | 包含不适合写入 GBuffer 的不透明材质 |
| Sky → Post Sky | 天空完成 |
| Pre Transparent → Transparent → Post Transparent | 原有透明与后处理入口 |
| 内建后处理与输出 | 引擎阶段 |

兼容路径的排序发生在同一阶段内；旧枚举数值不变。显式 FengRenderer 列表通过资源依赖检查约束排序，并在 Pass 边界建立底层命令依赖，避免 GPU 命令跨条目重排。

在回调中通过 `render_data.get_render_scene_buffers()` 访问 RenderSceneBuffersRD：

```gdscript
var buffers = render_data.get_render_scene_buffers()
var albedo = buffers.get_texture("frp_clustered", "gbuffer_albedo")
var orm = buffers.get_texture("frp_clustered", "gbuffer_orm")
var emission = buffers.get_texture("frp_clustered", "gbuffer_emission")
var normal = buffers.get_texture("frp_clustered", "normal_roughness")
var depth = buffers.get_depth_texture()
```

不要把纹理 RID 跨分辨率切换、视口销毁保存。MSAA 开启时，Post GBuffer / Pre Lighting 读取解析后的单采样 GBuffer；需要解析颜色时设置 Access Resolved Color。显式 FengRenderer 路径会在自定义 Pass 位置解析所需附件，并把颜色写回 MSAA 附件；普通 Compositor 的旧阶段路径不提供这项回写。回调运行在渲染线程，不能直接修改场景树。

RenderDoc 中展开 **FRP Scene → 序号与 Pass 名称 → 内部操作**，即可找到 GBuffer 几何绘制和全屏延迟光照。当前地形 Shader 使用顶点变形，几何绘制归入 **Opaque Forward Fallback**。最终把 Scene 纹理合成到编辑器 UI 的绘制不是场景几何。D3D12 编辑器无需额外启用 PIX 即可输出标签；Vulkan 非开发构建需用 `--verbose` 启用 debug utils。关闭或本帧没有 GPU 工作的条目不会产生事件。

## 本轮修正与优化范围

- 光照读取当前 GBuffer 深度，不再误绑屏幕材质使用的可选深度副本；光照输出不再附带正在采样的深度图。
- 未启用 GI 时跳过 GI 结果采样，避免占位黑纹理的 Alpha 把环境光覆盖成黑色。
- 深度重建采用 RenderingDevice 的反向 Z、0..1 深度范围；背景深度 0 跳过光照，正交相机使用平行视线。
- 光照 Pass 按最近采样读取 GBuffer，复用 DFG 与能量补偿计算。
- 全屏光照专用布局去掉几何实例、Lightmap、原始 VoxelGI/SDFGI、Decal、全局材质、屏幕颜色及未使用采样器等绑定；GI 继续读取提前计算的结果，灯光投影贴图仍保留。
- 光照布局从 59 个 Binding 缩减为 34 个。纹理数组的描述符数量另计；这不是 FPS 提升百分比。
- 删除光照之前重复创建的 Forward Uniform Set，移除无用 DrawCall Push Constant；无透明物体时跳过透明绘制和对应 Uniform 构建。
- MSAA 同一次 Resolve 中解析深度、法线与三张材质 GBuffer，确保取自同一采样点；不额外运行三个全屏解析 Pass。
- 光照使用实际 Specialization 配置，避免面积光、软阴影与投影灯开关一直为默认零。
- Reflection Probe 没有 GBuffer，走其不透明几何绘制路径。

这些是本轮可核实的修正，不代表所有场景中的 Pass 都能删除。Forward Fallback、透明、阴影、GI 具有独立职责，仍然保留。

## 验证入口

- `misc/feng-addons/feng-idweight-terrain/native/tests/texture_layers.gd`：真实 GPU 数组读取、刷材质、撤销、独立数组、平地与坡度画面对比、地图视图。
- `misc/feng-addons/feng-idweight-terrain/native/tests/idweight`：R16 编码与坡度算法契约。
- `misc/scripts/tests/frp_passes.gd`：阶段调用、交换 Pass 后的实际画面、禁用 Pass、透视/正交及 MSAA。

图形测试需要实际 D3D12 / Vulkan 驱动，不能使用 `--headless` 验证 GPU 画面。

本机验证：Windows、RTX 3080 Ti，D3D12 与 Vulkan 均通过 Pass 排序、禁用、参数化
Compute、透视/正交、MSAA 关闭/2×/4×的画面回归。D3D12 另验证点光源和面积光。
地形通过数组设置、材质列表编辑、R16 笔刷 GPU 上传/撤销重做、坡度对比与地图视图测试。
本轮未提供 FPS 百分比基准，也未覆盖所有 GI、XR、多视图与第三方自定义 Shader 组合。

## 新建地形

选择一个尚无区域的 Terrain3D 节点时，编辑器会要求选择项目内的地形数据目录。
选择空目录会在当前 Scene 相机前方的地面网格中创建一个 64×64 区域，并立即写入
`terrain3d*.res`。新地形关闭 World Background，仅渲染真实区域。场景会标记为已修改，
按 Ctrl+S 保存节点的数据目录和材质设置；之后保存场景也会保存地形编辑。

选择已有区域文件的目录会加载已有地形，不覆盖其区域大小或背景设置。取消选择不会
创建区域；可以在 Terrain 菜单的 Initialize Terrain… 重试。已有区域的地形不会
自动初始化。要扩大地形，选择 Add Region（E）并在空白地面上点击；该工具通过地面
平面定位，因此不依赖无限背景或已有地形几何。
