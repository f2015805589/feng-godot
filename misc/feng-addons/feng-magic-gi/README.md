# Feng Magic GI

Feng Magic GI 提供两种漫反射全局光照模式。默认 `PRT MagicGI` / `clv_cache_backend=1` 烘焙自由空间 TransferMatrix，并在烘焙端把几何遮挡和插值预处理为 CLV 线性算子；运行时以当前太阳、天空和已绑定自发光重照明，再由原生 PBR 硬件插值采样。当前新 Bake 使用分页 layout 6，旧单块 layout 5 仍可读取；重照明和像素采样均无 BVH 查询。`Surfel MagicGI` 在运行时维护表面缓存并用光追更新间接光。两种模式共用 `FMagicGIVolume`；独立的 FengLightmap Volume 不参与本 PRT 路径。

## 512 m 分页 CLV PRT

`MagicGIVolume → Page Streaming → Gi Radius M` 默认 **512 m 半径**，以实际摄像机位置为中心。它限制源块加载和接收像素的 GI 范围；不会扩大 Volume 的烘焙边界。没有烘焙数据的区域不能凭空获得间接光。原地转动视角不改变 CLV 格子或请求块。

最细层仍为 0.25 m，相邻层间距倍增。每层 16³ 时，512 m 覆盖需要最多 10 层（40,960 个驻留槽位）；24³/32³ 分别使用最多 9 层，以满足 3D 纹理深度限制。小场景迁移保留实际已有的四层，不额外生成远处数据。源块数量不受 16,384 的全域上限约束，GPU 只保存当前驻留格需要的算子。

- 每层只请求自己的 CLV 窗口，并与半径球相交。完全在球外的块不发起加载；相机移远后释放旧 CPU 块和 GPU 算子。异步 I/O 无法强行取消，已开始的过期请求只排空释放，不发布结果，其内存仍计入在途预算。
- 相交的边界块包含球外数据和一格插值邻接区；GPU 只取能影响球内接收点的样本，像素在距离 **大于 512 m** 时直接退出此 GI。范围外仍使用场景自身的环境照明。
- `Cpu Resident Budget Mib` 默认上限 1,024 MiB，按需占用，不预分配；可调至 4,096 MiB。GPU 默认 128 MiB，按实际算子池、纹理和缓冲计费，CPU 页面不会重复算作整页 GPU 常驻。预算不足显示缺页/预算状态，不冒充完整覆盖。
- 小场景 Bake 保留原积分和拟合，逐字节切成 `prepared_free_space_bricks_v1`。大于 32,768 个逻辑源格的场景改用各级独立采样的分块 Bake，每次最多 28³ 工作源格，不分配全世界的密集源数组。分块控制峰值内存；世界尺寸、质量参数与发光源数量仍影响总烘焙量和磁盘大小。
- 每页核心格唯一归属，重叠邻接格使用一致的全局格坐标和随机序列。烘焙失败或取消保留原 manifest。方向光、天空和已绑定自发光继续实时重照明，运行时不查 BVH。

迁移资源的源探针调试按需读取原源档案；新多分辨率 Bake 的源调试显示驻留 prepared cells，并明确区分来源。`Display Probes By Clv` 继续读取 GPU 实际结果。开启调试会增加编辑器绘制和读回成本。

512 m 是覆盖/加载契约，不是任意场景严格小于 0.5 ms 的性能保证。完整计时必须包含重照明、相机滚动上传和原生 Lighting 中的采样；仅计 Magic GI 独立 pass 会漏掉采样成本。

分页算子池对新进入格子做增量上传，连续退出槽位合并清理；扩容留有限余量，避免每加入一页就重传旧格。当前新算子的提交是原子的，`Upload Budget Mib Per Frame` 在本路径仅作为统计阈值，`upload_budget_enforced=false`；未实现跨帧上传队列。大跨度传送的瞬时上传峰值仍需要单独测量。

## GI 模式

`FMagicGIVolume` 默认使用 `PRT MagicGI`，旧场景继续沿用原有 Bake 数据和流程。选择 `Surfel MagicGI` 后，Surfel 模式会从当前场景快照自动覆盖可见表面，并在运行时追踪光线更新表面间接光；不需要离线布点，也不需要执行 Bake 或 Refresh。Surfel 缓存在 World 内共享并受容量预算限制，新表面首次覆盖和历史收敛需要运行一段时间。Volume 的 `size`、启用状态和 GI 强度仍共用；Surfel 参数控制半径、数量上限、每帧更新量、射线数与距离、历史权重和调试视图。Inspector 会显示 Surfel 参数并隐藏 PRT 的 Bake、Refresh 与布点参数；切回 PRT 时，原有 `bake_data` 和 manifest 保留。

Surfel 模式默认使用半分辨率 NRD RELAX 降噪；它需要 `feng-raytracing` 的 NRD 扩展以及支持硬件光追的 D3D12 或 Vulkan 渲染路径。NRD 不可用时，Surfel 会明确回退到 World Cache gather，GI 仍保持工作；降噪历史按渲染目标和视图分别保存。无需启用 `RTGI Diffuse` pass。当前场景快照支持刚体、骨骼蒙皮和 blend-shape `MeshInstance3D` 表面，以及 `BaseMaterial3D`；`ShaderMaterial`、透明接收表面和自定义 area-light 纹理暂不支持。

Surfel 还会自动维护三级世界空间 SH4 低频 probe field，在表面缓存覆盖不足时补充间接光；最多 1,536 个记录，每个 176 字节，不需要离线 Bake。探针更新从既有每帧射线预算中划分，探针照明射线最多 256 条/帧；该低频补充仍受硬件光追与当前场景快照支持范围约束。

表面分布默认启用两级 footprint LOD：细级使用设置半径 `r`，粗级使用 `2r`；LOD 将 8 个屏幕像素对应的世界空间 footprint 与 `r` 比较（16×16 屏幕 tile 的半宽），并用迟滞避免相机轻微移动时反复切换。每个轮到的 16×16 tile 检查四个分布在 8×8 象限的代表点；位置按 tile-sweep 游标轮换，使每个象限的 64 个像素位置都能在 64 次完整 tile sweep 内被检查。它优先补入目标 LOD 中尚无兼容缓存记录的位置，每个 tile 最多提交一个候选，且不按亮度单独加密。相机接近时缺少的细级覆盖会补入，远离时维护阶段将锚点迁移或回收；相机 LOD 改变分批维护，场景表面变换后会先重定位当前缓存记录，再让该帧 gather 使用它们。跨级查找会去掉相同表面三角形上位置重合的候选，并保留既有表面兼容与真实 LOS 检查。

Ray Guiding 使用每个表面记录的 4×4 余弦半球分布，继续保留至少 25% 的余弦采样概率。每批射线读取冻结的上一分布，并使用混合 PDF 做光照估计及发光命中 MIS；新样本只更新下一分布，避免同一批中采样和 PDF 不一致。该分布只改变采样效率，不裁掉或额外缩放辐射值。

设计参考：EA 的 [GIBS 技术介绍](https://www.ea.com/news/gibs-lighting-ea-sports-college-football-25) 与 [SIGGRAPH 2024 演讲幻灯片](https://advances.realtimerendering.com/s2024/content/EA-GIBS2/Apers_Advances-s2024_Shipping-Dynamic-GI.pdf)。

Surfel 的 `Debug View` 可通过 Feng Render Pipeline 的 `Debug Buffers` → `Magic GI` 查看贡献；调试内容只写入 sidecar，不改变正常 `SceneColor`。

### 旧单块 PRT MagicGI 烘焙数据（layout 5）

新 Bake 保存 `FMagicGIVolumeSourceChunk`，manifest 的 `transport_domain=regular_free_space_clv_v1`，最细间距固定 0.25 m。每个有效自由空间样本保存 SH9→SH9 RGB 次级传输、SH9→SH9 首段天空传输和每个稳定发光源的方向传输。SH degree 为 0–2，共 9 个实正交系数。其后 `feng_magic_gi_clv_transfer_builder.gd` 离线生成四级规则格的几何约束线性算子：遮挡射线与接触面约束仅在这一步执行，整个过程不代入某一时刻的太阳/天空/发光强度。`clv_prepared_operators` 因而仍是 TransferMatrix，不是烘焙好的间接光 SH。

页面保留有效源 Probe 的原始传输以便诊断；当前运行时只上传 prepared operators。准备完成后采用 v2 紧凑源存储，省略无效格子的全零 Transfer、天空、发光与距离矩载荷，并保存逻辑格到载荷的索引。原始有效点、迁移位置、全部有效系数和 prepared 算子保持不变；这项优化减少 CPU 常驻数据与校验工作，不降低烘焙射线数，也不改变运行时 GI。若索引开销抵消节省，则保留原存储。旧 v1 自由空间源继续读取；v2 仅走 prepared 路径，不能当作稠密数组交给旧动态缓存或重新拟合器。

白盒的保守减密评估保留近墙和 relocation 点，仅测试 169 个内部候选，用周围八点预测并比较完整次级传输、天空和各发光源矩阵的逐行 L1 算子误差。没有候选通过 1% 门槛，因此没有删除有效 Probe。该测试不能证明所有点在任何算法下都必要，也不能把矩阵误差百分比当作最终图像误差；本轮采取无损存储优化。

旧表面页 `FMagicGIData.directional`、旧未准备的自由空间页及 backend 0 仍按各自契约读取，不自动改写。完整 Bake、取消、场景变化和保存失败均保留上一代有效资源，成功时写入新的不可变 generation。

### 源 Probe 与运行时容量

**Magic GI pass → Prepared CLV Resolution** 控制 layout 5 每一级的边长，可选 16、24、32，默认 16。四级总容量分别为 16,384、55,296、131,072 个槽。最细间距仍为 0.25 m，四级依次为 0.25 / 0.5 / 1 / 2 m；增大边长扩大覆盖范围，不增加源 Probe、不改变烘焙，也不让原始低频 SH 恢复更多角向细节。

窗口随摄像机位置滚动，纯旋转不改变驻留布局。这是摄像机附近的空间缓存，不按视锥裁掉背面的探针，也不是整个烘焙场景的 Probe 数上限。无效槽不执行矩阵重照明；Inspector 分别报告有效驻留点和总槽容量。更大窗口增加缓存显存与重照明工作量，不承诺仍满足同一 GPU 时间预算。

当前自由空间 source 域仍为单页，受每轴 256 格、总 262,144 槽及 256 MiB 源载荷校验上限约束；烘焙会先生成稠密数据，因此打包不会绕过烘焙峰值限制。多页大世界流送是另一项实现工作，不能由扩大 resident CLV 容量替代。

## PRT 使用与烘焙

1. 启用 `Feng Render Pipeline` 和 `Feng Magic GI`，将两个插件链接到 `res://addons/`
2. 添加 `FMagicGIVolume`，设置 `size` 覆盖接收区域，选择 `PRT MagicGI`、`Use CLV` 和 backend 1。当前自由空间布局固定 0.25 m，隐藏不适用的旧表面偏移/自适应设置。
3. 选择 Bake quality 或自定义 `Bake Samples`、`Bake Bounces` 和 `Bake Distance`，点击 **Bake Free-space CLV PRT**。此按钮完成传输积分、CLV 预插值、压缩资源保存和重载验证，随后保存场景。关闭旧 `chunked_baking` 不会绕过该流程。当前该域保存一个受容量约束的 source page；超限会报错，不会静默降低密度。
4. Feng Renderer 中启用 **Magic GI**。layout 5 在 Lighting 前准备缓存并在原生 Lighting 中采样；独立 pass 负责发布与可选调试。启用 **Debug Buffers → Magic GI** 可查看当前实际 GI 贡献。

每个 World3D 选择最新有效且启用的 Volume，不混合多个 Volume。快照按世界和视口渲染目标路由。修改布局、静态几何、反照率或烘焙参数后需要重烘；太阳/TOD 与已烘焙发光源的开关、颜色和强度走实时 relight。**Refresh Surface Points** 仅用于旧表面域。

### Legacy 表面域：分块 Bake 与流送

本节描述旧表面页，不适用于上面的自由空间 layout 5 Bake 按钮。

新 `FMagicGIVolume` 默认启用分块 Bake。世界 XZ 平面按原点对齐的 512 m 管理块划分，负坐标使用向下取整；每块内部默认按 32 m 稀疏小页烘焙，并沿 Y 继续分层。超过单页网格、工作量、纹理或驻留预算时会继续细分，空页不保存数据。512 m 是管理边界，不是单个稠密网格，也不限制整个场景的总探针数。

Inspector 的 **Bake Streamed PRT** 重烘当前 Volume，**Bake Selected Block** 按 X/Z 管理块坐标局部重烘，并包含受该块影响的邻页；烘焙期间可点 **Cancel Bake**。取消、场景变化或失败不会替换仍可用的上一份烘焙。manifest 与页数据压缩为二进制 `.res`，默认写入 `res://bake/magicgi/<scene_and_volume_id>/`；旧 generation 不会自动删除。每个新页独立加载，manifest 只保存轻量索引。

流送默认最多并行准备 2 页，CPU 驻留预算为 256 MiB、GPU 驻留预算为 128 MiB、纹理上传预算为 16 MiB/帧；可在 Volume 的 Page Streaming 设置中调整。超出预算时系统保留较近的页，其他页等待预算释放后再加载。已有 `bake_data` 的 v2–v6 资源继续按旧路径读取，不会自动转换；显式执行分块 Bake 后才使用新 manifest。

## 自适应布点与体积缓存

### 默认运行时：MagicDawn CLV Block PRT（backend 1）

新 `FMagicGIVolume` 默认选择 `clv_cache_backend=1`。新的自由空间 generation 在加载线程校验哈希、签名、系数与 HDR 界限后，直接上传已准备的线性算子；不在加载时重建 BVH 或重新做几何插值。旧 baked-SH-only 资源不能启动实时 PRT，需重新 Bake。

实现参考 Tencent/MagicDawn [GDC 2026 公开演讲](https://media.gdcvault.com/gdc2026/Slides/Sheng_Feng_IlluminatingRocosLegacyScalableGlobalIlluminationfromTheorytoPractice.pdf)中的“预插值传输 → CLV block relight → 硬件插值”流程，维护 **4×16³** 驻留 cells。layout 5 的驻留窗口只依赖相机位置：沿相机到 source 域中心的空间方向拟合细级覆盖，避免域外相机把细级窗口留在空白区域。原地旋转不会改变 anchor、级联布局或触发重照明；平移仍按 0.25 m 源格及各级步长滚动。窗口不追随视线扫动，因此同一表面不会仅因转头而混入另一套级联数据。空间滚动只更新 cell 到 prepared operator 的映射。光照或映射改变时，一次 GPU dispatch 重算全部驻留 cells，固定输入不重复派发。当前布局使用 SH9，资源和压缩表示不声称与腾讯的 SH2 或私有实现一致。

每个 LOD 用七次三线性采样读取全部 SH9 RGB 对应的漫反射二次型；LOD 交界会混合邻级。矩阵乘法保持 FP32，输出为带统一二次幂 HDR 缩放的 RGBA16F，插值后恢复量纲。数据缺少可信算子界限时使用 RGBA32F。没有逐像素邻居循环、距离矩筛选、BVH 或额外全屏 Apply。几何约束在烘焙端处理墙面、重叠 box 交界与球体接触，保留真实遮挡；有效黑值仍替换未遮挡天空漫反射。

`get_magicdawn_runtime_state()` 中 `layout_version=5`、`prt_model=CLV_TRANSFER_MATRIX_RELIGHT`；`dynamic_volume.cache` 给出 `field_format`、`decode_scale`、`relight_revision`、`clipmap_update_count` 和 GPU 字节数。`dynamic_volume` 的 `lease_current`、`publication_token==consumed_token` 与 `renderer_active` 确认当前原生照明消费。`Debug Buffers → Magic GI` 按需生成 sidecar，不改变正常 SceneColor；调试视图有单独成本，不计入关闭调试时的生产预算。

**性能记录（2026-10-23，白光盒子，RTX 3080 Ti / D3D12 / 1920×1080）**：每阶段预热 120 帧、采样 160 帧，真实关闭原生 GI 为基线，包含 DeferredLighting 增量、NativePrepare 和 MagicGIPass；嵌套 relight 不重复相加。静止总增量中位约 0.227 ms；每帧太阳/发光变化约 0.266 ms，P95 0.281 ms；同时移动相机约 0.275 ms，配对 P95 0.304 ms（按 OFF 中位基线算为 0.342 ms）。后两阶段各 160 次不同 relight revision，均消费当前缓存。单独 relight 约 0.037 ms，不能用它替代总开销。GPU 缓存约 14.22 MiB。正常入口从场景挂入到当前 GI 首次消费测得 684 ms；这是已有导入和驱动缓存的启动，不代表首次 shader 编译耗时。

原始未过滤差分仍有 0.606 / 0.674 ms 尖峰，关闭 GI 的 DeferredLighting 也有尖峰。因此 P95 已低于 0.5 ms，但不宣称所有帧或所有设备都严格达标。工程 `Temp/dynamic_clv_preinterpolated_r16_20261023/` 保留原始 timestamps、配对算法、数值 readback 和正常入口报告。

### Legacy backend 0：per-probe/pixel PRT

backend 0 保留旧的逐 probe / pixel PRT 查询与照明重建行为，供需维持旧场景结果时显式选择。新建 Volume 默认使用 backend 1 的 CLV Block PRT。SH9 是低频漫反射近似，不是精确太阳盘或动态路径追踪。对照时请分别确认 Inspector 的序列化选择、有效 TransferMatrix 和 FRP runtime state；不要把 backend 0 的数据成本或历史 profile 当作 backend 1 的当前性能证据。

- `Adaptive Placement` 对新 Volume 默认关闭，显式保存的 `true` 仍会开启它。它与默认开启的 `Use CLV` 相互独立。`Probe Spacing` 决定均匀布局的基础间距；`Minimum Probe Spacing` 默认 0.25 m、支持 0.1–1 m，只在自适应细化开启时参与局部密度选择。系统先收集基础世界格与表面候选，再用几何特征和规范三角形标记拐角、曲面变化、小三角及窄构件所在区域；命中单元及其一格邻域才生成细间距候选，平滑区域保留基础间距。粗、细候选一起经过体积内外、表面侧、净空和安全偏移检查，再按确定性世界格与跨密度最小分离规则统一裁决；细探针按真实局部间距显示。
- 自适应布局使用稀疏单元范围和连续探针索引，每格不再截断为 8 个。细密探针的空间影响范围按局部间距收缩，避免查询成本和光照模糊随密度扩大。旧单资源路径受 Placement 安全上限约束：最终最多 65,536 点。分块 Bake 没有全场景总探针数上限；当前每页最多 32,768 个探针，以适配不超过 16 MiB 的 moments 纹理，并会按网格、工作量及驻留预算继续拆页。探针越多，CPU 烘焙工作量与资源大小越高；Adaptive 只在标记区域增加探针，不会降低每探针射线数或反弹数。参考：受控旧 F6 Cornell 场景以 1 m 基础间距、0.25 m 最小间距生成 4,087 个探针；r5、每探针 1,024 射线、2 次反弹、3 个发光源的烘焙用时 163,096 ms，资源为 11,169,794 字节。该时间是本次测量值，不是性能保证。
- `Use CLV` 默认开启，Adaptive Placement 独立控制是否局部加密 source probes。新 Volume 的 `CLV Cell Size` 默认 0.25 m，独立于 PRT `Probe Spacing`。MagicDawn backend 1 为当前视口维护规则级联体积；相机移动时更新新进入的覆盖 block，缓存用 3D 硬件插值供像素阶段读取。`CLV Cells Per Frame` 限制空间填充工作，默认 256、上限 512；它不把灯光变化分摊到多帧。
- 光照 revision 变化时，resident-relight 应在下一个 resident-relight dispatch 提交当前全部驻留 CLV faces；新空间 blocks 使用独立队列。用 `relight_serial`、`relight_lighting_revision`、`last_relight_faces` 和 `relight_pending` 判断 dispatch 状态；`relight_scheduled_and_dispatched` 只在成功提交 dispatch 的调用中为 true。`dirty_blocks` / `pending_blocks` 只观察空间填充，不能替代 relight 状态。GPU draw/readback 延迟另记，不将其计作分摊式 relight。
- 要直接看最终应用的 GI：启用 **Debug Buffers**，选择 **Magic GI**。这一路输出 Magic GI pass 实际写出的 contribution，已应用接收材质、AO、GI strength 与 pre-exposure。`CLV Debug View` 仅在当前 backend 对应的视图受支持时可用；Inspector 会说明不可用的值是否被忽略，并区分 GI 应用输出与缓存/采样诊断。默认 **ACES HDR** 只压缩 Debug Buffers 的显示范围，不改 `SceneColor` 或 GI 贡献；切到 **Unmapped (may clip)** 可看未压缩值。**GI Exposure** 只改变 debug 显示亮度，不改变实际 GI 能量。Volume 的 probe gizmo 是编辑器预览，不能代替运行时缓存输出。
- backend 0 保留旧的逐 probe / pixel 查询路径；该路径的缓冲与历史 profile 不代表 backend 1 的 CLV block 资源或运行成本。MagicDawn backend 1 的性能应以当前 pass GPU timestamps 计量，并包含 relight、CLV 更新及最终 apply。
- 受控旧 F6 Cornell 的布点 profile 中，旧全域细候选布局耗时 3,772 ms、生成 47,466 个 raw 候选并最终放置 3,982 个探针；分层布局耗时 1,620 ms、生成 9,683 个 raw 候选并最终放置 4,087 个。相同 r5 质量参数（1,024 rays、2 bounces、3 个发光源）的两次独立 bake 分别为旧布局 207,405 ms / 10,884,614 字节和新布局 163,096 ms / 11,169,794 字节；新布局探针数增加 2.6%。这些是受控 Cornell 跑次记录，不代表其他场景或硬件的普遍耗时比例。

方向 TransferMatrix 使用 SH degree 0–2 的 9 个实正交系数表示低频漫反射；增加空间密度不能恢复锐利镜面反射，也不能替代动态几何光追。

## 动态光照与自发光

backend 1 的 PRT TransferMatrix 在 Bake 时冻结，运行时输入的光照不是冻结的：方向光、`FengSkyLight` 当前 radiance/天空输入通过 SH 投影并推动 CLV blocks 的 GPU relight，适用于太阳方向与 TOD/Sky 更新。几何、布局或 transfer 本身变化仍要求重烘；新旧 bake 是否有可用方向矩阵由 Inspector 明确报告。backend 0 保持旧的逐 probe / pixel 查询行为。

每次运行时 lighting snapshot 读取同世界可见方向光的当前方向、颜色与强度，并读取 FengSkyLight 发布的当前天空 SH；Volume 的 Sun 可覆盖自动选择。物理模式使用 lux 和相关色温，非物理模式使用引擎归一化能量。layout 5 在输入或 CLV 映射改变时更新全部驻留 cells，dynamic_volume.cache.relight_revision 随成功 dispatch 前进；曝光和接收材质参数不代入传输求解。缓存坐标不变且输入固定时不重复 relight。旧表面域仍使用 relight_lighting_revision 和独立 slab 队列。

以下为旧表面域 v6 的兼容行为，layout 5 不执行这些像素查询：结构有效的 v6 Bake（含过期预览）在 Volume 覆盖的 opaque 像素按强度权重替换全局 SkyLight 漫反射；SkyLight 镜面反射、局部反射探针和 Volume 外像素保持不变。透明材质不在本 pass 的替换范围内。过期预览仍替换 SkyLight，不额外叠加未遮挡环境光；几何或材质输入改变后需重新烘焙。候选先通过法线、平面和网格窗口筛选，再对探针中心到真实接收面的直连线段做双面三角形遮挡查询。有墙相隔就拒绝该候选，即使两侧法线相同、墙无厚度、方向距离矩被远处开口平均成无遮挡也一样。v6 以精确几何查询决定可见性，不再叠加粗粒度距离矩造成的墙角误遮挡；旧格式预览仍使用 Chebyshev 距离矩。被遮挡候选不参与归一化。如果像素没有通过邻域/平面筛选的探针候选，pass 保持场景颜色不变；如果有候选但全部被遮挡，贡献为零，仍按 SkyLight 替换权重扣除漫反射 SkyLight。

仅旧表面缓存路径：烘焙与 CLV 填充使用静态几何进行直连遮挡和曲面延续检查，无需硬件光追。运行时像素使用缓存的表面归属、有限三角形深度修正和烘焙距离矩；已证明的同平面邻域直接插值。静态遮挡查询每次最多访问 256 个 BVH 节点，达到预算时保守拒绝。动态几何需重新烘焙；透明表面和 CPU 地形采样未包含的细节不构成静态遮挡。

PRT v3 及以上格式为不透明 `BaseMaterial3D` 发光表面保存独立传输，每个 Volume 最多 32 个发光材质表面。backend 0 保持旧的发光查询语义；backend 1 通过 bake 保存的方向/emission transport 重新组合当前支持的光照输入。发光表面的纹理、UV 映射、剔除模式或静态源几何发生改变时，该传输失效并需重新 Bake；对于可安全复用的运行时发光参数，以当前 Inspector/runtime warning 与完成 revision 为准，不把旧 `baked_indirect_sh` 状态当作本路径的依据。

已有静态反射探针若捕获了发光面，改变该表面后仍需重新 Capture 并保存探针。新增或启用尚未烘焙的发光面需要 Bake。Magic GI 是漫反射传输，材质 roughness 和 specular 设置不参与烘焙输入。

- 发光纹理、UV 映射或剔除模式改变时，仅该源暂时停止贡献并提示重烘；方向光和天空传输继续可用
- 发光源移动或静态几何改变会使整体几何传输过期

backend 1 的动态 CLV relight 使用当前支持的远场方向光、`FengSkyLight` 辐射与 bake 中存在的发光传输；不包括点光源、聚光灯、镜面传输、透明表面或 `ShaderMaterial` 自发光。backend 0 仍保留 legacy per-probe/pixel 行为。

## 几何、材质与容量

- `ArrayMesh` 从各三角形表面采样。单材质非 `ArrayMesh` 通过 `PrimitiveMesh.get_mesh_arrays()` 或 `Mesh.get_faces()` 采样；无法还原各面材质的多材质非 `ArrayMesh` 拒绝烘焙
- Terrain3D 通过支持洞孔的 `get_surface_height()` 采样。CPU 不执行地形分层 shader，使用 `Terrain Reflectance` 作为漫反射反照率
- `BaseMaterial3D` 使用 albedo tint、metallic 和 UV0 albedo 贴图。CPU 采样保留 UV 缩放、偏移、重复和最近点/双线性过滤，并对 sRGB 贴图解码一次；HDR 浮点纹理保持线性。缺失 UV 或三平面贴图会拒绝烘焙。`ShaderMaterial` 使用 `Fallback Material Reflectance`。透明表面跳过
- 旧表面域上限为每轴 64 个运行时查找网格单元、每个世界间距格 1 个探针、非自适应布局每个运行时查找格最多 8 个样本、65,536 个探针/候选世界格、每格最多 8 个几何域且每域最多 2 个候选、32 个发光表面、250,000 个网格三角形，以及包含 PRT、发光遮挡和方向可见性射线在内的 100,000,000 CPU 路径工作预算。超过容量会报错。世界间距格使用实际中心和全局世界坐标；运行时查找格仍按 v6 表面锚点与 Volume 局部网格构建

## 编辑器预览

当前 free-space CLV PRT 的预览：在 **MagicGIVolume** 上开启 **Show Probes** 显示有效源探针（含 relocation 后的位置），开启 **Show SH Probes** 显示当前重光照的 SH9 漫反射方向响应球。二者可以独立开启；SH 球均匀抽样最多 256 个，数量和状态在 Inspector 中显示。它们使用当前方向光、SkyLight 和自发光输入，SH 系数保留正负号，在球面重构时才做非负截断。

勾选 **Display Probes By Clv** 后改为显示所选编辑器视口实际驻留的 CLV cells，并从 GPU 当前重光照纹理异步读取 SH。**Probe Clv Level** 可选 L0–L3；All Levels 显示级联外壳，隐藏完整位于细级范围内的重叠粗级 cell，单独选择一级则显示其完整有效网格。范围框以青、绿、橙、粉色区分四级；**Probe Clv View** 对应编辑器分屏的第 1–4 个视口。视口没有正在渲染的有效缓存时显示等待状态，不伪造网格。

预览按需刷新，变化时最多约每 500 ms 更新一次。源探针求值和 CLV 读回解码在工作线程执行，稳定输入复用快照；两个显示开关关闭或 Volume 退出场景后撤销请求并丢弃迟到结果。调试网格不投射阴影、不参与 GI，也不保存到场景；显示打开时的球体绘制和读回属于额外编辑器调试开销，不计为正常 GI 的性能保证。

旧表面域的预览：**Show Probes** 默认开启，球心取实际探针中心，半径按基础显示网格缩放并乘以该探针真实局部间距比例；显示不会移动探针或为遮住重叠而缩小标记。标记显示当前完整 GI 响应（次级传输、首段天空和当前有效的发光贡献，再乘 `gi_strength`）；蓝色仅表示零响应。结构有效的过期 Bake 仅在保存的探针中心与当前布局逐项匹配时参与预览，否则标记为灰色。**Show SH Probes** 默认关闭，开启后最多显示 256 个归一化径向图，表示次级传输与首段天空可见性除以 π 的单位白光角向响应；这个视图展示单位远场光的传输响应；当前自发光贡献显示在 Probes 标记中。

## 模块与数据契约

- 当前自由空间域：`FMagicGIVolumeSourceBaker` 积分并保存原始传输，`feng_magic_gi_clv_transfer_builder.gd` 离线拟合带几何约束的线性算子，`FMagicGIVolumeSourceChunk` 验证持久化数据；`magic_gi_preinterpolated_volume_cache.gd` 管理四级驻留映射和 GPU relight，原生 Lighting 与可选 Debug 共用采样实现。
- `FMagicGIVolume` 管理设置、布局匹配、异步烘焙和预览
- `FMagicGIPlacement` 管理几何、布点和 BVH；`FMagicGIEmitterBakeSet` 通过 Placement 的 `emitters` 独占发光绑定、签名和面积采样，Baker 直接读取同一对象；`FMagicGIEmitterBinding` 管理稳定键和签名；`FMagicGISceneTracker` 跟踪场景/资源变化
- `FMagicGIBaker` 管理烘焙提交，`feng_magic_gi_directional_baker.gd` 积分路径，`feng_magic_gi_directional_data.gd` 定义方向数据，`feng_magic_gi_adaptive_layout.gd` 选择局部密度；`feng_magic_gi_visibility.gd` 构建和验证静态遮挡 BVH；`FMagicGIData` 验证持久化资源、组合发光响应并打包上传数据
- `FMagicGIRuntime` 选择 Volume 并发布世界/视口快照；每个 `RuntimeState` 只持有注册信息和独立的光照/发光对象；`FMagicGIEmission` 独占源参数、响应缓存和警告，诊断刷新不改写已发布响应。warning getter 只读
- `FengMagicGIPass` 通过可选 Runtime 路径消费快照，管理 RD 纹理、UBO 和释放。Inspector/Viz 负责编辑器操作与预览

`FMagicGIData` 保存 v6 世界空间表面锚点、实际探针中心/法线、布局、场景签名及查找索引。每个样本远场次级传输为 27 个 float，按系数优先、RGB 连续排列：`Y0`、`Y1-1(y)`、`Y10(z)`、`Y11(x)`、`Y2-2(xy)`、`Y2-1(yz)`、`Y20(3z²-1)`、`Y21(xz)`、`Y22(x²-y²)`。远场图集每样本 7 个 RGBA32F texel；primary SkyLight 可见性另存 9 个可能带正负号的标量系数，每样本用 3 个 RGBA32F texel 打包。几何图集每样本 3 个 texel；8×8×2 个距离矩通道共占 512 字节/探针；固定密度布局每网格单元含 8 个有符号 32 位样本索引，自适应布局改为单元范围和连续索引。可选方向数据独立版本化：每探针 243 个次级传输 float、81 个天空传输 float，以及每发光源 54 个传输 float。旧格式预览的每个候选双线性采样四个 moment texel。BVH 另用两个只读缓冲：每节点 32 字节、每三角形 48 字节，叶节点最多 4 个三角形，使用 8 桶、3 轴表面积代价划分，深度优先排列并带跳过子树索引，CLV 更新中的几何遍历不需要栈。三角形 w 通道存预计算面积、行列式阈值和平滑表面片 ID；探针锚点的表面片只在创建上传数据时定位，并写入几何图集的空闲 alpha。射线逆方向每次查询只计算一次。

以下为旧表面页运行时：运行时读取 `data.directional` 的 SH9→SH9 TransferMatrix 与天空传输，在 GPU 上由一次 resident-relight dispatch 重算所有驻留 cells 的方向光/天空响应；相机进入新空间后，几何 slab fill 使用独立的有界队列。像素阶段从当前有效的 3D 缓存做硬件插值，再完成几何可见性筛选和材质响应。只有光照/天空输入 revision 改变时才触发 resident relight；固定输入下不应重复重照明。`last_relight_gpu_ms` 只计重照明阶段，不能替代包含 CLV 更新、sampling 和 apply 的总 GI GPU 时间。

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
/path/to/godot --headless --path /path/to/project --script res://addons/feng-magic-gi/tests/test_volume_free_space_bake_integration.gd
/path/to/godot --headless --path /path/to/project --script res://addons/feng-render-pipeline/tests/test_preinterpolated_clv_camera_anchor.gd
/path/to/godot --headless --path /path/to/project --script res://addons/feng-magic-gi/tests/test_source_preview.gd
/path/to/godot --headless --path /path/to/project --script res://addons/feng-magic-gi/tests/test_source_archive.gd
/path/to/godot --headless --path /path/to/project --script res://addons/feng-render-pipeline/tests/test_clv_editor_snapshot.gd
```

`test_preinterpolated_clv_camera_anchor.gd` 不创建 GPU 设备，覆盖白盒正视域外相机、域内/侧面/中心相机的原地旋转、平移滚动与非法输入，并验证 0.25 m、四级 16³ 布局保持不变。它同时保留原朝向驱动算法的反例，防止再次把视线变化用于驻留映射。

`test_source_preview.gd` 检查源 Transfer、天空、自发光的精确重光照与无效探针过滤；`test_clv_editor_snapshot.gd` 检查真实纹理布局解码、半精度、四级位置以及异步请求生命周期。可视化网格及 SH 球实际像素测试需真实 GPU：`--path /path/to/project --rendering-method mobile --rendering-driver d3d12 --script res://addons/feng-magic-gi/tests/test_volume_probe_viz.gd`，不可用 headless dummy 的结果替代。

Prepared CLV 的天空接管回归需要 Vulkan，直接编译并运行生产 `sh9_tensor` 和 `dynamic_volume_sample` include：

```sh
/path/to/godot --path /path/to/project --rendering-method mobile --rendering-driver vulkan --script res://addons/feng-render-pipeline/tests/test_preinterpolated_clv_sky_ownership.gd
```

该测试检查完整与 0.75 有效插值权重在强度 1 / 0.5 下得到相同的归一化 PRT 结果；有效黑色、空/不足支持、图集/Volume 外和显式叠加模式也有数值断言。命令末尾添加 `-- --legacy-coverage-control` 可运行旧天空接管公式的负控，预期仅两个部分支持用例失败。有效插值权重是缓存支持率，不能作为混回无遮挡天空的比例。

完整 PRT 与 GPU 集成：

```sh
python misc/scripts/test_magic_gi.py --binary /path/to/godot --driver vulkan
python misc/scripts/tests/run_frp_exposure_balance.py --binary /path/to/godot
```

`test_magic_gi.py` 覆盖布点、方向积分、GPU/CPU 重照明一致性、缓存滚动与版本失效、贴图颜色空间、烘焙保存重载、发光源变化、相机变换和视口路由；Linux 无显示器时可加 `--xvfb`。曝光测试使用程序天空、Height Fog 和合成 PRT，在 60,000 lux 物理模式下检查 GI/Fog 可见贡献，以及 pre-exposure 开关的 LDR 差 ≤ 0.01、曝光 scale 差 ≤ 2%。日志、隔离项目和可选 PNG 保留在 `bin/` 下。
