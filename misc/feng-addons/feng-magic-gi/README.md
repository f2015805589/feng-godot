# Feng Magic GI

Feng Magic GI 提供两种漫反射全局光照模式：`PRT MagicGI` 预计算表面传输并在运行时重照明；`Surfel MagicGI` 在运行时维护表面缓存并用光追更新间接光。两种模式共用 `FMagicGIVolume` 和 Magic GI 渲染入口。Surfel 的缓存与照明保持场景线性；预曝光由最终合成应用一次，接收材质、AO 和 GI 强度也在最终合成时处理。

## GI 模式

`FMagicGIVolume` 默认使用 `PRT MagicGI`，旧场景继续沿用原有 Bake 数据和流程。选择 `Surfel MagicGI` 后，Surfel 模式会从当前场景快照自动覆盖可见表面，并在运行时追踪光线更新表面间接光；不需要离线布点，也不需要执行 Bake 或 Refresh。Surfel 缓存在 World 内共享并受容量预算限制，新表面首次覆盖和历史收敛需要运行一段时间。Volume 的 `size`、启用状态和 GI 强度仍共用；Surfel 参数控制半径、数量上限、每帧更新量、射线数与距离、历史权重和调试视图。Inspector 会显示 Surfel 参数并隐藏 PRT 的 Bake、Refresh 与布点参数；切回 PRT 时，原有 `bake_data` 和 manifest 保留。

Surfel 模式默认使用半分辨率 NRD RELAX 降噪；它需要 `feng-raytracing` 的 NRD 扩展以及支持硬件光追的 D3D12 或 Vulkan 渲染路径。NRD 不可用时，Surfel 会明确回退到 World Cache gather，GI 仍保持工作；降噪历史按渲染目标和视图分别保存。无需启用 `RTGI Diffuse` pass。当前场景快照支持刚体、骨骼蒙皮和 blend-shape `MeshInstance3D` 表面，以及 `BaseMaterial3D`；`ShaderMaterial`、透明接收表面和自定义 area-light 纹理暂不支持。

Surfel 还会自动维护三级世界空间 SH4 低频 probe field，在表面缓存覆盖不足时补充间接光；最多 1,536 个记录，每个 176 字节，不需要离线 Bake。探针更新从既有每帧射线预算中划分，探针照明射线最多 256 条/帧；该低频补充仍受硬件光追与当前场景快照支持范围约束。

表面分布默认启用两级 footprint LOD：细级使用设置半径 `r`，粗级使用 `2r`；LOD 将 8 个屏幕像素对应的世界空间 footprint 与 `r` 比较（16×16 屏幕 tile 的半宽），并用迟滞避免相机轻微移动时反复切换。每个轮到的 16×16 tile 检查四个分布在 8×8 象限的代表点；位置按 tile-sweep 游标轮换，使每个象限的 64 个像素位置都能在 64 次完整 tile sweep 内被检查。它优先补入目标 LOD 中尚无兼容缓存记录的位置，每个 tile 最多提交一个候选，且不按亮度单独加密。相机接近时缺少的细级覆盖会补入，远离时维护阶段将锚点迁移或回收；相机 LOD 改变分批维护，场景表面变换后会先重定位当前缓存记录，再让该帧 gather 使用它们。跨级查找会去掉相同表面三角形上位置重合的候选，并保留既有表面兼容与真实 LOS 检查。

Ray Guiding 使用每个表面记录的 4×4 余弦半球分布，继续保留至少 25% 的余弦采样概率。每批射线读取冻结的上一分布，并使用混合 PDF 做光照估计及发光命中 MIS；新样本只更新下一分布，避免同一批中采样和 PDF 不一致。该分布只改变采样效率，不裁掉或额外缩放辐射值。

设计参考：EA 的 [GIBS 技术介绍](https://www.ea.com/news/gibs-lighting-ea-sports-college-football-25) 与 [SIGGRAPH 2024 演讲幻灯片](https://advances.realtimerendering.com/s2024/content/EA-GIBS2/Apers_Advances-s2024_Shipping-Dynamic-GI.pdf)。

Surfel 的 `Debug View` 可通过 Feng Render Pipeline 的 `Debug Buffers` → `Magic GI` 查看贡献；调试内容只写入 sidecar，不改变正常 `SceneColor`。

### PRT MagicGI 烘焙数据

新烘焙同时保存表面响应和完整的 SH9→SH9 方向传输矩阵。首段天空、次级反弹、自发光分开保存；方向数据可以按接收法线进行余弦卷积。重照明时以同批路径的表面估计校准 SH 常数项，抑制高亮发光面在背面半球的低阶振铃。两种响应共享球面低差异路径及后续余弦采样的求交结果。烘焙以只读几何快照分发到 CPU 工作线程，每个任务独占一个探针的数据，完成后统一合并；取消、场景关闭和静态内容改变均会丢弃未完成或过期结果。距离矩使用 8×8 八面体图集，每格至少追踪四条射线。旧 v2–v6 烘焙继续读取原有表面响应，不会把旧的 27 个系数误当作方向矩阵。

## PRT 使用与烘焙

1. 启用 `Feng Render Pipeline` 和 `Feng Magic GI`，将两个插件链接到 `res://addons/`
2. 添加 `FMagicGIVolume`，调整 `size`、`Probe Spacing` 和表面偏移。默认基础间距为 1 米；探针沿可证实表面的外侧安全偏移，并保留表面锚点。非自适应布局使用以世界原点对齐的基础间距网格，每格最多一个探针、探针中心至少相隔一个基础间距。自适应布局按有效最小间距网格保证每格唯一，跨密度探针中心至少相隔两者实际间距的平均值；Volume 的旋转或缩放不会改变米制密度。平面按 dominant-axis 投影采样世界格点，拥挤时按有界、确定性的空间覆盖顺序选点；小三角、狭长面和局部细节仍经过相同的安全检查。闭合体内部及靠近其他表面的候选会丢弃或提示；无需碰撞体，无几何时不生成探针。`Adaptive Placement` 和 `Use CLV` 对新 Volume 均默认开启且相互独立；显式保存的 Adaptive 关闭状态仍受尊重。结构有效的旧 v6 烘焙会继续发布旧预览并标记为过期，不会自动改写或重烘；布局更新后，显式刷新布点并重新 Bake
3. 在 Inspector 的 **Bake quality** 选择 **Draft 256**、**Final 1024** 或 **High 2048** rays/point，或通过 `Bake Samples` 自定义。默认 256。新 Volume 默认启用分块 Bake，点击 **Bake Streamed PRT**；关闭 `chunked_baking` 的旧单资源模式才使用 **Bake PRT Transfer**。`Bake Bounces` 和 `Bake Distance` 控制路径深度和距离。烘焙在 CPU 分批执行，完成后场景标记为未保存
4. 新建 Feng Renderer 默认在 Lighting 后启用 **Magic GI** pass。无有效烘焙或同世界 Volume 时，pass 保持场景颜色不变。启用 **Debug Buffers** 可检查材质、法线、AO、运动向量和 Magic GI 贡献

每个 World3D 选择最新有效且启用的 Volume，不混合多个 Volume。快照按世界和视口渲染目标路由。已有场景保留已保存的设置；修改布局、几何或烘焙参数后需要重烘，Inspector 显示实际/请求样本数及过期原因。**Refresh Surface Points** 可立即刷新预览。

### 分块 Bake 与流送

新 `FMagicGIVolume` 默认启用分块 Bake。世界 XZ 平面按原点对齐的 512 m 管理块划分，负坐标使用向下取整；每块内部默认按 32 m 稀疏小页烘焙，并沿 Y 继续分层。超过单页网格、工作量、纹理或驻留预算时会继续细分，空页不保存数据。512 m 是管理边界，不是单个稠密网格，也不限制整个场景的总探针数。

Inspector 的 **Bake Streamed PRT** 重烘当前 Volume，**Bake Selected Block** 按 X/Z 管理块坐标局部重烘，并包含受该块影响的邻页；烘焙期间可点 **Cancel Bake**。取消、场景变化或失败不会替换仍可用的上一份烘焙。manifest 与页数据压缩为二进制 `.res`，默认写入 `res://bake/magicgi/<scene_and_volume_id>/`；旧 generation 不会自动删除。每个新页独立加载，manifest 只保存轻量索引。

流送默认最多并行准备 2 页，CPU 驻留预算为 256 MiB、GPU 驻留预算为 128 MiB、纹理上传预算为 16 MiB/帧；可在 Volume 的 Page Streaming 设置中调整。超出预算时系统保留较近的页，其他页等待预算释放后再加载。已有 `bake_data` 的 v2–v6 资源继续按旧路径读取，不会自动转换；显式执行分块 Bake 后才使用新 manifest。

## 自适应布点与体积缓存

- `Adaptive Placement` 对新实例及未序列化字段默认开启；显式保存的 `false` 仍会关闭它。它与默认开启的 `Use CLV` 相互独立。`Probe Spacing` 决定平滑区域的基础间距，`Minimum Probe Spacing`（默认 0.25 m，支持 0.1–1 m）决定局部细化间距。系统先收集基础世界格与表面候选，再用几何特征和规范三角形标记拐角、曲面变化、小三角及窄构件所在区域；命中单元及其一格邻域才生成细间距候选，平滑区域保留基础间距。粗、细候选一起经过体积内外、表面侧、净空和安全偏移检查，再按确定性世界格与跨密度最小分离规则统一裁决；细探针按真实局部间距显示。
- 自适应布局使用稀疏单元范围和连续探针索引，每格不再截断为 8 个。细密探针的空间影响范围按局部间距收缩，避免查询成本和光照模糊随密度扩大。旧单资源路径受 Placement 安全上限约束：最终最多 65,536 点。分块 Bake 没有全场景总探针数上限；当前每页最多 32,768 个探针，以适配不超过 16 MiB 的 moments 纹理，并会按网格、工作量及驻留预算继续拆页。探针越多，CPU 烘焙工作量与资源大小越高；Adaptive 只在标记区域增加探针，不会降低每探针射线数或反弹数。参考：受控旧 F6 Cornell 场景以 1 m 基础间距、0.25 m 最小间距生成 4,087 个探针；r5、每探针 1,024 射线、2 次反弹、3 个发光源的烘焙用时 163,096 ms，资源为 11,169,794 字节。该时间是本次测量值，不是性能保证。
- `Use CLV` 默认开启，Adaptive Placement 独立控制是否局部加密探针。新方向烘焙使用三层 16³ toroidal/scroll 缓存，逐级扩大世界覆盖范围并通过 3D 纹理硬件三线性采样。缓存焦点受烘焙几何边界约束，并为三线性角点和接收法线偏移保留内缩范围；几何范围较小时居中，范围外的相机不会把最细层浪费在 Volume 边缘。`CLV Cell Size` 为最细一级世界网格间距，后续逐级翻倍；`CLV Cells Per Frame` 限制每帧更新量，默认 256，上限 512。
- CLV 填充保留通过可见性检查的探针，并在首个 SH 系数的空闲 alpha 中记录一个可见探针作为距离矩参考，不增加纹理分配。像素阶段从缓存选择接收表面归属，使用已有的烘焙距离矩和 Chebyshev 权重过滤插值角点；天光可见性继续控制 primary sky，二者用途独立。部分角点有支持时，按可见性过滤角点后归一化重建；全部角点置信度较低时拒绝该层，避免将微弱可见性放大到全亮；无支持才继续查较粗级或使用烘焙距离矩的探针查询。像素着色器不遍历静态 BVH。烘焙和有预算限制的 CLV 填充仍可查询场景几何，光照刷新复用已有的接收表面和可见性证明。
- 每个视口独立缓存，相机移动只补充进入的格子。世界坐标、几何版本和布局共同验证缓存；几何变化使标签失效，光照内容变化排队刷新并保留上一个完整结果。八角元数据有效且可见性权重完整时使用硬件三线性插值；环形缓存接缝、部分支持和可见性过滤区域逐角读取。无效角点不读取辐射系数，支持有效的黑色光照保持合法。
- 缓存更新时为八角邻域生成同平面、同表面片和遮挡范围证明，并预先计算接收法线方向的次级与天空漫反射。匹配的平面像素读取两组硬件三线性结果；GBuffer 法线量化允许的偏差为 0.01，明显变化的曲面及法线贴图继续重建 SH。证明随几何标签失效，光照刷新复用几何证明；环形接缝和缺少证明的区域保留逐角距离矩过滤。
- CLV 首次填充同时缓存可见探针及独立的次级、primary sky 插值权重。光照更新只重算这些权重对应的 SH，不重复空间搜索和遮挡查询；每个表面槽最多缓存 16 个贡献项，超过容量时保留完整查询。权重使用 32 位浮点数，随世界格、几何标签或网格间距变化重建。该缓冲每个视图占 7,667,712 字节，CLV 可计量 GPU 资源合计 20,897,888 字节，另有驱动管理的着色器、管线和采样器对象。
- 在 Magic GI pass 选择 `CLV Debug View`，再在 Debug Buffers 选择 `Magic GI` 查看诊断。`Cascade Levels` 用绿色、橙色、蓝色表示 L0、L1、L2，精确求值回退为洋红；`Cache Validity` 用绿色表示完整支持、琥珀色到绿色表示经过可见性过滤的部分支持，并按颜色区分拒绝原因。`Cells` 显示物体表面上的采样网格，不是完整 3D Volume gizmo。颜色诊断将 `GI Exposure` 设为 0 EV；`Reconstructed Lighting` 可用该值调显示亮度，显示接收材质反照率、AO 和 GI 强度应用之前的重建光照。调试只改 GI 输出 RGB；场景颜色和 GI 所有权 alpha 仍由正常合成路径处理。
- 旧烘焙继续使用已有表面数据。关闭 `Use CLV` 可对照使用烘焙距离矩的逐像素探针求值。每个视口的 CLV 数据、有效性标签和小型工作缓冲约 12.62 MiB，最多保留四个视口。运行时每探针保留 32 字节旧表面输出缓冲；方向输出另占 320 字节/探针，法线另占 16 字节/探针。方向传输、天空和发光传输数组的 GPU 上传缓冲另计。实际烘焙资源还包含传输数组、查找索引和场景 BVH：本次 4,087 探针、3 个发光源 Cornell 资源为 11,169,794 字节，约 2,733 字节/探针（含本场景 BVH 与资源元数据）。
- 受控旧 F6 Cornell 的布点 profile 中，旧全域细候选布局耗时 3,772 ms、生成 47,466 个 raw 候选并最终放置 3,982 个探针；分层布局耗时 1,620 ms、生成 9,683 个 raw 候选并最终放置 4,087 个。相同 r5 质量参数（1,024 rays、2 bounces、3 个发光源）的两次独立 bake 分别为旧布局 207,405 ms / 10,884,614 字节和新布局 163,096 ms / 11,169,794 字节；新布局探针数增加 2.6%。这些是受控 Cornell 跑次记录，不代表其他场景或硬件的普遍耗时比例。

方向数据仍是低频 SH 漫反射表示；增加空间密度不能恢复锐利镜面反射，也不能替代动态几何光追。

## 动态光照与自发光

每帧将同世界可见方向光投影到 SH；Volume 的 `Sun` 可覆盖自动选择，切换或清空会使直接光缓存失效。物理模式使用 lux 和相关色温，非物理模式使用引擎归一化能量。天空照明由 ready 的 `FengSkyLight` 提供，缺省为零；其 SH 独立用于 primary visibility，与方向光合并后用于 secondary transport。太阳和发光源独立工作。`Lighting Environment` 保留为旧场景序列化字段。

结构有效的 v6 Bake（含过期预览）在 Volume 覆盖的 opaque 像素按强度权重替换全局 SkyLight 漫反射；SkyLight 镜面反射、局部反射探针和 Volume 外像素保持不变。透明材质不在本 pass 的替换范围内。过期预览仍替换 SkyLight，不额外叠加未遮挡环境光；几何或材质输入改变后需重新烘焙。候选先通过法线、平面和网格窗口筛选，再对探针中心到真实接收面的直连线段做双面三角形遮挡查询。有墙相隔就拒绝该候选，即使两侧法线相同、墙无厚度、方向距离矩被远处开口平均成无遮挡也一样。v6 以精确几何查询决定可见性，不再叠加粗粒度距离矩造成的墙角误遮挡；旧格式预览仍使用 Chebyshev 距离矩。被遮挡候选不参与归一化。如果像素没有通过邻域/平面筛选的探针候选，pass 保持场景颜色不变；如果有候选但全部被遮挡，贡献为零，仍按 SkyLight 替换权重扣除漫反射 SkyLight。

烘焙与 CLV 填充使用静态几何进行直连遮挡和曲面延续检查，无需硬件光追。运行时像素使用缓存的表面归属、有限三角形深度修正和烘焙距离矩；已证明的同平面邻域直接插值。静态遮挡查询每次最多访问 256 个 BVH 节点，达到预算时保守拒绝。动态几何需重新烘焙；透明表面和 CPU 地形采样未包含的细节不构成静态遮挡。

PRT v3 及以上格式为不透明 `BaseMaterial3D` 发光表面保存独立传输，每个 Volume 最多 32 个发光材质表面。启用发光源后先重新烘焙；随后可实时改变颜色、强度、`emission_enabled` 和 Add/Multiply 运算符。物理模式还会乘以 `emission_intensity`。

已烘焙发光绑定的开关与辐射参数是实时值；新启用或新增、但未烘焙绑定的发光面会单独提示重烘。Magic GI 是漫反射传输，材质 roughness 和 specular 设置不参与烘焙输入。

- 发光纹理、UV 映射或剔除模式改变时，仅该源暂时停止贡献并提示重烘；方向光和天空传输继续可用
- 发光源移动或静态几何改变会使整体几何传输过期

动态光照支持远场方向光、SkyLight 辐射和已烘焙发光面；不包括点光源、聚光灯、镜面传输、透明表面或 `ShaderMaterial` 自发光。

## 几何、材质与容量

- `ArrayMesh` 从各三角形表面采样。单材质非 `ArrayMesh` 通过 `PrimitiveMesh.get_mesh_arrays()` 或 `Mesh.get_faces()` 采样；无法还原各面材质的多材质非 `ArrayMesh` 拒绝烘焙
- Terrain3D 通过支持洞孔的 `get_surface_height()` 采样。CPU 不执行地形分层 shader，使用 `Terrain Reflectance` 作为漫反射反照率
- `BaseMaterial3D` 使用 albedo tint、metallic 和 UV0 albedo 贴图。CPU 采样保留 UV 缩放、偏移、重复和最近点/双线性过滤，并对 sRGB 贴图解码一次；HDR 浮点纹理保持线性。缺失 UV 或三平面贴图会拒绝烘焙。`ShaderMaterial` 使用 `Fallback Material Reflectance`。透明表面跳过
- 上限为每轴 64 个运行时查找网格单元、每个世界间距格 1 个探针、非自适应布局每个运行时查找格最多 8 个样本、65,536 个探针/候选世界格、每格最多 8 个几何域且每域最多 2 个候选、32 个发光表面、250,000 个网格三角形，以及包含 PRT、发光遮挡和方向可见性射线在内的 100,000,000 CPU 路径工作预算。超过容量会报错。世界间距格使用实际中心和全局世界坐标；运行时查找格仍按 v6 表面锚点与 Volume 局部网格构建

## 编辑器预览

**Show Probes** 默认开启，球心取实际探针中心，半径按基础显示网格缩放并乘以该探针真实局部间距比例；显示不会移动探针或为遮住重叠而缩小标记。标记显示当前完整 GI 响应（次级传输、首段天空和当前有效的发光贡献，再乘 `gi_strength`）；蓝色仅表示零响应。结构有效的过期 Bake 仅在保存的探针中心与当前布局逐项匹配时参与预览，否则标记为灰色。**Show SH Probes** 默认关闭，开启后最多显示 256 个归一化径向图，表示次级传输与首段天空可见性除以 π 的单位白光角向响应；这个视图展示单位远场光的传输响应；当前自发光贡献显示在 Probes 标记中。

## 模块与数据契约

- `FMagicGIVolume` 管理设置、布局匹配、异步烘焙和预览
- `FMagicGIPlacement` 管理几何、布点和 BVH；`FMagicGIEmitterBakeSet` 通过 Placement 的 `emitters` 独占发光绑定、签名和面积采样，Baker 直接读取同一对象；`FMagicGIEmitterBinding` 管理稳定键和签名；`FMagicGISceneTracker` 跟踪场景/资源变化
- `FMagicGIBaker` 管理烘焙提交，`feng_magic_gi_directional_baker.gd` 积分路径，`feng_magic_gi_directional_data.gd` 定义方向数据，`feng_magic_gi_adaptive_layout.gd` 选择局部密度；`feng_magic_gi_visibility.gd` 构建和验证静态遮挡 BVH；`FMagicGIData` 验证持久化资源、组合发光响应并打包上传数据
- `FMagicGIRuntime` 选择 Volume 并发布世界/视口快照；每个 `RuntimeState` 只持有注册信息和独立的光照/发光对象；`FMagicGIEmission` 独占源参数、响应缓存和警告，诊断刷新不改写已发布响应。warning getter 只读
- `FengMagicGIPass` 通过可选 Runtime 路径消费快照，管理 RD 纹理、UBO 和释放。Inspector/Viz 负责编辑器操作与预览

`FMagicGIData` 保存 v6 世界空间表面锚点、实际探针中心/法线、布局、场景签名及查找索引。每个样本远场次级传输为 27 个 float，按系数优先、RGB 连续排列：`Y0`、`Y1-1(y)`、`Y10(z)`、`Y11(x)`、`Y2-2(xy)`、`Y2-1(yz)`、`Y20(3z²-1)`、`Y21(xz)`、`Y22(x²-y²)`。远场图集每样本 7 个 RGBA32F texel；primary SkyLight 可见性另存 9 个可能带正负号的标量系数，每样本用 3 个 RGBA32F texel 打包。几何图集每样本 3 个 texel；8×8×2 个距离矩通道共占 512 字节/探针；固定密度布局每网格单元含 8 个有符号 32 位样本索引，自适应布局改为单元范围和连续索引。可选方向数据独立版本化：每探针 243 个次级传输 float、81 个天空传输 float，以及每发光源 54 个传输 float。旧格式预览的每个候选双线性采样四个 moment texel。BVH 另用两个只读缓冲：每节点 32 字节、每三角形 48 字节，叶节点最多 4 个三角形，使用 8 桶、3 轴表面积代价划分，深度优先排列并带跳过子树索引，CLV 更新中的几何遍历不需要栈。三角形 w 通道存预计算面积、行列式阈值和平滑表面片 ID；探针锚点的表面片只在创建上传数据时定位，并写入几何图集的空闲 alpha。射线逆方向每次查询只计算一次。

运行时远场图集在首次上传打包时对每个探针/颜色通道应用 SH9 非负窗口，只缩放 `l>=1` 并原样保留 DC 系数；持久化传输系数和 bake 格式不变。独立 GPU 重照明阶段按探针计算次级传输＋发光和首段天空两个 RGB 结果，以每探针 32 字节缓存。只有光照 SH、天空 SH、发光源身份或版本变化时重新计算；相机、曝光、接收材质和 GI 强度变化复用缓存。逐像素阶段读取缓存，并完成几何可见性筛选、插值和材质响应。曲面外侧空隙仅在出现曲面候选时查询一次。

v3 及以上额外保存发光源稳定键、静态签名及每源每样本 6 个 float，顺序为 source、probe、常量 RGB 响应和纹理 RGB 响应。动态 SH 与发光参数独立于烘焙资源。组合函数始终返回每探针一个有限 RGB 值；非法输入或溢出返回零响应。

当前可载入 v2–v6 格式。与当前场景签名、布局和烘焙设置完全匹配的 v5 在首次表面刷新时自动升级为内存中的 v6：复用已收集的几何构建 BVH，原有 transport、emission、primary sky 和 moments 逐字节保留，不重新积分、不自动保存。显式调用 `FMagicGIBaker.new().upgrade_visibility_bake(volume)` 也可获得新的资源；不匹配时返回 `null`，不会修改 Volume 或旧资源。失败尝试按资源、场景及设置缓存，不逐帧重试。过期 v5 仍按原有距离矩保留预览，并提示需要升级或重烘才能获得精确静态遮挡；不会将其伪装为 v6 数据。v2/v3/v4 以及已经过期的 v5 需重新 Bake。当前球面低差异采样器版本为 r5：每个路径顶点对每个发光源执行面积 NEE，并与同一路径方向首次命中的该源按 power heuristic 互补配权；常量和纹理传输分开保存。采样方向用于 PDF、余弦项和首跳 SH，shadow visibility 从同一未偏移顶点沿相同物理射线查询。NEE 与发光命中共用稳定 source group、face 映射、UV0/UV2 变换、贴图采样及 cull 规则。旧格式仍可读取与预览，新 r5 估计器需重新烘焙；调整质量只改变请求值，不改写旧烘焙的样本数。

## 测试

无 GPU 的世界/视口所有权和物理/非物理光照检查：

```sh
python misc/scripts/test_feng_runtime_contracts.py --editor /path/to/godot
```

在已导入上述插件的隔离项目中，运行无界面契约测试：

```sh
/path/to/godot --headless --path /path/to/project --script res://addons/feng-magic-gi/tests/test_runtime_state.gd
/path/to/godot --headless --path /path/to/project --script res://addons/feng-magic-gi/tests/test_sh_filter.gd
```

完整 PRT 与 GPU 集成：

```sh
python misc/scripts/test_magic_gi.py --binary /path/to/godot --driver vulkan
python misc/scripts/tests/run_frp_exposure_balance.py --binary /path/to/godot
```

`test_magic_gi.py` 覆盖布点、方向积分、GPU/CPU 重照明一致性、缓存滚动与版本失效、贴图颜色空间、烘焙保存重载、发光源变化、相机变换和视口路由；Linux 无显示器时可加 `--xvfb`。曝光测试使用程序天空、Height Fog 和合成 PRT，在 60,000 lux 物理模式下检查 GI/Fog 可见贡献，以及 pre-exposure 开关的 LDR 差 ≤ 0.01、曝光 scale 差 ≤ 2%。日志、隔离项目和可选 PNG 保留在 `bin/` 下。
