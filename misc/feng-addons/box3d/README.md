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
编辑器入口另需 `plugin.cfg` 和 `editor_plugin.gd`。不要同时安装另一份同名 Box3D 后端。

## 支持范围

- 静态、刚体和运动学物体，`CharacterBody3D.move_and_slide()`。
- Box、球、胶囊、圆柱、凸包、三角网格、高度图与世界边界碰撞形状。
- Area 重叠事件、重力和阻尼覆盖。
- 射线、点、形状重叠、形状扫掠、碰撞过滤和排除列表。
- Pin、Hinge、Slider 关节，以及接触监测。

尚不支持 `SoftBody3D`、`ConeTwistJoint3D`、`Generic6DOFJoint3D`，部分关节调参
没有对应实现。射线的 `hit_from_inside`、`hit_back_faces`、`pick_ray` 标志在当前
适配层尚未完整对齐 Godot 行为。需要这些功能的场景应继续使用原后端。

其他差异：Area 不会将三角网格/高度图物体作为被检测访客；`collide_shape()`
提供重叠接触点但不提供可靠穿透深度；摩擦力和反弹系数的组合规则不同。详见
[上游行为差异](https://bearlikelion.github.io/godot-box3d/behavior-differences/)。
这些限制不会因为注册成 PhysicsServer 而自动消失。

高级项目设置 `physics/box3d/worker_count` 控制物理工作线程，`0` 为自动选择。
`physics/box3d/length_units_per_meter` 默认 `1`，表示一单位为一米。二者修改后均需重启。

## 验证

```powershell
python misc/feng-addons/box3d/tests/run.py
```

测试使用隔离项目，不改动用户场景。先断言实际后端，再测试刚体落地、休眠、
碰撞过滤、触发器、关节、接触监测、自定义积分、坡面、三角网格/高度图接缝，
以及射线/重叠查询的碰撞节点与网格面索引。本次 **30/30 通过**。
测试项目和日志位于忽略的 `tests/.work/` 中。

这验证了基本接入和上述行为，不代表所有游戏场景的物理结果、性能均优于原后端。
