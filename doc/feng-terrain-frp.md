# 地形数组与 FRP Pass

## 批量创建地形

新建 Terrain3D 后选择空的数据文件夹，在 **Create Terrain Grid** 中输入
**Width (X blocks)** 和 **Depth (Z blocks)**，点击 **Create Terrain**。
每块固定为 512 × 512 米（`region_size = 512`、`vertex_spacing = 1`）；
20 × 20 会生成 400 块连续地形，总范围为 10,240 × 10,240 米。
窗口实时显示块数和米/公里尺寸。网格围绕编辑器视图对齐，靠近世界边界时自动平移到合法范围。

创建按批次保存并显示进度，最后统一更新地形贴图；停止时保留已创建的地块。
当前一次创建数量受材质的驻留 region 上限约束，默认最多 1024 块。
选择已有地形文件夹直接加载原数据，不会覆盖成空白网格；取消尺寸窗口不会创建文件。

## VT 检查

底部地形面板的 **Terrain → Surface VT Editor…** 打开分页信息窗口。
**Surface VT → VT Setting / AVT / SVT / VT Page** 可逐层折叠。
VT Page 按世界坐标拼接已烘焙的 SVT 材质页；点击区块可定位 Terrain3DRegion 数据。
驻留页显示 Ready、Pending bake、Pending upload、Missing bake 或 Stale/invalid bake。

VT Setting 统一管理物理缓存和生产预算，AVT 与 SVT 使用独立寻址表、共享物理页池。
AVT 在配置的可见地块网格内实时 GPU 烘焙；其他地块从离线 cell 源贴图生成 SVT 缓存页。
正常 VT 模式不会回退到原始地形材质，也不会在 AVT 缺页时改用 SVT；
同一视图可以读取有效祖先页，仍无有效页时显示紫色棋盘诊断。
SVT 默认开启 **Auto Bake**：地形修改停止 500 毫秒后增量更新受影响 cell 的源贴图与 mip 链；无变化时不持续烘焙。也可以用 **Bake All SVT Cells** 一键强制重烘全部 cell 源贴图。

原生 **VT Pass** 位于 GBuffer 前；RenderDoc 保留配置的 Pass 名称和顺序，
包括没有烘焙工作的空闲 VT Pass。空闲标记不执行 GPU 烘焙。
详见 [VT 架构检查](../misc/feng-addons/feng-idweight-terrain/docs/vt_architecture_review.md)。

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

Terrain3D 的 **Surface Density**（1/2/4/8 texel·m⁻¹，默认 1）决定 Surface Maps 的**存储**分辨率：每个 region 存 `region_size × density` 见方的 R16（region 256、density 4 时 2 MB）。它是地形级设置，因为材质数组是一张纹理、所有层必须同尺寸。数组层本身始终是 `region_size`（1 texel/m），只保存每个密度块的块首 texel，用于 VT 关闭时的原始材质计算及显式诊断模式；正常 VT 模式从 AVT 或 SVT 材质页读取结果，不使用此数组作为缺页回退。改密度会把内存里每个 region 的存档重采样（最近邻、按块，绝不重新从 Control Map 推导材质），旧档（无该字段、payload 为 `region_size²`）在进入内存时自动升采样。代价：撤销快照从 128 KB 涨到 2 MB/region（region 1024、density 4 时 32 MB），笔刷按 `density²` 整块写入。

Surface 材质使用 AVT 与 SVT 两级缓存。AVT 以 64 米 sector 动态分配虚拟地址并生成近景材质页；SVT 按地块预烘焙源图，运行时复制、组合需要的 mip 到共享物理页池。两者的纹素比独立于 R16 材质 ID 存储密度。

默认地块 512 米、AVT 1024 纹素/米、SVT 1 纹素/米。近景自动 mip、跨地块覆盖、编辑预览及缓存限制见下方说明和 [当前 VT 架构](../misc/feng-addons/feng-idweight-terrain/docs/vt_architecture_review.md)。正常材质 VT 缺页会使用已就绪父页或缺页诊断，不回到原材质求值；编辑预览和显式直接材质模式使用实时数组。

## 自定义 FRP Pass

随引擎提供 **FengPass** 系列资源，可在 Inspector 配置 Shader、纹理输入输出、参数和工作组。`addons/feng-render-pipeline/library/` 提供 tint/blur/fxaa/color-grade/bloom-lite 内置模板；`examples/tint.tres` 是可直接拖入的示例；复杂效果仍可继承 CompositorEffect。

### 三层架构

- **FengRenderer**（Resource）：`passes` 包含 8 个默认引擎 Pass（FRP 的全部条目就是这些 + 库里的 Color Grade，整条管线 9 条）与自定义效果；`apply(compositor)` 上传列表顺序及名称，自动挂载隐藏的 `FengTextureManager`。**pass id 连续且就是执行顺序，资源里的条目顺序就是引擎的执行顺序**（和 URP 的 RendererFeature 列表一样，拖动条目即改顺序；依赖约束只做校验）。FRP 没有 SSAO / SSIL / SSR / 全局光照与调试几何条目：Environment 里打开这些特性不会改变 FRP 的画面。
- **FengPass**（CompositorEffect）：单个 pass，`stage` + `inputs` + `outputs`；子类实现 `_render()`。`FengShaderPass` 提供 compute 与全屏光栅两种模式。
- **FengCompositor**（Compositor）：绑定 renderer 后自动同步 effects；pass 的 `enabled` 由引擎原生即时生效。

**一个 Pass 可以展开成多个内部 Operation**（resolve、屏幕/深度副本、高光合并、
运动矢量），所以这些记账步骤不再作为可独立开关的条目出现，但仍然照常执行。

运动矢量由 **GBuffer Pass 在同一遍几何里写出**：该 Pass 的 framebuffer 带上速度附件，shader 使用
带 `MOTION_VECTORS` 的 G-buffer 变体，速度写在 voxel-GI 槽之后的位置 5。TAA、3D 上采样与运动矢量
调试视图因此不再需要第二遍不透明几何，GBuffer 仍是唯一遍历不透明几何的 pass。旧资源（schema < 5）
里独立的 Motion Vectors 条目在加载迁移时折叠进 GBuffer。

中间纹理由 `FengTextureManager` 在 Pre GBuffer 阶段按 `FengPassOutput` 声明自动创建（scope `"frp_pipeline"`），分辨率切换自动重建；pass 通过 `Source.PIPELINE` 按名引用。

把 FengCompositor 挂到 WorldEnvironment 或当前 Camera3D，并为其 Renderer 指定资源。仅在文件系统创建或选中 FengRenderer 不会应用到场景；编辑器自由视角使用自己的相机，WorldEnvironment 可让它也使用同一配置。完整列表、约束和自动同步规则见 [FRP 插件说明](../misc/feng-addons/feng-render-pipeline/README.md)。

以下阶段表用于普通 Compositor 的兼容路径：在 Compositor Effects 添加脚本资源，Effect Callback Type 选择阶段，同阶段按数组顺序执行。FengRenderer 的显式列表以实际位置为准。

| 实际执行顺序 | 可用数据 |
| --- | --- |
| FRP: Pre GBuffer | 可准备自定义资源；当前帧的深度和颜色尚不可读 |
| GBuffer + MSAA Resolve | 引擎必要阶段 |
| FRP: Post GBuffer | 深度、法线、材质数组 |
| Pre Opaque | 保留原有回调，位于屏幕空间效果之前 |
| SSAO / SSIL / GI 等（FRP 不运行） | FRP 没有这些 pass，开关它们不改变画面 |
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

RenderDoc 场景事件按 **Pass 名称 → 内部操作** 展示。**VT Pass** 在 GBuffer 前执行材质页面更新；地形的自定义顶点变形已接入 GBuffer，深度和法线随变形输出。最终把 Scene 纹理合成到编辑器 UI 的绘制不是场景几何。D3D12 编辑器无需额外启用 PIX 即可输出标签；Vulkan 非开发构建需用 `--verbose` 启用 debug utils。关闭或本帧没有 GPU 工作的条目不会产生事件。

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
选择空目录后可输入 X/Z 地块数量；每块实际覆盖 512×512 米（512 样本、1 米间距）。
例如 20×20 地块覆盖 10.24×10.24 公里。创建会分批执行，并立即写入
`terrain3d*.res`。新地形关闭 World Background，仅渲染真实区域。场景会标记为已修改，
按 Ctrl+S 保存节点的数据目录和材质设置；之后保存场景也会保存地形编辑。

选择已有区域文件的目录会加载已有地形，不覆盖其区域大小或背景设置。取消选择不会
创建区域；可以在 Terrain 菜单的 Initialize Terrain… 重试。已有区域的地形不会
自动初始化。要扩大地形，选择 Add Region（E）并在空白地面上点击；该工具通过地面
平面定位，因此不依赖无限背景或已有地形几何。


## AVT 纹素比与自动 mip

地块为 512×512 米，内部包含 8×8 个 64×64 米 AVT sector。VT 设置使用独立的
AVT/SVT 纹素/米，移除 AVT 分辨率下拉框。物理页 256 纹素时，768 纹素/米对应
49152×49152 虚拟图像，192×192 有效页条目，分配 256×256 页表块；1024 纹素/米
对应 65536×65536 虚拟图像。页表固定为 2048×2048 条目，物理页按可见需求驻留。
AVT 按屏幕像素覆盖的世界面积自动选择 mip，相邻已就绪 mip 插值；旧距离数组不再控制 sector 模式。
界面固定显示三档纹素/米，默认 1024、512、256；编辑任一层联动整条标准减半链。
缩放页表复用已有兼容 mip，细节按每帧预算异步补充。
SVT 密度独立设置，但其固定世界页表的可覆盖范围随密度提高而缩小，面板显示该范围。
当前 sector AVT 使用 CPU 可见范围需求，而非 GPU PageID feedback。

AVT/SVT 同时开启时，AVT 使用相机周围的水平距离范围（默认 512 米）并按视锥请求，跨地块连续覆盖。
最外侧 25% 范围渐变到 SVT；近景内部缺页仍使用 AVT 父 mip。Region Grid、Offset、Forward 控件已移除，旧值不再影响 sector AVT。
SVT 默认密度为 1 纹素/米。512 米地块烘焙为一套 512×512 源贴图（三个材质通道，含完整 mip 链），
保存到 `svt_cells/<x>_<z>_0.vtcell`；运行时提取需要的 mip 区域，由 GPU 复制/组合物理缓存页。
同一张粗页可以覆盖多个 cell；改变物理页尺寸不要求重烘焙源图。编辑会使相关 cell 源失效并重烘焙。
旧 `.vtpage` 文件保留但不再读取，已有场景需重新 Bake SVT 一次。浏览器按 cell 显示源结果。
当前 cell 分辨率上限为 8192；读取及烘焙导出仍在主线程执行，尚未实现后台流送线程。

AVT 过渡修正：细分后保留父 mip，并补齐大范围根页到 64 米 sector 的中间层级。
按屏幕需求细化整个可见树，不再只给最近的一批 sector 细节页。
缺少同精度邻页时，边界渐变到父级；同精度页之间保持清晰。新页以 200 ms 淡入。
768 等非二次幂密度按真实世界纹素尺寸衔接 mip，避免 sector 与世界父级交界跳变。
父级占用计入原有缓存预算，未通过增大默认物理页池掩盖问题。

编辑器默认开启 `vt_editor_preview`：实时材质和表面数组直接显示笔刷修改，暂停 VT 请求及 SVT 自动烘焙。
关闭预览时合并刷新脏地块并恢复 VT；手动 Bake 仍可使用。该选项在运行游戏时不生效。
保存地形不等于更新离线 SVT 缓存，发布前需显式烘焙或关闭预览后等待自动烘焙完成。
AVT 的 mip 距离控件已再次移除，使用自动屏幕 mip；旧固定距离 API 保留为空操作兼容入口。SVT 距离设置保留。
界面仍保留三档纹素比，底层保留完整 mip 链。默认 1024 纹素/米对应每个 64 米 sector 的 65536×65536 虚拟图像，
并非实际驻留这么大一张贴图；实际细节还受到屏幕需求、源材质及共享物理缓存预算限制。
AVT 逐页生成增加约 3 ms 的 CPU 软预算，单页不可中断；稳定且无需 mip 混合的像素跳过粗级材质查询。


## 地形性能与架构审查

附近已生成的 AVT 页面及虚拟地址跨转向保留；可见需求优先，空闲时只用空槽预取周围页面。页表改为渲染线程按 16×16 脏块合并上传，避免稳定视角反复传整张页表。首次进入新区域、缓存不足或材质修改仍可能出现细节补充。

内置编辑预览/关闭 VT 的 shader 在编译期移除 VT 资源与函数，预览不声明八个 VT 采样器。Clipmap 共享七种唯一网格，实例分组使用原生容器并跳过未变化的变换提交；MultiMesh 按批次上传，按 cell/region 聚合实例时不再逐个复制颜色数组。删除不可达 SVT 调度分支、被覆盖的 shader 计算和无人使用的高度页副本。接缝几何、位移相关包围盒及自定义 shader 接口保留。

Windows / RTX 3080 Ti / D3D12 的固定转向测试：热缓存 AVT CPU 更新从约 3.6–4.1 ms 降至约 0.27–0.32 ms，四次热转向没有生成新页、采样画面误差为零。该数据不是整体 FPS 或 GPU 加速倍数；冷启动仍有差异。完整测量范围、图像基线、源码清单和剩余限制见 [优化审计](../misc/feng-addons/feng-idweight-terrain/docs/terrain_optimization_audit.md)。
