# Feng Magic GI

FMagicGI 为 Feng Render Pipeline 提供表面 PRT（预计算辐射传输）数据。烘焙只保存几何传输，与当前光照分离：每个接收表面点保存 9 个 RGB 球谐系数。运行时将传输系数与当前世界空间光照系数点积，再由渲染 pass 乘以接收材质的反照率、非金属比例、AO 和 GI 强度。因此改变太阳或环境光不用重烘焙几何。

烘焙从真实接收表面按余弦分布发射 CPU 路径；路径至少经过一次漫反射几何反弹，并在之后逃逸到光源方向时才计入传输。方向由每探针独立随机移位的低差异序列产生，再经余弦半球映射；首段直接逃逸不写进烘焙，以免与引擎 direct-light pass 重复；也不额外做余弦卷积或乘 π。

## 模块边界

- `FMagicGIVolume` 保存作者设置、判断烘焙是否匹配当前布局，并协调布点、异步烘焙和编辑器预览。
- `FMagicGIPlacement` 负责几何、表面点与 BVH；`FMagicGIEmitterBakeSet` 负责发光面、纹理与 CDF 采样；`FMagicGIEmitterBinding` 共享稳定键、签名和源解析；`FMagicGISceneTracker` 跟踪场景边界与资源变化。`FMagicGIBaker` 积分路径，`FMagicGIData` 持有持久化格式、验证和运行时上传打包。
- `FMagicGIRuntime` 负责每个 World3D 的有效 Volume 选择、视口目标路由与快照发布。`RuntimeState` 持有单个 Volume 的动态光照、发光响应缓存和诊断状态；warning 查询只读取缓存，显式诊断刷新负责更新它。
- `FengMagicGIPass` 通过可选 Runtime 脚本路径读取只读约定的快照，并独自管理 RD 纹理、UBO 与释放；FRP 不依赖 Magic GI 的类。Inspector 与 Viz 只处理编辑器操作和预览。

## 使用与烘焙

1. 启用 `Feng Render Pipeline` 与 `Feng Magic GI`，确保两个插件都链接到 `res://addons/`。
2. 在场景中添加 `FMagicGIVolume`。新建 Volume 的默认布点间距为 1 米；按需要调整 `size`、`Probe Spacing` 和表面偏移。场景里已保存的间距值会保留；未显式保存该属性的 Volume 会采用新默认。改变间距后需要重新 Bake。探针只布置在 Volume 内的可见受支持表面，不需要物理碰撞体；没有几何时不会在空气中生成探针。
3. 在 Inspector 的 **Bake quality** 中选择 **Draft 256**、**Final 1024** 或 **High 2048** rays/point，再点击 **Bake PRT Transfer**。新建 Volume 的数值默认仍为 256；现有场景不会静默改用更多样本。也可用 `Bake Samples` 设置自定义数量。质量或其他烘焙参数变化后，Inspector 会显示旧数据的实际样本数、当前请求数及需重烘状态。烘焙在 CPU 上分批追踪路径，表面较密或采样较多时会花一些时间；`Bake Bounces` 和 `Bake Distance` 控制路径深度及传输距离。烘焙成功后编辑器会将场景标记为未保存。可用 **Refresh Surface Points** 立即刷新编辑器预览。
4. 新建的 Feng Renderer 默认在 Lighting 后加入并启用 **Magic GI** pass。没有有效烘焙，或当前视口没有同一 World3D 的 Volume 时，pass 不改变场景颜色。独立的 **Debug Buffers** pass 默认关闭；启用后可检查反照率、view-space 法线、AO、roughness、metallic、运动向量或 Magic GI 贡献。

每个 World3D 只选择最新的有效启用 Volume，不混合多个 Volume。Pass 只使用注册到当前 World3D 和视口渲染目标的 Volume，避免编辑器或游戏 SubViewport 串用另一个世界的烘焙。

## 动态光照

FMagicGI 每帧将匹配世界中的可见 `DirectionalLight3D` 与选定环境投影到世界空间 SH。可在 Volume 的 `Sun` 或 `Lighting Environment` 属性中指定来源；留空时使用同一 World3D 的环境或 fallback environment。太阳颜色、方向、能量和间接能量变化会实时更新光照系数，不改烘焙传输。非物理光照单位按 Godot 引擎的缩放处理；物理光照模式读取光源 lux 强度。环境全景使用 `RenderingServer.environment_bake_panorama` 的背景/ambient 混合语义；环境属性或方向光变化时，天空 SH 最多每秒刷新四次。

当前只将远距离方向光和环境全景纳入动态 SH；点光源和聚光灯不投影到此 PRT 光照场。未修改材质属性的时间驱动天空 shader 动画不会被自动识别。共享世界光照系数没有套用相机专属曝光，因此物理光照模式下的 Magic GI 不匹配各相机曝光归一化。

## 材质自发光

PRT v3 会为不透明 `BaseMaterial3D` 自发光表面烘焙独立的间接传输；每个 Volume 最多支持 32 个发光材质表面，发光路径受 CPU 烘焙工作预算限制。场景启用发光源后需先重新烘焙，CPU 烘焙会为它们保存传输；之后发光颜色、强度以及 `emission_enabled` 开关在运行时读取，无需重烘，`Add` 与 `Multiply` 运算符也可实时切换。启用物理光照单位时，发光强度还会乘以材质的 `emission_intensity`。自发光纹理内容、纹理资源、UV 映射或表面剔除模式发生变化时，仅该源的烘焙传输会被标为过期并暂不贡献，其他方向光/天空烘焙仍可使用；重新烘焙后恢复该源。移动发光源或场景几何变化会使整体静态传输过期，需重新烘焙。发光间接光只支持漫反射传输；镜面反射、动态点光源/聚光灯、`ShaderMaterial` 发光和透明表面不受支持。

旧 PRT v2 资源继续提供已有的方向光与天空间接光，但没有发光面传输。场景中存在发光材质时，Volume 会提示重新烘焙以加入自发光贡献；加载旧数据不会把整份 GI 关闭。

## 表面与材质支持

- `ArrayMesh` 的三角形表面从真实网格采样。单材质表面的非 `ArrayMesh`（例如 `BoxMesh`）从 `PrimitiveMesh.get_mesh_arrays()` 或 `Mesh.get_faces()` 采样；由于这些路径无法还原每面的材质，多材质面的非 `ArrayMesh` 会拒绝烘焙。
- Terrain3D 从支持洞孔的 `get_surface_height()` 高度数据采样，不依赖碰撞形状。烘焙器不会运行 Terrain3D 分层 shader，请用 `Terrain Reflectance` 指定 CPU 烘焙使用的漫反射反照率。
- `BaseMaterial3D` 使用 albedo tint 与 metallic 参数；不会读取 albedo 贴图像素，存在贴图时仍使用材质 tint。`ShaderMaterial` 使用 `Fallback Material Reflectance`。透明表面会跳过。
- 烘焙表示漫反射间接传输，不包含镜面反射、动态点/聚光灯或任意 shader 反照率。只有可见支持的几何会参与。

网格与查找容量有明确上限：每轴最多 64 个网格单元、每个查找格最多 8 个表面样本、最多 65,536 个样本、最多 32 个发光表面、250,000 个网格三角形，CPU 路径工作量也有上限。超过限制或不能表示场景时烘焙会报错，不会静默丢弃几何。旧版只保存辐射的资源不符合 v2，必须重新烘焙。

## 编辑器可视化

`Show Probes`（默认开启）会显示采样到的表面点；未烘焙时为灰色，烘焙后按单位方向光从世界 +Y 入射时的几何传输响应着色。`Show SH Probes` 默认关闭；开启后以径向网格可视化几何传输响应，而不是烘焙的或当前的光照辐射，最多显示 256 个样本。预览会跟随 Volume 变换，并在场景几何或布点设置变化后更新。

## Eye Adaptation GPU 回归

`misc/scripts/tests/frp_exposure_balance.gd` 用真实 FRP 渲染一组带程序天空、Height Fog 和合成 PRT 传输的接收面，分别切换 Magic GI、Height Fog 与 Eye Adaptation 的 pre-exposure。可用 `python misc/scripts/tests/run_frp_exposure_balance.py --binary <Godot editor binary>` 在 GPU 上运行；默认选择 Vulkan，也可用 `--driver d3d12` 指定 D3D12。测试会在 `bin/` 下保留隔离项目、日志和可选 PNG。物理光照模式以 `light_energy=1`、`light_intensity_lux=60000` 运行，并要求 Sky、Fog、GI 的 PE on/off LDR 差不超过 0.01、曝光 scale 差不超过 2%；GI 与 Fog 开关也必须对各自采样点产生可见变化。非物理 `light_energy=60000` 保留作诊断模式；该强度下固定曝光的 GI 接收点及自动曝光的 Fog/接收点会剪裁，因此不作为 PE 数值断言。

在 `test-1` 隔离副本里，原 `project.godot` 未启用物理光照单位，保存的 `DirectionalLight3D.light_energy` 是 6.0；场景没有 `WorldEnvironment`、`Environment` 或 `Sky`。以非物理 `light_energy=60000` 运行 Eye Adaptation 扩展范围（EV100 `-10..20`）时，PE on/off scale 为 `0.00014329/0.00014371`，地形采样的 LDR 差约一个 8-bit 码；GI 开关造成的地形采样差不超过 `0.004`。物理单位副本使用 `light_energy=1`、`light_intensity_lux=60000`，PE on/off scale 为 `0.00046034/0.00046197`，地形差不超过 `0.004`。原场景的黑色背景在 PE on/off 都保持黑色；Fog 关闭时同一背景是默认灰色，启用 Fog 后又变黑。

加入 Physical Sky 并关闭 Fog 后，隔离副本可见天空；原太阳方向的 `basis.z.y=-0.32295` 位于 Physical Sky 的地平线下方。为避免方向对照被 LDR 剪裁，本次副本测试把 sky energy multiplier 设为 `0.0001`，并固定手动曝光（f/16、1/60、ISO 100）；将 `basis.z.y` 改为正值后左上天空 RGB 从约 `(0.078, 0.110, 0.086)` 增至 `(0.137, 0.161, 0.149)`。Fog 打开后两种太阳方向的天空都回到接近黑色。该强度和手动曝光仅用于方向诊断，没有写入用户项目。已测证据没有显示 GI/Fog/Sky 的 pre-exposure 单位不一致，因此不应通过任意调低 GI 或重复乘 PE 来补偿天空亮度。原场景的雾密度为 0.5、散射颜色固定为约 0.816；在强光适应后，它会显著衰减天空并压低固定辐射度的雾散射贡献。

## PRT v3 数据

`FMagicGIData` 保存世界空间表面采样位置与法线、每个样本 27 个远场传输 float、发光源稳定键与各源每样本 6 个传输 float、Volume 布局元数据、持久化场景签名和查找索引。远场系数按“系数优先、RGB 分量连续”排列：`Y0`、`Y1-1(y)`、`Y10(z)`、`Y11(x)`、`Y2-2(xy)`、`Y2-1(yz)`、`Y20(3z²-1)`、`Y21(xz)`、`Y22(x²-y²)`。远场传输图集每个样本 7 个 RGBA32F texel，几何图集每个样本 2 个 RGBA32F texel；每个网格单元保存 8 个有符号 32 位样本索引。发光传输按 source、probe、两种 RGB 基底排列：常量颜色响应与静态发光纹理调制响应。

方向光和环境光仍独立保存在 27 个动态 SH 系数中；实时发光参数只重组已有的发光传输，不会改写烘焙资源。几何、发光纹理/UV 映射、Volume 布局或烘焙设置不再匹配时，相关传输会提示重新烘焙。format-2 旧数据仍可提供远场光照；只有早期仅保存辐射值、不能表示几何传输的资源需要重新烘焙。旧随机采样器生成的 format-2 资源仍会被标记为过期，必须使用当前低差异采样器 r2 重新烘焙。Inspector 显示本次实际使用的 rays/point，切换质量只更新 Volume 的请求值，不会改写旧烘焙的数据或样本数。本次模块整理不改变 v2/v3 持久化布局，也不改变采样器 r2 的数值序列。
