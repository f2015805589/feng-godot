# Feng Magic GI

FMagicGI 为 Feng Render Pipeline 提供表面 PRT（预计算辐射传输）。烘焙保存几何传输；每个接收表面点的次级传输为 9 个 RGB 球谐系数，格式 4 起另存首段天空可见性的 9 个标量系数，格式 5 增加原始表面锚点、实际探针中心和方向距离矩。运行时再与世界空间光照相乘，由渲染 pass 应用接收材质反照率、非金属比例、AO、GI 强度和 SkyLight 替换权重。太阳、SkyLight 内容或能量变化无需重烘几何。

远场传输从接收表面沿余弦分布发射 CPU 路径。首段逃逸记录为 primary SkyLight 可见性；经过漫反射反弹后逃逸的路径仍保存在独立的 secondary transport 中，不会把当前天空辐射烘进几何数据。每个探针使用独立随机移位的低差异序列。方向可见性另用 8×8 八面体图集记录首击距离的一、二阶矩：每格至少实际追踪 4 条射线，质量样本数超过 256 时再加入球面低差异射线。自发光面另行保存源到接收面的间接响应。

## 使用与烘焙

1. 启用 `Feng Render Pipeline` 和 `Feng Magic GI`，将两个插件链接到 `res://addons/`
2. 添加 `FMagicGIVolume`，调整 `size`、`Probe Spacing` 和表面偏移。默认间距为 1 米；探针沿可证实的表面外侧自适应留出空间，并保留原始表面锚点。闭合体内部、共面/交叉冲突或无法安全离开薄壳的位置会丢弃或提示；无需碰撞体，无几何时不生成探针
3. 在 Inspector 的 **Bake quality** 选择 **Draft 256**、**Final 1024** 或 **High 2048** rays/point，或通过 `Bake Samples` 自定义。默认 256。点击 **Bake PRT Transfer**；`Bake Bounces` 和 `Bake Distance` 控制路径深度和距离。烘焙在 CPU 分批执行，完成后场景标记为未保存
4. 新建 Feng Renderer 默认在 Lighting 后启用 **Magic GI** pass。无有效烘焙或同世界 Volume 时，pass 保持场景颜色不变。启用 **Debug Buffers** 可检查材质、法线、AO、运动向量和 Magic GI 贡献

每个 World3D 选择最新有效且启用的 Volume，不混合多个 Volume。快照按世界和视口渲染目标路由。已有场景保留已保存的设置；修改布局、几何或烘焙参数后需要重烘，Inspector 显示实际/请求样本数及过期原因。**Refresh Surface Points** 可立即刷新预览。

## 动态光照与自发光

每帧将同世界可见方向光投影到 SH；Volume 的 `Sun` 可覆盖自动选择，切换或清空会使直接光缓存失效。物理模式使用 lux 和相关色温，非物理模式使用引擎归一化能量。天空照明由 ready 的 `FengSkyLight` 提供，缺省为零；其 SH 独立用于 primary visibility，与方向光合并后用于 secondary transport。太阳和发光源独立工作。`Lighting Environment` 保留为旧场景序列化字段。

有效且当前匹配的 v5 Bake 在 Volume 覆盖的 opaque 像素按强度权重替换全局 SkyLight 漫反射；SkyLight 镜面反射、局部反射探针和 Volume 外像素保持不变。透明材质不在本 pass 的替换范围内。v5 使用单边 Chebyshev 方差界估计从探针到接收点的遮挡，并以无遮挡基础权重归一化，完全遮挡的候选不会因小权重重归一而恢复亮度。

PRT v3 及以上格式为不透明 `BaseMaterial3D` 发光表面保存独立传输，每个 Volume 最多 32 个发光材质表面。启用发光源后先重新烘焙；随后可实时改变颜色、强度、`emission_enabled` 和 Add/Multiply 运算符。物理模式还会乘以 `emission_intensity`。

- 发光纹理、UV 映射或剔除模式改变时，仅该源暂时停止贡献并提示重烘；方向光和天空传输继续可用
- 发光源移动或静态几何改变会使整体几何传输过期

动态光照支持远场方向光、SkyLight 辐射和已烘焙发光面；不包括点光源、聚光灯、镜面传输、透明表面或 `ShaderMaterial` 自发光。

## 几何、材质与容量

- `ArrayMesh` 从各三角形表面采样。单材质非 `ArrayMesh` 通过 `PrimitiveMesh.get_mesh_arrays()` 或 `Mesh.get_faces()` 采样；无法还原各面材质的多材质非 `ArrayMesh` 拒绝烘焙
- Terrain3D 通过支持洞孔的 `get_surface_height()` 采样。CPU 不执行地形分层 shader，使用 `Terrain Reflectance` 作为漫反射反照率
- `BaseMaterial3D` 使用 albedo tint 和 metallic，不读取 albedo 贴图像素。`ShaderMaterial` 使用 `Fallback Material Reflectance`。透明表面跳过
- 上限为每轴 64 个网格单元、每格 8 个样本、65,536 个样本、32 个发光表面、250,000 个网格三角形，以及包含 PRT、发光遮挡和方向可见性射线在内的 20,000,000 CPU 路径工作预算。超过容量会报错

## 编辑器预览

**Show Probes** 默认开启：未烘焙表面点为灰色，烘焙后显示世界 +Y 单位方向光下的几何传输响应。**Show SH Probes** 默认关闭，开启后用径向网格显示传输响应，最多 256 个样本。预览跟随 Volume 变换，并在几何或布点设置改变后刷新。

## 模块与数据契约

- `FMagicGIVolume` 管理设置、布局匹配、异步烘焙和预览
- `FMagicGIPlacement` 管理几何、布点和 BVH；`FMagicGIEmitterBakeSet` 管理发光面与面积采样；`FMagicGIEmitterBinding` 管理稳定键和签名；`FMagicGISceneTracker` 跟踪场景/资源变化
- `FMagicGIBaker` 积分路径；`FMagicGIData` 验证持久化资源、组合发光响应并打包上传数据
- `FMagicGIRuntime` 选择 Volume 并发布世界/视口快照；每个 `RuntimeState` 只持有注册信息和独立的光照/发光对象；`FMagicGIEmission` 独占源参数、响应缓存和警告，诊断刷新不改写已发布响应。warning getter 只读
- `FengMagicGIPass` 通过可选 Runtime 路径消费快照，管理 RD 纹理、UBO 和释放。Inspector/Viz 负责编辑器操作与预览

`FMagicGIData` 保存 v5 世界空间表面锚点、实际探针中心/法线、布局、场景签名及查找索引。每个样本远场次级传输为 27 个 float，按系数优先、RGB 连续排列：`Y0`、`Y1-1(y)`、`Y10(z)`、`Y11(x)`、`Y2-2(xy)`、`Y2-1(yz)`、`Y20(3z²-1)`、`Y21(xz)`、`Y22(x²-y²)`。远场图集每样本 7 个 RGBA32F texel；primary SkyLight 可见性另存 9 个可能带正负号的标量系数，每样本用 3 个 RGBA32F texel 打包。几何图集每样本 3 个 texel；8×8×2 个距离矩通道共占 512 字节/探针；每网格单元含 8 个有符号 32 位样本索引。运行时仅在已有法线、平面和网格筛选通过后查询可见性，每个候选双线性采样四个 moment texel。

v3 及以上额外保存发光源稳定键、静态签名及每源每样本 6 个 float，顺序为 source、probe、常量 RGB 响应和纹理 RGB 响应。动态 SH 与发光参数独立于烘焙资源。组合函数始终返回每探针一个有限 RGB 值；非法输入或溢出返回零响应。

当前可载入 v2、v3、v4、v5 格式，但只有含显式表面锚点和方向距离矩的 v5 Bake 可参与运行时渲染；v2/v3/v4 仅供检查，需显式重新 Bake，不回退到旧布局，载入时也不会改写旧资源。v5 是烘焙数据 ABI 变更；当前低差异采样器版本为 r3，使用旧随机采样器的 v2 Bake 必须按 r3/v5 重烘，更早的纯辐射值资源也需重烘。调整质量只改变请求值，不改写旧烘焙的样本数。

## 测试

无 GPU 的世界/视口所有权和物理/非物理光照检查：

```sh
python misc/scripts/test_feng_runtime_contracts.py --editor /path/to/godot
```

在已导入上述插件的隔离项目中，运行无界面契约测试：

```sh
/path/to/godot --headless --path /path/to/project --script res://addons/feng-magic-gi/tests/test_runtime_state.gd
```

完整 PRT 与 GPU 集成：

```sh
python misc/scripts/test_magic_gi.py --binary /path/to/godot --driver vulkan
python misc/scripts/tests/run_frp_exposure_balance.py --binary /path/to/godot
```

`test_magic_gi.py` 覆盖布点、烘焙、持久化格式、发光源变化、相机变换和视口路由；Linux 无显示器时可加 `--xvfb`。曝光测试使用程序天空、Height Fog 和合成 PRT，在 60,000 lux 物理模式下检查 GI/Fog 可见贡献，以及 pre-exposure 开关的 LDR 差 ≤ 0.01、曝光 scale 差 ≤ 2%。日志、隔离项目和可选 PNG 保留在 `bin/` 下。
