# Feng OLV

OLV 是 MagicGI 的离线标签子组件，每个 MagicGI Volume 只使用一个 `FOLVVolume` 子节点。它读取父节点已烘焙的源 Probe，不重算 GI 传输；自己的标签、模型绑定和手工修改保存在 `FOLVData`。运行时只读取分类字节，不运行模型。

## 使用

启用 **Feng Magic GI** 插件即可。选中 `MagicGIVolume`，点击 **打开 OLV 子节点**；没有则创建，已有则选中，重复点击不会添加新节点。OLV 直接使用父节点的 Probe 和范围，无需另选源 Volume。白光盒子项目已经放置了 `MagicGIVolume/OLV`。

单点／批量校正都在同一个 OLV 子节点中完成。误复制的第二个 OLV 会显示重复警告，并拒绝编辑或发布父 Volume 的标签；保留已有数据，删除多余节点即可。

- **启用 OLV 防漏光**：立即开关标签过滤，保留数据，不重烘焙 GI。
- **导入已有 OLV**：将旧 GI 缓存的有效标签复制到独立资源，不启动模型。
- **烘焙 / 更新 OLV 标签**：运行当前选择的模型，更新自己的标签资源。模型变化不会使 GI 传输失效；同一格点上的手工修改会保留。
- **单点编辑**：打开“显示 Probe”和“编辑 Probe”，在 3D 视图点击点选，Ctrl/Shift 多选。也可输入 Probe 编号选择。
- **批量编辑**：设置 `Batch Center / Batch Size`，在白色框内选中一批 Probe，再点击“标记选中为室内／室外”。
- **恢复模型结果**：删除选中 Probe 的手工覆盖。编辑支持撤销／重做。

点的青色为室内，黄色为室外，白色表示当前选择。Mesh 的两色预览仍在 **FRP → Debug Buffers → MagicGI → OLV 室内/室外** 中。标签不是颜色插值，也不通过预览状态启用。

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
godot.windows.editor.x86_64.console.exe --headless --path "F:/godot/PROJECT/白光盒子测试场景" --script res://addons/feng-olv/tests/test_independent.gd
godot.windows.editor.x86_64.console.exe --path "F:/godot/PROJECT/白光盒子测试场景" --script res://addons/feng-olv/tests/test_rendering.gd
```

回归检查独立模型更新、单点／批量修改、恢复和开关，并验证 GI manifest 及传输数组不变。渲染回归确认手工标签实际进入 Mesh 结果，关闭 OLV 后 GI 继续生效。有限格点、薄缝及二元域自身仍有表示限制，手工编辑不会变成几何遮挡或区分两个同属室内的房间。
