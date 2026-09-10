# 地形数组与 FRP Pass

## 地形材质

选中 Terrain3D，打开 **Assets → Texture Array**；地形材质面板的 **Texture Array** 按钮也能进入。

- 每个地形独立持有数组和设置。数组按 Layer ID 自动排列，最多 32 层。
- Albedo/Height 与 Normal/Roughness 分别存为一张 Texture2DArray，共用层序号。它们是同一套地形材质的两个通道数组。
- Size：Auto 使用第一个有效贴图的尺寸，也可指定统一尺寸。
- Mipmaps：默认开启；法线 Mipmap 会重新归一化。
- Compression：默认 BC7，也可选择 Uncompressed。保留 Alpha 中的高度与粗糙度；HDR 输入需选择 Uncompressed，使用 RGBAF，避免静默截断。
- Info 显示层数、尺寸、实际格式、Mipmap 和两张数组的估算 GPU 数据字节数。

新增 Layer、替换贴图、调整数组设置会自动更新。源贴图不被修改；缺失通道使用占位图。准备失败会保留上一套可用数组。准备好的层在内存中缓存，修改某层不会重新压缩其他未变化的层；第一次加载仍需处理源图，尚无磁盘烘焙缓存。

## 笔刷、坡度与地图

先用 Region 工具建立地形区域，再使用材质笔刷选择 Background / Overlay。

- Set：按权重绘制，不随坡度变化。
- Add / Sub：坡度增加 / 减少覆盖层的占比。
- Mix：按坡度混合。阈值来自 Weight Level，过渡锐度使用 Background 的 Slope Blend Sharpness，坡度衰减使用 Overlay 的 Slope Based Damp。
- 切换材质或修改笔刷尺寸不会覆盖材质保存的坡度参数。

**Terrain Maps** 打开实际地图数据；面板视图菜单可直接显示 Heightmap、Material IDs、Material Weight、Slope。

- Height Maps：地形几何高度图，RF。
- Surface Maps：实际材质 ID 图，R16 UNORM。它同时编码两个 5 位材质 ID、2 位混合模式、3 位权重等级与 1 位 UV 标志。没有另一张独立的 Weightmap。
- Control Maps：保留洞、自动材质等旧控制元数据。材质笔刷与吸管使用 Surface Maps。
- 贴图 Albedo Alpha 中的 Height 是材质微观高度，与地形几何 Height Maps 不同。

## 自定义 FRP Pass

随引擎提供 **FengPass** 系列资源，可在 Inspector 配置 Shader、纹理输入输出、参数和工作组。`addons/feng-render-pipeline/library/` 提供 tint/blur/fxaa/color-grade/bloom-lite 内置模板；`examples/tint.tres` 是可直接拖入的示例；复杂效果仍可继承 CompositorEffect。

### 三层架构

- **FengRenderer**（Resource）：声明式管线，`passes` 列表；`apply(compositor)` 把启用的 pass 按阶段分组写入 `Compositor.compositor_effects`，并自动挂载隐藏的 `FengTextureManager`。
- **FengPass**（CompositorEffect）：单个 pass，`stage` + `inputs` + `outputs`；子类实现 `_render()`。`FengShaderPass` 提供 compute 与全屏光栅两种模式。
- **FengCompositor**（Compositor）：绑定 renderer 后自动同步 effects；pass 的 `enabled` 由引擎原生即时生效。

中间纹理由 `FengTextureManager` 在 Pre GBuffer 阶段按 `FengPassOutput` 声明自动创建（scope `"frp_pipeline"`），分辨率切换自动重建；pass 通过 `Source.PIPELINE` 按名引用。

在 Camera3D 或 WorldEnvironment 的 **Compositor → Compositor Effects** 添加 CompositorEffect 脚本资源。设置 Effect Callback Type 选择阶段，拖动数组元素可改变同阶段的执行顺序，Enabled 可单独关闭 Pass。沿用 Godot 的 RenderingDevice 回调和资源生命周期，无需另建一套渲染 API。

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

阶段之间遵守数据依赖。拖动数组不会让 Pre Lighting 跑到 GBuffer 前；排序发生在同一个阶段内。这与 [Unity URP 的注入点](https://docs.unity.cn/Packages/com.unity.render-pipelines.universal%4017.0/manual/customize/custom-pass-injection-points.html)相同。新增阶段仅在 FRP 中调用；旧枚举数值不变，旧场景保持兼容。

在回调中通过 `render_data.get_render_scene_buffers()` 访问 RenderSceneBuffersRD：

```gdscript
var buffers = render_data.get_render_scene_buffers()
var albedo = buffers.get_texture("frp_clustered", "gbuffer_albedo")
var orm = buffers.get_texture("frp_clustered", "gbuffer_orm")
var emission = buffers.get_texture("frp_clustered", "gbuffer_emission")
var normal = buffers.get_texture("frp_clustered", "normal_roughness")
var depth = buffers.get_depth_texture()
```

不要把纹理 RID 跨分辨率切换、视口销毁保存。MSAA 开启时，Post GBuffer / Pre Lighting 读取解析后的单采样 GBuffer；Post Lighting 需要解析颜色时设置 Access Resolved Color。写解析颜色不会自动回写 MSAA 附件，后续 MSAA 解析可能覆盖它；输出颜色效果推荐放在 Post Transparent。回调运行在渲染线程，不能直接修改场景树。

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
