# Box3D

通过 GDExtension 将 Box3D 注册为 Godot 的可选 **3D 物理后端**。不修改引擎 C++
源码，也不需要为切换物理后端重编译引擎。场景继续使用 `StaticBody3D`、
`RigidBody3D`、`CharacterBody3D`、`Area3D` 和现有碰撞形状；2D 物理不受影响。

接入的是 [Erin Catto 的 Box3D](https://github.com/erincatto/box3d)，适配层来自
[godot-box3d v0.3.1](https://github.com/bearlikelion/godot-box3d/tree/v0.3.1)。
当前属于实验性后端，支持范围与 Godot/Jolt 并不完全相同。版本和本地修正见
[THIRD_PARTY.md](THIRD_PARTY.md)，分发时保留 [LICENSES.txt](LICENSES.txt)。

## 使用

1. 保存并重启此仓库构建的 Godot 编辑器。引擎现有的 addon 发现机制会将本目录链接到
   项目的 `addons/box3d`。
2. 在 **项目设置 → 物理 → 3D → Physics Engine** 中选择 **Box3D Physics**。
   也可以使用 **项目 → 工具 → Box3D 物理后端…**，点击“使用 Box3D”。
3. 保存场景并重启编辑器，开始使用新的物理后端。

安装或启用编辑器插件只提供设置入口，不会自动更改已有项目的物理引擎。
PhysicsServer 在启动时创建，因此切换后端或替换 DLL 都需要重启。
插件窗口同时显示“项目设置”和“当前运行”，便于确认是否已经生效。

项目配置对应为：

```ini
[physics]
3d/physics_engine="Box3D Physics"
```

运行时可以直接确认实际后端，避免只检查设置而遗漏加载失败后的回退：

```gdscript
print(PhysicsServer3D.get_class()) # 应为 Box3DPhysicsServer3D
```

恢复原后端：在同一项目设置中选择 `Jolt Physics`、`GodotPhysics3D` 或 `DEFAULT`，
然后重启。禁用编辑器插件不会切换已经运行的物理服务。

## 构建与分发

本地已提供编译后的 Windows x86_64 `bin/box3d.dll`，编辑器和 Release 导出共用
这一份优化库。构建产物不进入 Git；源码、许可、构建脚本和行为测试保留在仓库。

在仓库根目录执行：

```powershell
python misc/feng-addons/box3d/native/build.py
```

需要 Python、Visual Studio 2022 C++ 工具和 CMake 3.22+。脚本会自动查找 VS 自带
的 CMake。`build-feng-godot.bat` 也已加入此插件的构建步骤。
Box3D 和适配层源码均已包含，构建复用 `feng-idweight-terrain/native/godot-cpp`，
无需额外下载一份 SDK。所有中间产物放在忽略的 `native/.build/` 下。

Linux x86_64 可使用同一脚本在目标平台构建 `bin/box3d.so`；本次未在 Linux 验证。
当前面向单精度 Godot 4.5+。本次运行验证使用本仓库的 Godot 4.7.3 自定义版本。

普通 Godot 项目也可以使用：将本插件复制到 `addons/box3d`，包含对应平台的库，
再按上述步骤设置后端。分发运行时只需 `.gdextension`、`bin`、许可文件；
编辑器入口另需 `plugin.cfg` 和 `editor_plugin.gd`；使用扩展软体节点还需
`soft_body_3d.gd`。不要同时安装另一份同名 Box3D 后端。

## 支持范围

- 静态、刚体和运动学物体，`CharacterBody3D.move_and_slide()`。
- Box、球、胶囊、圆柱、凸包、三角网格、高度图与世界边界碰撞形状。
- Area 重叠事件、重力和阻尼覆盖。
- 射线、点、形状重叠、形状扫掠、碰撞过滤和排除列表。
- Pin、Hinge、Slider 关节，以及接触监测。
- `SoftBody3D`：本地 CPU XPBD 求解，支持布料、闭合弹性网格、固定点、质量、
  刚度、阻尼、收缩、力/冲量、刚体碰撞、自碰撞、软体互碰，以及拉伸撕裂和主动切割。
  软体是本地适配层的扩展，不是上游 Box3D 自带功能。
- Godot 的 `PhysicalBoneSimulator3D` / `PhysicalBone3D`，附带可切换布娃娃的 actor。

尚不支持 `ConeTwistJoint3D`、`Generic6DOFJoint3D`，部分关节调参
没有对应实现。射线的 `hit_from_inside`、`hit_back_faces`、`pick_ray` 标志在当前
适配层尚未完整对齐 Godot 行为。需要这些功能的场景应继续使用原后端。

其他差异：Area 不会将三角网格/高度图物体作为被检测访客；`collide_shape()`
提供重叠接触点但不提供可靠穿透深度；摩擦力和反弹系数的组合规则不同。详见
[上游行为差异](https://bearlikelion.github.io/godot-box3d/behavior-differences/)。
这些限制不会因为注册成 PhysicsServer 而自动消失。

软体当前是实验实现：不支持 Area 风场覆盖及软体射线拾取。
刚体接触使用粒子扫掠与接触平面；软体接触使用 BVH 加速的顶点/三角形距离约束和
扫掠穿面检查，排除静止拓扑的相邻顶点。尚未实现完整的边/边连续碰撞检测，
高速旋转、极薄三角形、初始深度穿插仍可能出现穿透，不能保证任意网格完全不穿模。
`pressure_coefficient` 对闭合网格控制保体积约束强度，不是气体充气压力。
支持首个三角形 surface；粒子焊接重复顶点，渲染仍保留原网格的 UV/法线索引。

## 软体碰撞与撕裂设置

普通 `SoftBody3D` 默认启用自碰撞和软体互碰。需要额外调参或撕裂时，使用
`FengBox3DSoftBody3D`，或给 SoftBody3D 挂上 `res://addons/box3d/soft_body_3d.gd`。
检查器提供自动休眠开关 `can_sleep`、独立碰撞开关、碰撞半径、撕裂开关、拉伸阈值和每子步最大断裂数。
原生 `simulation_precision` 继续控制约束迭代次数。软体互碰遵循 Godot 的碰撞层、
掩码和例外列表；任一侧掩码匹配即允许接触，两侧软体互碰开关都需开启。

启用撕裂时，脚本在启动阶段将网格展开为每个三角形角点一个可视顶点，保留 UV、
材质和固定点绑定。求解器仍焊接完整部分；断裂后分开粒子并重新分配质量，
只在断裂时更新连接关系。裂口沿现有三角形边形成，不是任意位置重切三角形。
顶点展开会增加可视网格内存，因此撕裂默认关闭。关闭撕裂不会焊回已经产生的裂口，
示例的“重置”会重建软体。闭合弹性体破裂后停止保体积约束。

```gdscript
var cloth = preload("res://addons/box3d/soft_body_3d.gd").new()
cloth.mesh = your_mesh
cloth.tearing_enabled = true
cloth.tear_stretch_ratio = 1.8
add_child(cloth)
# 启动完成后，按世界空间线段切割；返回断开的边数。
cloth.cut_segment(from_world, to_world, 0.04)
print(cloth.get_solver_statistics())
```

底层也提供 `PhysicsServer3D.call("soft_body_configure", rid, options)`、
`soft_body_cut` 和 `soft_body_get_statistics`。关闭碰撞功能可跳过相应检测；
开启自碰撞/互碰有额外 CPU 成本，不会与未开启时具有相同耗时。

软体默认允许自动休眠。连续 0.5 秒内所有粒子速度低于 0.03 m/s，且累计位移未超过
1 cm，才满足休眠条件；相互接触的软体作为一组判断。冲量、力、固定点移动、参数
修改、邻近物体运动、支撑移走/删除都会唤醒。反复提交同一固定点坐标不会打断休眠。
仍有明显形变或振动的网格继续求解，不会因为经过固定秒数而强制停止。

## 软体和布娃娃示例

直接打开 `res://addons/box3d/examples/soft_ragdoll_lab.tscn` 并按 F6。
在工作区的 `PROJECT/Box3D物理测试` 中，也可按 **4** 进入独立实验室。
它沿用项目的 FRP，独立于 30 排多米诺的性能采样场景。

- 左键发球：击打悬挂布料、弹性球和角色。击中站立角色会切入布娃娃。
- 按住右键转动视角；右键按住时 WASD 移动、Q/E 升降、Shift 加速；滚轮缩放。
- Esc 或释放右键恢复鼠标；失去焦点、退出实验室也会释放鼠标。
- K /“切开布料”：切开悬挂布料；右侧两个弹性球用于观察软体互碰。
- 悬挂布料为 **64×32，共 2048 个初始粒子**，尺寸 3×2 米，固定上方两角。
  保留自碰撞、软体互碰和撕裂；撕裂后分开的粒子会使计数增加。
- T /“切换布娃娃”：切换角色状态；R /“重置”：还原角色和软体。
- “返回多米诺 / 方块墙”：回到测试项目主场景。

`examples/ragdoll_actor.tscn` 可直接实例化；包含 11 根物理骨骼，使用 Pin/Hinge
关节和胶囊可视模型。`set_ragdoll(true, impulse)` 启动，`reset_actor()` 还原。
`player_controlled` 可开启方向键行走。它是基础物理 actor，不含动画资产或蒙皮人物。
Godot 已有骨骼布娃娃系统，正式人物可用同一组原生节点接入自己的 Skeleton3D。
切换为布娃娃时，各骨骼继承角色线速度，再施加命中冲量；重置会清除旧线速度和
角速度。模拟期间关闭 actor 的 GDScript 物理回调，由原生刚体/关节推进和休眠。

高级项目设置 `physics/box3d/worker_count` 控制物理工作线程，`0` 为自动选择。
Windows 下在每次进程启动时读取物理核心拓扑，包含大小核、不把 SMT 当成额外
物理核心；结果限制在 1–32 个参与者，包含调用线程。例如 8 核 16 线程默认用 8，
16 核 32 线程默认用 16，超过 32 核默认仍为 32。换设备后重新启动即可重新检测，
前提是项目设置仍为 `0`；手动指定的非零值不会自动变化。检测结果在进程内缓存，
不会逐帧检测，也不根据场景自动试跑寻找最优线程数。线程更多不保证更快。
压力测试 HUD 显示实际 Box3D 参与者数量和自动／手动模式。
`physics/box3d/length_units_per_meter` 默认 `1`，表示一单位为一米。二者修改后均需重启。

## 验证

```powershell
python misc/feng-addons/box3d/tests/run.py
```

测试使用隔离项目，不改动用户场景。先断言实际后端，再测试刚体落地、休眠、
碰撞过滤、触发器、关节、接触监测、自定义积分、坡面、三角网格/高度图接缝，
以及射线/重叠查询的碰撞节点与网格面索引、软体固定点/变换/碰撞/力、布娃娃切换
和形状生命周期。检查还覆盖软体自碰撞/互碰/过滤、快速穿面、切割与拉伸撕裂、
断裂质量守恒、裂口稳定性，以及环境缓存更新。图形验证还检查 FRP 下相机转向、
布料受球击打变形、裂口渲染、骨骼落地和重置；脚本为 `tests/playground_showcase.gd`。
回调生命周期检查覆盖静止但清醒的刚体、休眠/唤醒、积分回调的 userdata，以及
回调中删除自身/其他刚体并立即创建替代刚体的情况。
自动休眠回归还覆盖同一姿态保持、重新受力、固定点同步、刚体进入、移走/删除刚体或
软体支撑；碰撞缓存检查覆盖运行时增加厚度、高速扫掠，以及六个碰撞对象超过缓存容量、
删除碰撞对象、替换网格后其余接触仍然稳定。测试项目和日志位于忽略的 `tests/.work/` 中。

性能复测命令：

```powershell
python misc/feng-addons/box3d/tests/benchmark.py
```

固定 120 Hz、4 个 Box3D 工作线程；每次预热 60 帧后采样 600 步、重复 3 次。
`soft_rest`、`ragdolls_rest` 预热 1800 帧，且不强制休眠。统计的是无渲染模式下
相邻物理帧之间的 CPU 墙钟时间，包含 Godot 和适配层，不是 GPU 耗时，也不是仅
Box3D 求解器的计时。

软体负载采样结束时均未休眠，结果反映活跃求解成本。计时结束后对全部软体可视顶点
的世界位置计算 SHA-256，四个软体负载在 1、4、8 个工作线程下结果逐位相同；校验
工作不计入性能采样。原生调度回归覆盖 1、2、4、8 个工作线程，以及同步执行回调的
任务调度器。

该悬挂负载自接触较少，采样末帧接触修正数为零；接触密集时仍执行完整的两轮碰撞求解。
所有测试的子步数、精度、碰撞半径、约束刚度均未降低。不同网格形状、接触数量、
休眠比例和 CPU 会改变结果，低接触场景的提升不能直接套到布料堆叠。该基准直接提交
软体 RID 的网格、姿态和固定点，避免依赖 headless 模式不会执行的渲染前固定点同步；
检查悬挂高度，防止测到无固定点的落地布料。普通悬挂负载不包含撕裂拓扑重建或渲染上传；
`cloth_reimpact_tearing` 单独开启与实验室相同的撕裂布局，并记录预热阶段的撕裂尖峰。

`--case cloth2048|cloth4096|rigid|soft|soft_contacts|soft_stack|soft_balls|soft_rest|ragdolls|ragdolls_rest` 可选择负载；
`--library` 可指定对照 DLL，`--workers` 可指定工作线程数（默认 4）。

### 落地布料再次击打

```powershell
python misc/feng-addons/box3d/tests/benchmark.py --case cloth_reimpact_tearing --case cloth_reimpact --workers 8 --repeats 3
bin/godot.windows.editor.x86_64.exe --path "F:/godot/PROJECT/Box3D物理测试" --fixed-fps 120 --script res://addons/box3d/tests/cloth_lab_benchmark.gd
```

第二条使用实际 FRP 管线和完整软体实验室：先击打悬挂布料，释放支撑，落地后再发射三次。
目标取自地板范围内的真实布料顶点，避免飞散碎片扩大 AABB 后把球射向空处。
记录逐帧物理窗口、整帧间隔、发射资源创建耗时、接触和撕裂计数，默认输出
`res://.godot/cloth-lab-benchmark.json`；`-- --result=<路径>` 可指定结果文件。
物理窗口从 `physics_frame` 到 `process_frame`，包含场景物理回调和服务器步进；整帧还包含
渲染、统计脚本及发射操作，二者不能当成纯求解器或 GPU 耗时。

撕裂重建使用复用的连续缓冲、按粒子编号分桶和局部排序，保持原有粒子编号、质量分配、
约束及碰撞查询顺序；BVH 重建预先计算三角形中心。球体复用网格、材质与碰撞形状，
避免每次发射重新创建相同资源。2048 初始粒子、4 子步、精度 6、自碰撞、互碰、撕裂均保留。
2026-11-04 本机 8 工作线程三轮对照，开启撕裂的无渲染测试中，发生撕裂帧的峰值中位数
从 9.17 ms 降到 3.97 ms；普通落地再次击打中位数约 1.17 ms，基本不变。
四组软体负载的最终顶点及刚体状态 SHA-256 与修改前一致，46 项物理回归通过。
同机完整 FRP 实验室三轮测试，撞击撕裂的物理窗口峰值中位数从 18.14 ms 降到 7.81 ms，
再次发射资源创建从 0.373 ms 降到 0.084 ms。落地后二次击打的物理窗口中位数约
3.18 ms、整帧中位数约 4.38 ms，均基本不变；提升主要发生在瞬时重建和资源创建。
逐帧接触、撕裂数量与修改前一致。上述数值来自 Ryzen 7 9850X3D / RTX 3080 Ti、
120 Hz 固定步进，不能当作其他硬件或更密集布料堆叠的通用帧预算。

## 刚体压力场景与 Jolt 对照

`examples/rigid_stress_60k.tscn` 默认创建 **10,000 个动态刚体**，可切换 30,000 / 60,000。
在 `PROJECT/Box3D物理测试` 运行主场景后按 **5**，或打开项目中的
`rigid_stress_60k.tscn` 按 F6。右键转向，WASD/QE 移动，Shift 加速；
R 重置，按钮切换持续扰动和休眠。返回主场景时恢复原来的物理步进和垂直同步设置。

场景用真实 PhysicsServer3D 刚体和一份 MultiMesh 显示；新注册的
`FengPhysicsStressBatch` 只调用公开服务器 API，Jolt 与 Box3D 使用相同的辅助类。
不创建一万个 GDScript 回调。共享立方体形状、初始姿态、质量、摩擦、阻尼和施加的
冲量相同；脚本记录初始姿态 SHA-256，并从直接刚体状态类确认实际后端。

复测命令（在引擎仓库根目录）：

```powershell
python misc/feng-addons/box3d/tests/compare_backends.py --count 10000 --repeats 3
python misc/feng-addons/box3d/tests/compare_backends.py --count 10000 --case stir --render --repeats 3
python misc/feng-addons/box3d/tests/compare_backends.py --count 10000 --render --render-project "F:/godot/PROJECT/Box3D物理测试" --realtime --repeats 3
```

`--backend box3d|jolt` 选择后端，`--library <DLL>` 对照不同库，
`--box3d-workers` 默认为 0（物理核心自动检测），`--godot-workers` 默认为 -1
（Godot 自动线程池，Jolt 使用此池），两个参数分别设置，不能视为同一种线程计数。
`--render-project` 在隔离副本中使用指定项目的管线、自动加载和显示设置；
`--realtime` 使用交互运行的墙钟时间，同时报告实际每秒模拟步数。
`--core-profile` 可额外采集 Box3D 内部阶段计时，用于定位热点；正式性能对比关闭
此选项，避免统计读回本身影响帧耗时。
隔离项目、逐轮日志、结果 JSON 和渲染截图放在忽略的
`tests/.work/rigid-compare-*` 中，不修改生产项目的后端设置。

两个后端的对比要求线程配置一致：Box3D 用自动检测（本机 8 个参与者，含调用线程），
Jolt 使用 Godot 默认线程池。完整 `Box3D物理测试` FRP 配置下，120 Hz 墙钟运行、
关闭休眠、预热 240 步、采样 600 步，堆叠与扰动各交错运行三轮，每轮中位数再取中位数。

计时从 `_physics_process` 末尾到同帧 `_process` 开头，包含服务器 step 和少量
主循环开销，不包含之前的 `flush_queries`、脚本施加冲量或之后的显示同步。
整帧间隔另报，避免把 Godot 的一秒最大物理监视值当成逐帧耗时。
自动测试默认强制每帧推进一步；加 `--realtime` 后与交互模式相同，最多补一步，
超出预算时模拟会慢放。实际运行中渲染帧多于物理步，整帧统计包含无物理步的帧；
物理步窗口和显示同步只采样实际执行的工作，不能将它们直接相加当作整帧均值。

这是**当前安装的两个后端及其默认求解设置**的比较：Box3D 为 4 子步，Jolt 为
10 次速度 / 2 次位置迭代，不能称为相同的求解器或精度。当前编辑器中的 Jolt 还包含
DEBUG_ENABLED 的任务计时和锁，而插件为 Release；不能据此断言两个独立 Release
物理库的普遍性能排名。

用户物理回调收到 RID 快照，允许在回调中删除本体或其他刚体。关闭没有消费者的
原生接触事件数组时，Godot 的接触监视仍完整读取 manifold。

## 上游物理问题核对

本节核对上游 issue 对本适配层的影响。

| 上游 issue | 本插件结论 |
| --- | --- |
| [#209 材质和接触复用](https://github.com/erincatto/box3d/issues/209) | 修复运行时材质不传给已有形状，以及复用接触保留旧摩擦/反弹系数；变更时使缓存失效并唤醒接触对象。 |
| [#184 网格接触三角形截断](https://github.com/erincatto/box3d/issues/184) | 超过 256 个候选时使用工作线程 arena 扩容，保留全部候选；回归覆盖 2178 个三角形。 |
| [#32 贴面扫掠无法离开](https://github.com/erincatto/box3d/issues/32) | 保留接触容差内仍有效的分离法线；软体忽略离开方向的零距离命中，保留进入方向和未知法线的阻挡。 |
| [#208 运动学关节并发写](https://github.com/erincatto/box3d/issues/208) | 当前暴露的 Pin/Hinge/Slider 路径已有 dynamicFlag 写保护；报告涉及的 MotorJoint 未暴露。 |
| #206 形状中心、#205 Wheel、#198 角弹簧、#190 Motor、#167 风力、#197 快照恢复 | 原生路径存在相关风险，但当前适配层未调用对应 API/参数；不宣称这些上游问题已全部修复。 |
| #164 多体场景冻结 | 报告条件不足，尚未复现，未据此修改算法。 |
| #200 GeometryMover 示例、#186 TOI 树顺序、#73 rollingImpulse | 分别为未打包示例逻辑、确定性增强需求、子步冲量统计语义；未确认当前适配器具有同类功能缺陷。 |

原生回归目标 `box3d-physics-issues` 需显式构建，产物只在忽略的 `native/.build/` 中。
测试程序的网格数据保留到世界销毁之后。软体冲击测试覆盖 120 Hz、质量守恒、固定点、
能量预算和地面支撑。重球击打后，极轻的撕裂碎片可能高速飞远、越过有限测试地板，
扩大整张渲染网格的包围盒；没有通过限制碎片位置或删除粒子来隐藏这种行为。
