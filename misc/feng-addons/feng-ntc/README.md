# Feng NTC

Feng NTC 联合压缩材质贴图。默认的 `FengNTCNeuralMaterial` 在片元着色器中直接使用压缩潜变量与网络，**不生成完整 RGBA8 纹理**。制作后游戏不需要 CUDA、LibNTC DLL 或预先导出 BC7。本插件使用公开 RenderingDevice、Texture2DRD / Texture2DArrayRD 和 ShaderMaterial 接口；本次采样改动没有增加引擎源码修改。

这里的“通用”指没有 NVIDIA 专用指令或运行库依赖，**不等于所有设备已经验证**。Vulkan、D3D12 已在本机运行；AMD、Intel、Metal、Android、iOS 仍需对应实机测试。Compatibility / WebGL 无法提供本实现使用的 RenderingDevice 纹理接入。

## 三种加载方式

| 模式 | 加载与采样 | 显存与适用范围 |
| --- | --- | --- |
| NTC 压缩数据直接采样（默认） | 常驻压缩潜变量、GenericInt8 网络及全部 mip，片元着色器推理 | 保留原分辨率，数据显存显著减小；推理会增加 GPU 计算量 |
| 完整 RGBA8 · 仅省包体 | 分批解码全部 mip，完成后使用 StandardMaterial3D；之后不再推理 | RGBA8 纹理常驻，显存高于 BC7；保留标准材质功能 |
| VT 页缓存 · 不透明 PBR | 按请求解码缺失的 64×64 页，包含 2 像素边框；缓存命中直接采样 | 固定页数、LRU 替换和粗 mip 回退；适合能提供局部 UV 可见范围的模型或地形 |

直接采样保留 GenericInt8 数学，通过通用 FP32 / 整数运算实现，没有供应商专用指令。打包权重优先使用材质 uniform 缓冲，避免逐像素纹理寻址；缓冲大小受设备限制时使用纹理承载。可逆的有限浮点位模式保留全部权重位；无法找到安全掩码时使用精确的宽编码。着色器按网络形状及承载方式共享，不为每组权重生成独立代码。缺失潜变量层的零输入和未使用输出通道被跳过。默认用连续坐标推理和双 mip 混合减少噪点；它是神经重建插值，不等同于硬件双线性/各向异性过滤。没有用随机逐帧采样掩盖质量问题。

VT 默认 8×8 个物理槽位，可设置 4～16。小纹理自动缩小分配；粗 mip 常驻，详细页超过容量时降低请求 mip。VT 不逐片元推理，已缓存页不重复解码。所有页解码会话共享每帧最多一次提交；这不是跨 GPU 的毫秒上限。

VT 具有点采样页表、双线性页内过滤、手动 mip 混合和边框处理；页表在页变化时预先解析回退层级。更新详细页只更新受影响的页表区域。压缩潜变量保留在 CPU 内存，GPU 只上传当前页需要的特征窗口。**当前不是磁盘分块流式系统，也没有 GPU 可见性反馈或各向异性 VT 重建。**

## 使用

在 feng-godot 中，本目录沿用现有 addon 自动挂载机制；其他项目可复制到 `addons/feng-ntc`。启用编辑器插件后打开底部 **Feng NTC** 面板：

1. 读取选中 MeshInstance3D 的 StandardMaterial3D，或拖入原始材质。
2. 默认选择“NTC 压缩数据直接采样”、目标 2 bpp、16,384 步；SDK 会选取可用的实际码率。提高码率可改善有损重建质量。制作端仍使用 NVIDIA LibNTC / CUDA，运行时不再依赖它们。
3. 点击“压缩并创建 NTC 材质…”，得到材质 `.tres` 和独立的 `.ntc-<hash>.res` 数据。压缩在后台运行，可取消；相同源内容和参数会复用制作缓存。
4. 应用到模型，支持替换已有 Material Override 并撤销。默认直接采样无需页面请求节点。可选 VT 模式使用 `streamer.gd` 或下列接口请求页面。

```gdscript
# 范围使用最终纹理 UV；允许 Repeat。0 表示请求最细 mip。
virtual_material.request_uv_rect(Rect2(0.25, 0.25, 0.125, 0.125), 0)
var stats = virtual_material.get_runtime_stats()
```

`streamer.gd` 按相机视锥、模型投影尺寸和配置的 UV 范围保守请求页面，不是遮挡反馈。对于占据大 UV 范围的整块网格，应划分空间块并提供各块 UV 范围，或者选择完整加载。没有可见性请求时默认覆盖全 UV，并按缓存容量使用粗 mip。

“另存为普通 BC7 材质…”保留为可选功能，用于基准比较或不需要 NTC 插件的项目；正常制作、加载、VT 渲染都不会走这一步。

已有 NTC 材质可在面板中读取，选择加载模式后点击“已有 NTC 改采样方式（无需重训）…”。只改采样方式会保留原码率；进一步缩小数据需要从原图以较低码率重新压缩。检查器展示压缩数据资源及显存说明，隐藏内部 GPU 参数。

### 为什么 DXT1 比完整 NTC 更小？

Godot 纹理检查器显示的是 **GPU 纹理大小**。完整加载路径会把 2048×2048 底色展开成约 21.33 MiB 的 RGBA8；DXT1 / BC1 约 2.67 MiB。完整 RGBA8 只作为诊断选项，默认使用 NTC 压缩数据直接采样。

当前测试项目的草地、岩石均已从原图重新压缩并实际替换生产材质：2048×2048、完整 12 级 mip，实际码率约 1.67 bpp。每组 DXT1 底色 + BC5 法线为 8,388,648 字节；NTC 常驻压缩数据为 **937,656 字节（0.894 MiB）**，约小 **8.95 倍**，减少 **88.82%**。两张贴图合计也约为原单张 DXT1 的三分之一。这里统计纹理数据，排除驱动对齐、着色器代码和管线分配。

这仍是有损压缩，低码率的细节还原不等同于 BC。它没有以降到 256×256 省显存。按 1 / 2 / 3 / 4 查看原材质、直接 NTC、VT、RGBA8 诊断。可选 VT 的 64 页仍会在全 UV 请求时降至 mip 3；该回退会显示在 HUD 上。

### 输入与材质限制

- 同尺寸、4～8192、长宽分别为 2 的幂次方的 LDR 贴图；底色 RGBA、OpenGL 法线 RGB，以及可选 AO / Roughness / Metallic。
- 没有 ORM 源贴图时不再生成冗余常量 ORM。普通颜色、粗糙度、金属度仍由材质参数表示。
- 底色按 sRGB 处理；法线与 ORM 为线性数据；制作 mip 时处理颜色空间并归一化法线。
- 优先读取原始图像，避免对已损失细节的 BC 纹理再次训练；尊重 Godot 法线导入的 Y 翻转设置。源数据统一为 RGBA8，不保留 16 位或 HDR 精度。
- 完整加载保留 StandardMaterial3D 属性。VT 只支持不透明 UV1 基础 PBR；透明、额外着色层、UV2 AO、三平面等不支持的组合会提示使用完整加载。
- terrain 自定义 ShaderMaterial、纹理数组、UDIM 不会自动改写，需要使用公开请求接口另行接入。

## 制作、导出与旧资源

```text
制作：源图 → 通道打包 → LibNTC 训练 → 可移植权重 / 常量 / 潜变量 / 通道布局
直接采样：上传压缩潜变量及网络 → 片元推理 → PBR 着色
完整加载：GPU 分批解码全部 mip → 普通 RGBA8 材质纹理
VT：请求 UV 区域 → 上传局部特征 → 解码缺页 → 物理图集 → 页表采样 / 缓存复用
```

- 编辑器 SDK 位于被 Godot 忽略的 `tools` 描述文件和 `bin` 内，仅制作端显式加载。导出插件打包计算着色器源与许可证；游戏包无需原生扩展。
- 旧资源的 `.ntc` payload 可在制作端进行 CPU 元数据转换，不需要重新训练。转换后只保留 portable package。已将工作区 `NTC材质测试` 项目的两组材质迁移。
- 批量迁移命令：`godot --headless --path PROJECT --script res://addons/feng-ntc/tools/migrate_assets.gd -- res://materials/example.ntc.res`。它会保存指定数据资源。
- 未迁移的旧资源在无 SDK 的游戏中会明确报错；请在发布前迁移并测试导出包。
- GPU 输出和页表不序列化到材质文件。运行时不写 AppData 解码缓存；只有编辑器制作缓存使用 `user://feng-ntc/encode-v2`。
- `.sdk`、`native/.build`、`tests/.work`、`bin`、日志不进入 Git。游戏不需要 Python、外部服务或下载模型。

## 实测与性能边界

当前验证覆盖 Windows 的 Vulkan 与 D3D12，包括无 SDK 运行与 FRP / D3D12 下的迁移材质显示；其他厂商、移动设备与 Metal 尚未实测。

在 1280×720 满屏 PBR 平面上，直接采样慢于 BC1 + BC5，VT 命中页与其接近；该差距不足以断定 VT 普遍更快。上述均为整个视口时间，不能当作单独材质 pass 或稳定帧预算。具体数值随硬件与场景变化，复测命令见本节末。

### Terrain3D 的 VT 页压缩

`PROJECT/test场景` 已接入 Terrain3D 的实际页生产器。地形近景、远景的 Compression 都可选择 `NTC (baked pages)`，数据放在 `vt_neural_data`。这压缩的是求值后的完整 VT 页，包含线性底色/高度、带符号世界法线/粗糙度、材质参数及有效位，不是把原图换成另一种输入纹理。

在场景树选中 Terrain3D，打开底部 Feng NTC 面板，点击“所选地形：烘焙当前视域 VT → NTC…”，保存页数据与场景。维持地形原有页核心、边框、密度和通道；可从不同视点追加烘焙。没有烘焙到的区域、地形编辑后失效的旧页，在有界模式下直接使用原材质采样；完整缓存模式仍由原生产器补齐。

制作时才使用 CUDA/SDK；运行时采用通用着色器。默认每帧最多向热页缓存解码 4 页。数据资源可设置加载模式、解码页预算、物理缓存格式；修改后会更新解码器并失效旧页，不用重新训练。CPU 始终保留可移植数据包。

**默认使用“压缩驻留 + 有界页缓存”。** 网络和所需潜变量常驻 GPU，解码页缓存独立限制为 384 页、最多 128 MiB；750 个已烘焙虚拟页不必全部展开成 BC7。热页直接走硬件纹理过滤，冷页通过可移植 GenericInt8 采样器读取压缩数据，不以降低虚拟分辨率或改选更粗 mip 来省显存。缺失或源签名失效的页回到原材质采样，停止反复提交无效解码请求。

缓存按投影覆盖面积与像素密度选择页面，以虚拟页身份复用，避免逻辑槽位换号后重复解码。优先级计算分帧执行、有选择间隔与滞回；静止时不继续排序或生产页面。`decoded_cache_pages` / `decoded_cache_mib` 可调整显存与移动时缺页成本，`max_pages_per_frame` 限制解码批次。0 页只用于直接采样诊断，逐像素网络推理会明显更慢。

**“完整硬件页缓存”保留为速度/兼容性对照。** 此模式把所有逻辑页展开成 GPU 支持的 BC7，否则为 RGBA16F，也可显式选择 BC3；与普通 BC7 VT 的物理缓存显存相同。NTC 文件较小，不能据此声称完整物理缓存也较小。默认有界模式同样会使用 BC7 存储热页，但只保存工作集，不导出 BC7 资产。非 BC 设备使用有字节预算的 RGBA16F 工作集；实际性能仍需在对应硬件测量。

Terrain 插件自带制作端 CPU BC7 编码器，因此定制引擎未编译可选 cvtt 模块时仍能产出 BC7，不会整组回退到 RGBA8。近远景同格式的数组按共享槽位合并；支持直接 GPU 回写时中间页用 8 层分批复用，未使用的 SVT cell store 不预分配纹理。这些是存储分配策略，对 BC7 同样生效，与 NTC 网络的压缩率无关。

复测（在插件目录运行）：

```powershell
python tests/terrain_comparison.py --modes raw bc7 ntc_direct --repeats 3 --frames 1200 --cache-pages 384 --output-dir tests/.work/terrain-resident-accepted-static
python tests/terrain_comparison.py --modes bc7 ntc_direct --repeats 3 --frames 1200 --cache-pages 384 --motion --output-dir tests/.work/terrain-resident-accepted-motion
python tests/terrain_vt_run.py --runtime-only
```

CSV、逐轮 JSON、截图和日志留在忽略的 `tests/.work`。无 SDK 的 D3D12 / Vulkan 回归覆盖直接采样、BC7/RGBA 缓存、签名失效、槽位复用和扩容、两种存储模式切换、近远景 NTC/BC7 混用及资源释放。`terrain_modes.gd` 另在真实项目检查实时切换后的材质路由和缓存恢复。只更新 addon，不新增引擎 EXE。

每帧解码页数需要限制并异步排队；Terrain3D 默认每次最多 16 页，全套神经解码的耗时不能按 0.5 ms 预算规划。缓存命中不再推理，但物理页的 RGBA/BC 存储、页表查询与软件 mip 采样仍产生成本。VT 以可见范围和缓存复用换取显存，不能同时常驻整幅 2K 的精细 mip；CPU 侧仍保留压缩数据。

直接采样与 VT 在部分负载下仍慢于 BC7：缺页需要解码，完整加载则使用更大的 RGBA8 显存带宽，BC7 的硬件解码优势无法仅靠接入接口消除。Terrain 的压缩驻留路径在冷页上仍执行片元推理。压缩网络为 NTC GenericInt8；普通 PBR 材质与多时刻光照贴图的压缩率不能直接比较。

## 构建与复测

制作端：Windows x64、NVIDIA Turing 或更新 CUDA GPU，Python 3.11+、VS 2022 C++、CMake 3.22+。安装官方运行库，无需完整 CUDA Toolkit：

```powershell
python tools/setup_sdk.py
python native/build.py --jobs 8
python tests/run.py --gpu vulkan d3d12 --large-asset 'F:/godot/PROJECT/NTC材质测试/materials/gray_rocks.ntc.res' --export
python tests/terrain_vt_run.py
python tests/run.py --sample-asset 'F:/godot/PROJECT/NTC材质测试/materials/grass_ground.ntc.res' --gpu vulkan d3d12 --export
```

上述插件构建只生成 addon DLL，不增加 Godot exe。SDK 固定 RTXNTC v0.10.0-beta，库提交 `35ec039503ef5e151c661beccc82390948dd5218`；下载校验 SHA-256。独立构建可用 `--godot-cpp PATH --cvtt PATH` 指定公共依赖源目录。

测试包含真实压缩、旧资源转换、无 DLL 运行、Vulkan / D3D12 解码一致性、边框绕回、VT 与普通纹理采样对比、淘汰及粗 mip 回退、缓存命中无推理、资源保存与 GPU 生命周期、独立 PCK 导出运行。直接采样还覆盖 narrow / wide 权重的 uniform 与纹理承载。`tests/sample_benchmark.gd` 比较 BC1+BC5 / 直接采样 / VT 命中；`tests/page_benchmark.gd` 对隔离项目中的 `sample.ntc.res` 计时 64² 和 256² 页，分开报告 GPU 时间与同步墙钟时间。`tests/render_benchmark.gd` 保留 BC7 / RGBA8 / VT 对照。原始结果保存在忽略的 `tests/.work`。

## 上游资料与许可证

- [NVIDIA RTXNTC](https://github.com/NVIDIA-RTX/RTXNTC)
- [加载时解码接口](https://github.com/NVIDIA-RTX/RTXNTC/blob/main/docs/integration/InferenceOnLoad.md)
- [采样时推理及性能限制](https://github.com/NVIDIA-RTX/RTXNTC/blob/main/docs/integration/InferenceOnSample.md)
- [腾讯 NDGI 论文](https://arxiv.org/html/2604.12625v1) / [项目页](https://magicdawn.tencent.com/academic/pages/ndgi.html)
- [第三方组件说明](THIRD_PARTY.md)

`shaders/decode.glsl` 移植了 NVIDIA GenericInt8 推理数学，受随附 NVIDIA 许可证约束；没有 DLL 的游戏导出也需保留其通知。本插件不是腾讯 NDGI 源码，也不属于其官方实现。



