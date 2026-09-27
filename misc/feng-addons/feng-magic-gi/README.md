# Feng Magic GI

FMagicGI 为 Feng Render Pipeline 提供表面 PRT（预计算辐射传输）数据。烘焙只保存几何传输，与当前光照分离：每个接收表面点保存 9 个 RGB 球谐系数。运行时将传输系数与当前世界空间光照系数点积，再由渲染 pass 乘以接收材质的反照率、非金属比例、AO 和 GI 强度。因此改变太阳或环境光不用重烘焙几何。

烘焙从真实接收表面按余弦分布发射 CPU 路径；路径至少经过一次漫反射几何反弹，并在之后逃逸到光源方向时才计入传输。方向由每探针独立随机移位的低差异序列产生，再经余弦半球映射；首段直接逃逸不写进烘焙，以免与引擎 direct-light pass 重复；也不额外做余弦卷积或乘 π。

## 使用与烘焙

1. 启用 `Feng Render Pipeline` 与 `Feng Magic GI`，确保两个插件都链接到 `res://addons/`。
2. 在场景中添加 `FMagicGIVolume`。默认布点间距为 1 米；按需要调整 `size`、`Probe Spacing` 和表面偏移。探针只布置在 Volume 内的可见受支持表面，不需要物理碰撞体；没有几何时不会在空气中生成探针。
3. 在 Inspector 的 **Bake quality** 中选择 **Draft 256**、**Final 1024** 或 **High 2048** rays/point，再点击 **Bake PRT Transfer**。新建 Volume 的数值默认仍为 256；现有场景不会静默改用更多样本。也可用 `Bake Samples` 设置自定义数量。质量或其他烘焙参数变化后，Inspector 会显示旧数据的实际样本数、当前请求数及需重烘状态。烘焙在 CPU 上分批追踪路径，表面较密或采样较多时会花一些时间；`Bake Bounces` 和 `Bake Distance` 控制路径深度及传输距离。烘焙成功后编辑器会将场景标记为未保存。可用 **Refresh Surface Points** 立即刷新编辑器预览。
4. 新建的 Feng Renderer 默认在 Lighting 后加入并启用 **Magic GI** pass。没有有效烘焙，或当前视口没有同一 World3D 的 Volume 时，pass 不改变场景颜色。独立的 **Debug Buffers** pass 默认关闭；启用后可检查反照率、view-space 法线、AO、roughness、metallic、运动向量或 Magic GI 贡献。

每个 World3D 只选择最新的有效启用 Volume，不混合多个 Volume。Pass 只使用注册到当前 World3D 和视口渲染目标的 Volume，避免编辑器或游戏 SubViewport 串用另一个世界的烘焙。

## 动态光照

FMagicGI 每帧将匹配世界中的可见 `DirectionalLight3D` 与选定环境投影到世界空间 SH。可在 Volume 的 `Sun` 或 `Lighting Environment` 属性中指定来源；留空时使用同一 World3D 的环境或 fallback environment。太阳颜色、方向、能量和间接能量变化会实时更新光照系数，不改烘焙传输。非物理光照单位按 Godot 引擎的缩放处理；物理光照模式读取光源 lux 强度。环境全景使用 `RenderingServer.environment_bake_panorama` 的背景/ambient 混合语义；环境属性或方向光变化时，天空 SH 最多每秒刷新四次。

当前只将远距离方向光和环境全景纳入动态 SH；点光源和聚光灯不投影到此 PRT 光照场。未修改材质属性的时间驱动天空 shader 动画不会被自动识别。共享世界光照系数没有套用相机专属曝光，因此物理光照模式下的 Magic GI 不匹配各相机曝光归一化。

## 表面与材质支持

- `ArrayMesh` 的三角形表面从真实网格采样。单材质表面的非 `ArrayMesh`（例如 `BoxMesh`）通过 `Mesh.get_faces()` 采样；由于该 API 无法还原每面的材质，多材质面的非 `ArrayMesh` 会拒绝烘焙。
- Terrain3D 从支持洞孔的 `get_surface_height()` 高度数据采样，不依赖碰撞形状。烘焙器不会运行 Terrain3D 分层 shader，请用 `Terrain Reflectance` 指定 CPU 烘焙使用的漫反射反照率。
- `BaseMaterial3D` 使用 albedo tint 与 metallic 参数；不会读取 albedo 贴图像素，存在贴图时仍使用材质 tint。`ShaderMaterial` 使用 `Fallback Material Reflectance`。透明表面会跳过。
- 烘焙表示漫反射间接传输，不包含镜面反射、动态点/聚光灯或任意 shader 反照率。只有可见支持的几何会参与。

网格与查找容量有明确上限：每轴最多 64 个网格单元、每个查找格最多 8 个表面样本、最多 65,536 个样本、250,000 个网格三角形，CPU 路径工作量也有上限。超过限制或不能表示场景时烘焙会报错，不会静默丢弃几何。旧版只保存辐射的资源不符合 v2，必须重新烘焙。

## 编辑器可视化

`Show Probes`（默认开启）会显示采样到的表面点；未烘焙时为灰色，烘焙后按单位方向光从世界 +Y 入射时的几何传输响应着色。`Show SH Probes` 默认关闭；开启后以径向网格可视化几何传输响应，而不是烘焙的或当前的光照辐射，最多显示 256 个样本。预览会跟随 Volume 变换，并在场景几何或布点设置变化后更新。

## PRT v2 数据

`FMagicGIData` 保存世界空间表面采样位置与法线、每个样本 27 个传输 float、Volume 布局元数据、持久化的场景内容签名和查找索引。系数按“系数优先、RGB 分量连续”排列：`Y0`、`Y1-1(y)`、`Y10(z)`、`Y11(x)`、`Y2-2(xy)`、`Y2-1(yz)`、`Y20(3z²-1)`、`Y21(xz)`、`Y22(x²-y²)`。传输图集每个样本 7 个 RGBA32F texel，几何图集每个样本 2 个 RGBA32F texel；每个网格单元保存 8 个有符号 32 位样本索引。

烘焙资源只含几何传输。当前光照另外保存在 27 个 float 的 SH 系数中，所以动态换光不修改烘焙数据。布局、几何、材质输入或烘焙设置不再匹配时，数据会失效并需重新烘焙。数据仍是 format 2、每点 27 个 float；持久化场景签名同时包含采样器修订号。旧随机采样器生成的 format-2 资源仍可加载和检查，但会被标记为过期，必须使用当前低差异采样器 r2 重新烘焙。Inspector 显示本次实际使用的 rays/point，切换质量只更新 Volume 的请求值，不会改写旧烘焙的数据或样本数。
