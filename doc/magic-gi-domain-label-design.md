# OLV 剩余工作与多房间扩展

OLV 的当前使用方式与数据入口见 [Feng OLV 使用说明](../misc/feng-addons/feng-olv/README.md)，
标签域与插值前门控见 [feng_magic_gi_olv_domain.gd](../misc/feng-addons/feng-magic-gi/feng_magic_gi_olv_domain.gd)。
本文只记录尚未交付的部分。

## 范围

OLV v1 面向开放世界或建筑中室内外分界明确的跨域插值漏光：标签描述可见性域，在插值前
逐角判决，不确定时弃权并走旧路径。

两个同为 `INTERIOR` 的房间共享一个标签，门控无法分开它们。这属于另一条路线的前提，
不是 v1 的缺陷修补项，见末节。

## A/B 对比

需要同一场景、同一视角、同一光照下，旧路径与 OLV 修正路径的逐像素对比，并作为一次
修正结果的一部分报告出来。

尚未实现：改标签后只能靠 Undo 回退，无法直接观察两条路径的差异。`Undo`、取消与失败
恢复已可用。

## 训练真值隔离

AI 自动应用产生的标签只能记为 correction batch，不得进入 human gold；只有带人工审核、
渲染证据和确认信息的 approved revision 才能进入训练真值。更换模型只失效对应的 AI
批次，不删除既有 human gold。

尚未实现：append-only revision 归档、manifest 指向 active revision、原子替换与写失败
恢复，以及按 scene 的 train/val/test 划分随数据集归档。

## 未见场景与成本验证

- 未见几何：薄墙、曲面、窄缝、非封闭网格、开放门洞与室内外过渡区。开放门洞要确认没有
  把合理传输一并拒绝，也没有产生过黑。
- relight 稳定性：改变太阳、TOD 与受支持的发光输入后，标签仍应给出稳定结果。
- 回归：旧资源、开关关闭、`ABSTAIN`、模型缺失与 stale hash。
- 成本：完整 GPU 成本（含原生 Lighting 内的采样）、显存、CPU、推理与上传，均需实测。
- 与旧路径在同设备、同场景、同视角、同光照下配对测量。

未见场景的结果需要归档为证据；性能结论只来自实测。

## 多房间：Depth / 混合可见性

当需求包含多个室内房间或更一般的遮挡关系时：

- 为每个 Probe/Cell 设计 DistanceMap/Depth 数据，含稀疏存储与 streaming。
- 按 shading point 与候选 Probe 的实际遮挡关系计算权重，而不是只比较室内外标签。
- 验证 layout 7/8 的数据上传与原生绑定，不把 source 中的距离矩当作运行时已接入。
- 测量 DistanceMap、间接索引、额外采样与显存成本。
- 与 OLV 在同一场景做 A/B：OLV 负责室内外粗域，Depth 负责更细遮挡，再评估混合路线。
- 多房间结果不计入 OLV 已解决范围。

## 参考

- OLV 与 Depth 的公开说明（外部资料）：<https://zhuanlan.zhihu.com/p/2020903414117201233>
- GDC 2026 CLV PRT 公开流程：<https://media.gdcvault.com/gdc2026/Slides/Sheng_Feng_IlluminatingRocosLegacyScalableGlobalIlluminationfromTheorytoPractice.pdf>
