# Feng OLV

OLV 是 MagicGI 的离线标签子组件，每个 MagicGI Volume 只使用一个 `FOLVVolume` 子节点。它读取父节点已烘焙的源 Probe，不重算 GI 传输；自己的标签、模型绑定和手工修改保存在 `FOLVData`。运行时只读取分类字节，不运行模型。

## 使用

启用 **Feng Magic GI** 插件即可。选中 `MagicGIVolume`，点击 **OLV 模型 / 手工修正**；没有则创建，已有则选中，重复点击不会添加新节点。OLV 直接使用父节点的 Probe 和范围，无需另选源 Volume。白光盒子项目已经放置了 `MagicGIVolume/OLV`。

单点／批量校正都在同一个 OLV 子节点中完成。误复制的第二个 OLV 会显示重复警告，并拒绝编辑或发布父 Volume 的标签；保留已有数据，删除多余节点即可。

- **启用 OLV 防漏光**：立即开关标签过滤，保留数据，不重烘焙 GI。
- **导入已有 OLV**：将旧 GI 缓存的有效标签复制到独立资源，不启动模型。
- **烘焙 / 更新 OLV 标签**：运行当前选择的模型，更新自己的标签资源。模型变化不会使 GI 传输失效；同一格点上的手工修改会保留。
- **单点编辑**：选中 OLV 节点，默认显示当前视野内未被场景 Mesh 遮挡的有效源 Probe。在 3D 视图点击单选，Shift 追加、Ctrl 切换选择；也可输入编号选择。使用“显示并编辑 Probe”开关隐藏或重新显示。
- **批量编辑**：在视口拖框选择，默认只选显示的点；Shift 框选追加、Ctrl 框选切换，Ctrl+A 选择当前视野中显示的点。需要选择墙后的点时主动开启“透视显示 / 选择”。点击“标记选中为室内／室外”立即修改整组选点。面板提供按当前类别全选（包含遮挡点）、清空选择；也可打开“空间批量框”，设置 `Batch Center / Batch Size` 按空间范围选择。
- **显示筛选**：全部标签／仅室内／仅室外；筛选只影响预览和选择，不修改数据。点太多时开启“仅显示空间批量框内的 Probe”，在下方调整框中心和大小。遮挡按可见 Mesh 的三角形判定，不依赖物理碰撞体；场景和视角不变时复用结果。这部分仅在编辑器选中 OLV 时工作。
- **恢复模型结果**：删除选中 Probe 的手工覆盖。编辑支持撤销／重做。

点的室内／室外颜色取自 OLV Debug 的同一组颜色及其默认显示变换，选中点添加白色圆环，保留标签颜色。面板显示两色图例、总数和选中数量，单选还显示编号与标签。尚未生成标签的有效点显示灰色；几何内部的无效槽位不作为 Probe 显示或编辑。显示的是整套烘焙源 Probe，不受 CLV 驻留范围限制。Mesh 的两色预览仍在 **FRP → Debug Buffers → MagicGI → OLV 室内/室外** 中。

Probe 标记仅在选中 OLV 节点时显示，使用编辑器 GPU 批量覆盖层，避免 FRP 场景曝光把标记压黑。视角、可见几何或筛选改变时更新可见点集合，静止视角复用结果；不向游戏场景添加显示节点或逐帧分类。遮挡预览有编辑器 CPU 开销，不计作正常 GI 运行时开销。

编辑后保存场景。独立标签资源默认存入项目的 `res://bake/olv/`，不会替换 GI manifest、传输矩阵或预插值算子。几何或 Probe 格点真正改变时，旧标签会拒绝绑定，需更新对应的源数据和 OLV；模型变化、开关和手工修改不属于这种情况。

## 保留材料

- `model/`：引擎当前使用的唯一模型包，200,052 参数、64k 检查点；权重 SHA-256 为 `493b09bb5d3ff0471f38f186ef502f8ff4c833cb5b0205b9a608281ee83c3121`。未修改模型权重或其归一化器。
- `data/train.npz` 与 `train_views.npz`：该模型对应的200,000条训练主体，保留六种原始观测，观测不能重复计为独立主体。
- `data/validation.npz`、`hard_validation.npz`：独立开发集。
- `data/test.npz`：普通、困难、拓扑、物体、接触等六套冻结测试，按套保留，互不冒充新增训练样本。
- `data/benchmark/`：v5 冻结的三档基准，144个场景、23,040条主体；保留原始几何、标签和已封存特征。仅评测，不参与训练或选模。
- `tools/train.py`：唯一训练入口；`inference.py` 和 `olv_patch_geometry.py` 是共享模型／几何推理依赖，不是其它训练版本。

数据文件使用 Git LFS；中间权重、旧模型、历史实验报告和生成过程不保留在插件目录。`data/manifest.json` 记录当前数据的数量、来源和文件哈希。

## 训练和评测

依赖 Python 3、NumPy、PyTorch；CUDA 可选。Godot 通过 `FENG_OLV_PYTHON` 指定解释器，也支持当前工作区已配置的本地环境。

```powershell
python tools/train.py --out F:/godot/feng-godot/Temp/olv-training --steps 100000 --device cuda
python tools/train.py --evaluate-test --bundle model --out F:/godot/feng-godot/Temp/olv-test
python tools/train.py --evaluate-benchmark --bundle model --out F:/godot/feng-godot/Temp/olv-benchmark
```

在本目录执行。输出目录必须是新目录。训练从随机权重开始，复用生产的 Transformer 架构和输入变换；只用训练集拟合归一化，以开发集选模，测试／Benchmark 从不参与训练。导出的新模型放在输出目录的 `model/`，不会自动覆盖生产。该入口不是历史训练过程的逐字节重放。

## 功能回归

以下入口在已经烘焙的白光盒子项目中运行；日志和测试资源仅写项目 `.godot/`：

```powershell
godot.windows.editor.x86_64.exe --headless --editor --path "F:/godot/PROJECT/白光盒子测试场景" --script res://addons/feng-olv/tests/test_probe_editor.gd
godot.windows.editor.x86_64.exe --headless --path "F:/godot/PROJECT/白光盒子测试场景" --script res://addons/feng-olv/tests/test_independent.gd
godot.windows.editor.x86_64.exe --path "F:/godot/PROJECT/白光盒子测试场景" --script res://addons/feng-olv/tests/test_rendering.gd
```

回归检查独立模型更新、单点／批量修改、恢复和开关，并验证 GI manifest 及传输数组不变。渲染回归确认手工标签实际进入 Mesh 结果，关闭 OLV 后 GI 继续生效。有限格点、薄缝及二元域自身仍有表示限制，手工编辑不会变成几何遮挡或区分两个同属室内的房间。
