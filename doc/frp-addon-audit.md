# Feng 七个插件架构复核

日期：2026-10-01。范围：`misc/feng-addons` 七个插件、自有构建/检查工具，以及相关编辑器、渲染与 Tracy 模块接口。

## 结论与覆盖范围

已通读当前自有实现代码，包含 GDScript、C++、C#、着色器与构建工具，共 323 个生产/构建源码文件、87,475 行。第三方库、生成代码、二进制与素材不计入；现有大型地形测试目录按具体测试记录覆盖，未宣称逐个测试全部执行。部分 C++ 阅读批次省略空行和独立行注释，未省略实现语句。逐文件范围与当前哈希见 [覆盖清单](frp-addon-audit-coverage.json)。

现有分层总体合理。此次保留兼容场景 API，围绕所有权、缓存失效、纹理读写和数据迁移修复有证据的问题，没有按文件大小进行机械拆分或重写。默认管线仍为 14 个条目，其中 13 个普通条目默认开启，Debug Buffers 默认关闭。

| 插件 | 保留的职责边界 | 本次重点 |
|---|---|---|
| feng-render-pipeline | Renderer 作者资源、执行计划、逐视口状态、Pass 纹理声明与原生适配 | 独立视口租约；可选后处理的尺寸与输入所有权 |
| feng-fog | 作者参数、主线程世界路由、不可变快照、GPU 消费 | 与其他生产者独立释放；恢复原始 debanding |
| feng-magic-gi | 几何/放置、离线烘焙、数据持久化、光源观察、运行时 SH | 显式太阳选择与物理色温失效 |
| feng-sky | 参数与兼容迁移、光学传输/LUT、环境所有权、快照发布 | Unreal 参数/传输对齐；详见 Sky 文档与数值测试 |
| feng-idweight-terrain | Terrain3D 兼容门面、区域数据、网格、资产、VT 规划/驻留/生产 | 区域转换安全、编辑器绑定与 C# 边界 |
| feng-godottracy | 编辑器启动工具与引擎事件模块分离 | Tracy 分配型源位置及 UTF-8 字符串生命周期 |
| feng-renderdoc-capture | 引擎早期装载、原生捕获、编辑器状态恢复分离 | 保留现有捕获代次和恢复所有权，不跨层合并 |

雾的白色基底与方向性着色独立；物理光照的 60,000 lux 测试基准不变。Fog、Sky 与 PRT 的光照语义不同，不应仅因都读取太阳就合并为一个服务。

## 已修复并验证

1. **跨插件视口注销**：共享注册表改为弱所有者租约。同一视口由 Fog/GI/Sky 多方注册时，一方退出不再删除其他方的路由。保留无 owner 的旧接口；实际成员变化才使缓存失效。覆盖弱引用、幂等注册、子树释放和双向跨插件注销。
2. **Magic GI 缓存**：显式太阳切换/清除与 panorama 光源变化分别失效；物理光照纳入线性色温。修复前红太阳切换为已存在的绿太阳仍返回旧 SH，6500 K→2000 K 也不更新；修复后物理/非物理模式及全部 27 个系数回归通过。
3. **Tracy 生命周期**：分配型 source-location 每次提交转移一次所有权；动态消息使用复制 API；持久名称复用引擎现有 interner。生产翻译单元的确定性所有权测试及真实客户端连接/断连压力测试通过。原实现确定性测试失败，但未宣称观察到真实 allocator 崩溃。
4. **可选 Blur/Bloom-lite/FXAA**：缩放 pass 的 UV 按目标尺寸覆盖全画面；FXAA 先复制至逐视口 scratch，再读取邻域，消除同一 dispatch 的反馈。旧默认 `library:fxaa` 经严格匹配后迁移，保留参数、开关、顺序和共享资源；自定义 shader/绑定不替换。真实 Vulkan 图案测试中，旧版 blur/bloom 最大误差均为 0.75、FXAA 为 0.18408；新版四项误差均为 0。磁盘往返旧资源与同步入口测试通过。
5. **区域缩小的数据丢失**：原先 size128 的区域 `(63,0)` 缩为64会生成越界126/127，在替换失败前已把原区域标记删除。现在先验证全部目标范围与容量，再检查每次提交；失败恢复原表、布局与删除标记。真实 Linux GDExtension 回归覆盖正/负边界、对象身份、高度/材质字节、保存后原文件仍在，以及有效合并/拆分。生产 helper 还覆盖逐次插入失败回滚。
6. **编辑器与迁移工具**：选择切换/退出时按所有者释放 terrain 的 editor/plugin 指针；提前断开 picker 回调。headless mock 和真实 ClassDB 绑定测试通过。区域移动工具改为预检、分阶段 rename、检查失败与回滚，保留失败恢复路径；它仍不是崩溃安全或并发写入安全的文件事务。旧 `link_plugin.ps1` 不再递归删除已有目录，只接受缺失目标或已匹配 junction。
7. **C# 与通道打包**：修复 Bind 继承方向、若干省略参数的原生默认值，以及丢失的 Variant 返回值；源码/原生接口契约测试通过。通道打包修复反向法线旋转奇点与保存失败传播；失败注入和有限值/正交性测试通过。

地形的旧 `0xFFFE` 测试改为真实 PLANNED 哨兵语义；活动文档使用 canonical VT pass id1。AP 的准备回调经 Volume 包装转发，LUT 使用专用线性 clamp sampler，避免包装层丢失新接口或继承最近点采样。

## 剩余问题与后续优先级

以下未在本次继续修改。P1 表示指定场景的功能正确性问题；P2 表示可选路径、资源失败或局部边界问题，不代表已发生线上事故。

| 优先级 | 条件与证据 | 建议回归 |
|---|---|---|
| P1 | `Terrain3DStreamer::initialize` 更换数据对象未清空 `_missing/_streamed`；从数据集A切换到B可继承错误缺失/所有权记录 | 同坐标在A缺失、B存在的目录切换 |
| P1 | `terrain_3d_surface_views_far_walk.cpp` 的容量降级提高 mip 却不对齐/合并子地址；四个兄弟页、容量1时仍截取一个细页 | 生产循环提取已复现；补真实容量压力图像测试 |
| P2 | SVT fallback policy1 返回 mip 局部地址，调用方期待 mip0 地址；默认 policy0 不受此条件影响 | 提取原函数已复现 ±64、mip4；补远景根覆盖测试 |
| P2 | 异步压缩 fallback 预留3个回调，部分压缩通道仅完成2个时 lease 不归零；Feng 直接 GPU copy 路径绕过此分支 | 强制异步 fallback，覆盖1/2/3通道及过时代次 |
| P2 | `_copy_cell_page` 跳过缺失来源仍返回成功；部分失败可能未归一化却发布 ready | 注入 source-view/纹理分配失败 |
| P2 | Cell-store 部分上传失败、clipmap staging 分配失败的回滚/重试不完整；indirection 首次 RID 发布可能存在锁外写入 | 分配/上传失败注入及 ThreadSanitizer |
| P2 | 可选 atlas 的 global rect 未赋值；无 spare 的静止满网格失效后可能无法补页 | 直接/native Atlas 配置测试；正常 Shape 默认有 spare |
| P2 | CDLOD 外层仅比较 transform，可能跳过高度范围改变后的 AABB 更新 | 静止相机、相同 patch、抬高地形 |
| P2 | 未入树 Terrain3D 的部分 setter 依赖尚未创建的数据/标签对象；满资产列表最后一项键盘选择有边界问题 | 构造后属性恢复、满容量编辑器导航 |
| P2 | `get_normal` 重复检查 hx 而未检查 hz；工具归一化公式在非零最小值时有偏差 | 缺失Z邻居和非零最小值图像 |

潜在页池 abort-budget 的零预算退款问题目前无生产调用者；诊断 projected-demand 在非单位 vertex spacing 下存在单位差异。它们应保持独立测试，不应借机改写正常 VT 规划器。可选运行时加载器对“同会话后装插件”的负缓存也仍需单独定义契约。

## 验证边界与复跑入口

- 已构建 Linux 编辑器与地形 GDExtension；数据测试为真实原生调用，地形全渲染/完整编辑器 GUI 生命周期未因此视为通过
- Vulkan 图像回归使用 llvmpipe；部分语义测试并发执行，不据此报告性能改善或目标显卡时序
- 无 `dotnet`，C# 未编译执行；无 PowerShell，junction 修复只完成源码安全检查；Windows/D3D12 与真实 RenderDoc 捕获未复验
- 源码通读不等于无缺陷，也不等于所有已有测试通过；Sky 最终数值、GPU 与完整管线结果另见对应验证记录

主要入口：`misc/scripts/test_feng_runtime_contracts.py`、`test_feng_tracy_lifetime.py`、`test_frp_optional_library.py`，以及地形 `native/tests/region_resize/run_tests.py`、`terrain_region_resize_bounds_runner.py`、`editor_tool_contracts_runner.py`、`csharp_wrapper_contract_test.py`。这些入口分别区分 CPU、原生绑定、图像和源码契约，不用源码字符串检查替代运行结果。
