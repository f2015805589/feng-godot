# 大气性能、捕获原点与 HDR 回归修复

基准：`e002032f4c7d430d66b0cafc82f7191b60c50c23`。本文区分已复现的问题、明确的修复合同与尚未获得的目标硬件证据。需要重新编译匹配的引擎，不能只把新增天空 shader 复制给旧可执行文件。

## 参数与效果对齐审计

| 项目 | 本次状态 | 明确边界 |
|---|---|---|
| RGB Rayleigh/Mie/吸收、tent、单位、双光源 | 已实现并回归 | 依据公开API/研究模型；未取得5.8 CDO逐项默认值导出 |
| 半径、Mie g、Trace作者范围、AP起始距离 | 已修正 | 作者范围与本实现数值/采样预算分别记录 |
| Render in Main Pass | 已实现并GPU验证 | 同时门控本组件天空及opaque/forward/transparent空气透视，保留次级光照；独立高度雾不被关闭 |
| Holdout | 部分支持 | 天空RGB黑与捕获保持已GPU测，ALPHA0赋值已源码核对；完整UE材质/场景合成未验证 |
| 物理辐亮度范围 | 保留限制，未完全对齐 | 太阳辐照仍限10M等效lux，shader仍在预曝光之前按60000/背景增益截断场景线性辐亮度；极强光会损失能量 |
| HDR缓冲区范围 | 独立的存储修复 | 新guard在最终缩放之后保护FP16写入，防止Inf/NaN传播；不能恢复上游模型截掉的物理能量 |
| 捕获原点 | 显式Feng适配 | 固定世界原点/anchor/视口相机跟随可选；背景与AP始终按实际相机计算 |
| UE5.8逐像素、云/体积阴影、完整SkyLight | 未验证/未克隆 | 不宣称“完全对齐UE5.8” |

保留上游60000模型上限是为了不在此回归补丁里悄然改变已发布场景的辐亮度与测光策略。去掉它会改变太阳/天空能量比、自动曝光与捕获，需要单独的线性HDR物理参考矩阵。它不是新缓冲区guard的替代品，也不是解决无限物理动态范围的方案。

## 已确认的原因

1. 自动太阳选择每500ms重新扫描全部场景。天空使用`find_children`，雾还有独立的显式栈遍历。现在通过节点加入/移除维护弱引用集合，稳定选择只检查少量方向光；实时验证世界、可见性和树顺序，移除旧的半秒失效窗口。两个插件仍可独立安装。每次服务连接仅做一次初始扫描。
2. 天空引用`POSITION`会使Godot在每次相机平移时重新生成并过滤整个实时radiance map。背景天空需要真实相机位置，但全局反射捕获不必隐式跟随每个观察者。这是移动相机成本显著增加的已测原因。
3. `COLOR <= 60000`不等于实际HDR写入安全。引擎还会施加环境亮度、相机/预曝光、雾与抖动；雾和表面路径也会在源颜色之后继续相加/缩放。现在在这些RGBA16F存储边界之前做有限范围保护，正向超限饱和到65504，不在最终黑像素上补色。
4. 公开UE5.8 API的范围与原实现存在差异：地面半径、Mie各向异性、Trace UI范围、空气透视起始距离，以及主Pass/Holdout控制。极端`g=.999`还暴露了旧相函数分母下限1e-4过度压平前向峰的问题。采用稳定的弦长表达式，在CPU重要性采样、天空和两条空气透视实现中保持一致。

## 捕获行为与迁移

新增三个明确的捕获控制：

- `radiance_capture_position`：世界米坐标，默认世界原点
- `radiance_capture_anchor`：可选Node3D，捕获点跟随其世界位置
- `radiance_follow_camera`：兼容模式，跟随此WorldEnvironment所属视口的当前Camera3D；此模式优先于anchor。相机移动会恢复逐帧重建成本

固定捕获只影响全局天空反射/间接采样的参考位置。可见背景和表面空气透视继续逐视口使用真实相机位置。太阳方向/颜色/强度、光学设置和捕获原点改变仍刷新radiance。不同World3D保留独立资源与原点。

这是有意公开的行为变化：新组件及精确匹配已发布内嵌默认shader的迁移使用固定原点。地面相机飞向太空时，背景跟随相机，反射仍保留作者选择的地面捕获；需要随高度变化的反射时，应指定高空anchor、改变捕获坐标或开启camera-follow。不能将这称为所有位置都与原逐相机反射完全相同。

引擎的`radiance_position_independent`是通用shader合同：该shader承诺其cubemap输出不依赖引擎自动传入的观察相机POSITION。Feng天空仅在`AT_CUBEMAP_PASS`使用显式捕获uniform；普通Sky/custom shader保持原有失效规则。旧发布shader按精确SHA256迁移，增加e002032夹具；修改过的自定义shader不被重写。

## 主Pass与Holdout边界

`render_in_main_pass=false`同时关闭主视图天空与本组件的相机空气透视，包括opaque、forward fallback和transparent路径。GPU包保留active与光源RID，只通过独立位门控aerial evaluator，所以物体直射光的大气透射及反射捕获继续有效。独立高度雾不随之关闭。

`holdout`的天空RGB黑色及captured radiance保持已GPU测试，ALPHA0赋值已源码核对。完整UE场景/材质/后期holdout合成尚未验证，不能据此声称所有holdout语义都已对齐。

## 曝光与雾的准确语义

[UE Auto Exposure](https://dev.epicgames.com/documentation/unreal-engine/auto-exposure-in-unreal-engine)描述预曝光为上一帧曝光对场景颜色的数值范围重映射，目的是避免低精度HDR溢出。最终曝光需要补偿该比例；预曝光不应成为额外的艺术亮度乘数。在未发生存储饱和/下溢的范围内，开关预曝光应保持最终显示。

[UE Sky Atmosphere](https://dev.epicgames.com/documentation/en-us/unreal-engine/sky-atmosphere-component-in-unreal-engine)同时明确区分已有的艺术性Fog Inscattering Color/Directional Inscattering Color与额外的大气贡献。用户先前要求雾像受光材质一样随光变化，因此保留`Lit`默认与原有序列化值；原`Legacy Radiance`的显示名明确为`UE Analytic Radiance`，枚举值不变。两种模式都进入场景曝光链，不能把“预曝光不改变最终效果”理解为“雾不受自动曝光影响”。没有把体积雾Albedo与解析高度雾的艺术辐亮度混称为同一个UE参数。

本次新增的性能/HDR原型一度在普通Compositor应用后直接改曝光字段，没有重新应用快照；那些初步标签未被采信为固定EV证据。原已发布场景夹具的sample()本来就按每组重新apply，其固定EV日志有效。最终新夹具显式apply并读取实际GPU曝光和每个观察阶段的pre-exposure，断言比例确实等于请求值。FengCompositor正常监听renderer.changed；这个修正针对显式调用renderer.apply的测试用普通Compositor。

## 保留与放弃的优化

保留默认13个非调试Pass，保留所有作者覆盖。没有通过关闭TAA、雾、间接光或物体空气透视制造正常场景的加速。

尝试过半分辨率散射重建、全分辨率太阳和锐利区域精确回退。六组场景的最终RGB RMS最大0.000444、最大通道差1/255；线性HDR归一化RMS最大约0.334%。但ABBA实测没有证明稳定的全帧收益，额外子Pass与radiance过滤占主导。因此该原型未进入生产代码，最终保持全分辨率精确天空积分。

首次/光学编辑的CPU LUT构建和太阳进入新角度缓存区间的CPU积分仍有成本；固定捕获不承诺消除动态太阳或持续编辑光学参数的全部开销。持续camera-follow仍是昂贵选项。

## 可复现验证

完整入口：`misc/feng-addons/feng-sky/tests/run_sky_atmosphere_tests.py`，传入匹配的编辑器可执行文件和`--gpu-driver`。性能入口为同一隔离工程中的`atmosphere_gpu_probe.gd -- --capture-performance`；`--performance-only`还包含静态/运动、旧PhysicalSky和关闭大气控制组。所有正常性能区间保留13个作者Pass，计时期间不回读像素。

- 自动光源：5000节点、100次实际旧扫描，中位1495µs/P95 2070µs；事件集合中位2µs，生命周期测试覆盖隐藏、显示、模式、排序、移除、重入、跨世界移动和次光排除
- 两世界radiance重建计数：固定相机运动0/0；太阳运动19/0；捕获原点运动18/0；camera-follow19/0；关闭follow恢复0/0；光学编辑19/0。使用真实生产重建时间戳；固定捕获的panorama内容保持不变，太阳/原点编辑会改变内容，地面到80km可见天空仍变化
- 生产引擎天空存储算术写入float32诊断目标：旧代码24个通道越过半浮点范围，修复0个。这样不依赖显卡将半浮点超限转为Infinity还是直接饱和
- 本机llvmpipe会饱和超限half写入，因此不能把它声称为已复现用户Windows/D3D12黑斑。新增端到端HDR观察点和真实屏幕太阳检查，用来约束早期溢出与后续历史/雾传播

## 固定EV全帧性能

Vulkan 1.4.305、llvmpipe LLVM19.1.7软件GPU；固定EV=-12、60,000lux。每段预热32帧、测量60帧，以follow/fixed/fixed/follow交错顺序复测；13个作者Pass全开、计时区间不读像素。GPU数据来自视口GPU计时器，CPU提交时间与整帧wall分别列出，不把Performance.TIME_PROCESS当GPU时间。

| 分辨率 | 模式 | GPU中位ms（两次） | CPU中位ms（两次） | 整帧wall中位ms（两次） |
|---|---|---|---|---|
| (320, 240) | follow | 230.424 / 174.687 | 1.775 / 1.745 | 247.971 / 188.083 |
| (320, 240) | fixed | 26.048 / 33.903 | 1.409 / 1.475 | 38.221 / 53.323 |
| (640, 360) | follow | 235.154 / 239.223 | 1.848 / 1.826 | 252.311 / 253.545 |
| (640, 360) | fixed | 67.726 / 62.827 | 1.613 / 1.544 | 83.041 / 77.484 |

这些是同机同场景的移动相机结果，不是用户显卡/D3D12或19ms目标的保证。所有测量区间新增draw pipeline编译均为0。固定模式减少不必要的全局捕获，不降低可见天空采样、分辨率或Pass数量；用户选择持续跟随/移动anchor时仍支付重新捕获的成本。静止相机的全分辨率天空积分仍有开销。

## HDR端到端观察

正确应用并断言实际EV后的8组场景覆盖60k/10M lux、0.01°/默认太阳半径、预曝光开关和±16 stops。天空、高度雾、TAA、Color Grade后累计检查1,597,536个RGB通道，无非有限值/超出half存储范围值，太阳输出非黑；实际比例包括65536及1/65536。四个额外观察Pass仅用于读取诊断，不进入任何性能数据。输出达到存储范围上限时允许饱和，不能据此宣称物理HDR能量在关闭预曝光的任意极值下无损。

## 对齐审计的剩余边界

没有获得UE5.8私有源码/CDO或匹配线性HDR参考图，参数语义对齐不等于像素级UE复刻。

已覆盖公开作者参数的单位、RGB系数、tent、双光源、主Pass门控及稳定数值范围。Holdout仅覆盖天空primitive；UE完整材质表达式、云/体积阴影、SkyLight专有特性、scalability与LUT预算不是同一套实现。Trace作者值允许超过UI上限8，但本实现积分仍有64段安全预算，明确区别作者范围与引擎预算。

## 最终验证状态

- 匹配源码的Linux x86_64编辑器构建通过；构建参数`platform=linuxbsd target=editor dev_build=no debug_symbols=no lto=none -j5`
- 实际二进制SHA256：`975439ec7e3ed65913b346e468f2b44cb621aeba61812ed6260e6711f83451d0`；版本标记为基准e002032加本补丁，不靠版本字符串代替文件与行为验证
- 物理、非物理两套完整大气回归通过：组件/世界/迁移、参数、CPU传输、LUT、捕获生命周期、HDR阶段、存储边界、AP/main-pass门控、实际场景、数值与运动
- 两模式各12组移动太阳/相机、36次图像采样；每次25个中心像素加96个轮廓点，未出现黑太阳/黑环。正常组保留13个Pass，TAA关闭组是明确标记的12-Pass独立控制
- 60k lux固定EV场景中，实际曝光均为1/4096，雾像素预曝光开/关RGB差为0；Lit Fog的6/60000、无Sky、独立橙色方向瓣、opaque/fallback/transparent测试通过
- FRP广泛回归20/23通过，另有导入通过。保留三项已知基准失败：MSAA GBuffer材质丢失、ViewState LDR overlay断言（300秒超时，明确记为失败）、Post后置LDR overlay未呈现
- C++/头文件格式检查、`git diff --check`、Python语法与六项AP结构合同通过。未批量重排旧GLSL文件中既存的全文件格式差异

## Pass成本观测

单独启用GPU profile读取真实Pass边界时间戳，以下是每次调用/被观察帧的中位值。GPU query会改变调度，不能把该诊断数字混入前面的无逐Pass查询全帧ABBA数据。

| 相机跟随 | 范围 | CPU中位ms | GPU中位ms | 观测帧数 |
|---|---|---|---|---|
| True | 03 Lighting | 0.048 | 6.931 | 24 |
| True | 05 Sky | 0.013 | 4.319 | 24 |
| True | 08 Temporal AA | 0.037 | 8.074 | 24 |
| True | Radiance update/filter setup | 0.521 | 161.718 | 22 |
| False | 03 Lighting | 0.052 | 5.160 | 24 |
| False | 05 Sky | 0.013 | 4.474 | 24 |
| False | 08 Temporal AA | 0.033 | 8.650 | 24 |

固定捕获组没有观察到radiance update/filter事件。保留跟随时，该阶段是移动相机的主要GPU成本；原生run_pass的热态CPU提交通常远低于26ms，冷编译或用户场景的持续26ms仍需目标捕获区分。
