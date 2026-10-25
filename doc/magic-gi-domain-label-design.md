# Magic GI 域标签（OLV-like）技术设计与分阶段实施

**Evidence scope:** 本文只按**文章自报**转述公开文章给出的 OLV 名称与用途（**本文未独立验证其实现**）；腾讯的网络结构、训练流程、编辑器 UI 均未公开，本文不作任何推测性复刻。本文是一份 **OLV-like 自研设计**，不是与腾讯 OLV 的兼容承诺，也不声称与其实现等价或可比。本文所述功能 **当前未实现、未训练、未跑测试**：文内所有 `[现有]` 标记的事实来自本次只读代码核查（引用给到 `path:line`，默认相对仓库根；显式标注为**仓外**的绝对路径除外），所有 `[提议]` 标记的内容均为设计建议，均未在引擎中验证，不构成性能、精度或资源承诺。参考文章中出现的任何量化指标均为文章自报，本文未独立核实其账号官方性，也未复现，故不作为本文任何决策依据。

---

## 1. 背景

### 1.1 公开信息边界

- **文章称（文章自报，本文未独立验证其实现）**：OLV 面向 GI probe 的可见性标签，基于**神经网络优化**，并用于**自动划分室内/外区域**；它是更大 GI 方案（预计算传输 + 运行时重光照）的一部分。原文链接见 §14：<https://zhuanlan.zhihu.com/p/2020903414117201233>。
- **仍未公开**：网络结构、输入特征、训练数据与训练流程、编辑器/标注 UI、以及任何代码。本文不据此推测其实现，也不把文章描述当作已验证事实。
- 因此本文不自称 OLV 实现，只在**问题形态**上对齐：把"某个 GI 采样点属于哪个可见性域"变成可人工审核、可学习、可在烘焙前推理的显式数据。

### 1.2 本项目现状（`[现有]`）

- 引擎为本仓库分支 Godot 4.7.3-rc（`version.py:3-6`），渲染侧由自研 FRP 插件承载；Magic GI 的职责与集成边界见 `misc/feng-addons/README.md:19`、`misc/feng-addons/README.md:24-27`。
- 默认运行时是 **backend 1 = "MagicDawn CLV Block PRT (dynamic)"**，`clv_cache_backend` 默认 1、`use_clv` 默认 true、`clv_cell_size` 默认 0.25 m（`misc/feng-addons/feng-magic-gi/feng_magic_gi_volume.gd:201`、`:210`、`:220`）。
- 该 backend 的驻留缓存是 **layout 5** 的预插值线性算子（`misc/feng-addons/feng-render-pipeline/passes/magic_gi_preinterpolated_volume_cache.gd:3-6`），项目自述其架构参考腾讯公开的 CLV PRT 流程、但不宣称与其私有代码或 SH2 资源兼容（`misc/feng-addons/feng-magic-gi/README.md:82`、`misc/feng-addons/feng-render-pipeline/README.md:113`）。
- 项目自测记录（**项目自报，非本文承诺**）见 `misc/feng-addons/feng-magic-gi/README.md:88`。

### 1.3 要解决的问题

layout 5 的接收者按硬件三线性在自由空间 cell 上混合，混色发生在任何按域判断之前。如果相邻 cell 属于不同可见性域（门洞、薄墙、曲面窄缝、非封闭网格），混入的能量在采样之后无法"解混"。本文要定义的是：**在混合之前**知道每个采样点/每个 cell 的域归属，并让该归属可被人工审核、可训练、可复现、可验收。

---

## 2. 目标与非目标

### 2.1 目标（分阶段）

1. 把"域标签"定义成显式、可解释、可序列化的数据契约。
2. 在编辑器内形成闭环：几何分析 → 标签建议 → overlay 审核 → 人工批准 → 导出数据集。
3. 用离线训练得到小模型，在编辑器内做轻量推理，产出可被审核的标签建议。
4. 在渲染侧以**可开关、可回归**的方式验证标签接入不会引入跨域混合。

### 2.2 非目标 / v0 硬边界

- **不移动、不新增、不删除任何 Probe**。标签只描述既有采样点；纠标签不等于移动 Probe，也不等于直接修改 GI 结果。
- **v0/v1 不训练 Transformer**（进入条件见 §8.3）。
- **不直接修改 layout 5 热路径**。v0 的渲染正确性实验在 legacy/gather 车道完成（§10.1）；layout 5 的插值前方案只做可行性比较（§10.2）。
- **不支持动态几何**。动态几何仍需重新烘焙；本文先验证静态烘焙 + 标签纠偏（`misc/feng-addons/feng-magic-gi/README.md:114` 记录了现有静态遮挡语义）。
- 编辑器里的"点按钮"是**几何分析 / 模型推理**，不是现场训练；训练始终离线进行。

---

## 3. 术语

| 术语 | 含义 | 备注 |
| --- | --- | --- |
| domain_class | 采样点的可见性域类别（§6.1） | 主任务输出 |
| abstain | 推理侧的弃权/置信信号（§6.1） | **不是** `domain_class` 取值 |
| subject | 带标签的对象：surface Probe 或 layout 5 自由空间 cell | 由 `subject_kind` 区分 |
| surface Probe | 表面锚定的 PRT 采样点，含位置/法线/安全偏移 | 现有语义，见工程 README |
| CLV cell | layout 5 的 0.25 m 自由空间格点 | 与 surface Probe **非同一种对象** |
| teacher | 由几何规则或已有算法产出的标签（silver） | 可批量、可信度有限 |
| pseudo | 未审核的模型预测 | 必须隔离，不得进入 gold |
| gold | 人工批准（或人工修正）后的标签 | 唯一高可信真值 |
| sidecar | 与 bake 资源分离的审核/训练元数据文件 | 不覆盖 bake 产物 |

---

## 4. 当前架构证据（`[现有]`）

### 4.1 默认车道：layout 5 prepared 算子

- 常量与驻留：`PREPARED_LAYOUT := 5`、`_prepared_validity`（每 cell 1 byte）、`_prepared_validity = source.clv_prepared_validity`、驻留筛选 `if _prepared_validity[source_index] == 0: continue`
  —— `misc/feng-addons/feng-render-pipeline/passes/magic_gi_preinterpolated_volume_cache.gd:6`、`:16`、`:76`、`:179`。
- 重光照管线创建：`misc/feng-addons/feng-render-pipeline/passes/magic_gi_preinterpolated_volume_cache.gd:126`；shader 源 `:8-9`。
- 运行时采样入口 `frp_magic_gi_dynamic_volume_sample()` 按 `dimensions_version.w == 5` 分派到 prepared 分支
  —— `misc/feng-addons/feng-render-pipeline/library/magic-gi/magic_gi_dynamic_volume_sample.glslinc:361`、`:375-397`（`dimensions.w == 5` 判定见 `:378`）。
- prepared 采样体 `frp_magic_gi_preinterpolated_sample_lod()`：**布局守卫** `:330`（`origin.w`、`layout_info.y == 7`、`dimensions.w == 5`）；**网格范围检查** `:332-334`；**7 次硬件三线性取值** `:339-354`；SH9 解码 + `coverage > 0.5` 返回 `:355-358`；相邻 LOD 混合 `:385-393`（**未定义**"全拒"路径，见 §10.2）。
- 结论：该路径**没有**逐 cell 有效性读取、没有距离矩、没有 BVH、没有逐角过滤。这与 `misc/feng-addons/feng-magic-gi/README.md:84`（"没有逐像素邻居循环、距离矩筛选、BVH"）一致。

### 4.2 legacy / gather 车道

- 候选级可见性与累加：`misc/feng-addons/feng-render-pipeline/library/magic-gi/magic_gi_gather.glslinc:459-460`、`:534`——每个候选先算可见性，再进入加权累加；被拒候选不参与归一化（语义描述见 `misc/feng-addons/feng-magic-gi/README.md:112`）。
- probe 可见性函数（Chebyshev 距离矩，且三次方收紧）：`misc/feng-addons/feng-render-pipeline/library/magic-gi/magic_gi_clv_probe_visibility.glslinc:87-101`、`:103-111`；CPU 侧同构实现 `misc/feng-addons/feng-magic-gi/feng_magic_gi_data.gd:1090-1108`（`:1104` 注释即"reduce the remaining light leak"）。
- 该头文件的 include 归属（用于判定"不属于 layout 5"）：`library/magic-gi/magic_gi_apply.glsl:18`、`magic_gi_apply_compact.glsl:21`、`magic_gi_clv_probe_block_field_fill.glsl:34`、`magic_gi_baked_sh_clv_probe_block_field_fill.glsl:11`。

### 4.3 稠密车道的逐角先例（说明"逐角过滤"在本仓库如何实现）

- 逐 8 角循环并跳过 `frp_magic_gi_dynamic_validity.values[cell_index] == 0u`：`magic_gi_dynamic_volume_sample.glslinc:193-216`（`:209`）与 `:270-311`（`:282`），后者还含接收者半球 sidedness 判定 `:299-302`。
- 距离矩可见性：`magic_gi_dynamic_volume_sample.glslinc:167-175`、`:177-191`，调用点 `:304-307`。
- 这两段属于**稠密车道**（`magic_gi_dynamic_volume_cache.gd:11` 的 `LAYOUT_VERSION := 4`），**不是** layout 5。

### 4.4 相关开关的归属（不得混用）

- `native_baked_sh_lighting_enabled`（`:291`）、`approximate_clv_volume_enabled`（`:310`）、`approximate_clv_ready_bit_enabled`（`:313`）、`exact_clv_corner_visibility_enabled`（`:316`）——`misc/feng-addons/feng-render-pipeline/passes/magic_gi_pass.gd:288-325`。
- 后两者只在 layout 9 / layout 14 测试分支被消费：`magic_gi_pass.gd:6389-6405`，并会强制 full features（`:5947-5948`）与回退 legacy（`:7003-7033`）。
- layout 9 缓存常量：`misc/feng-addons/feng-render-pipeline/passes/magic_gi_clv_cache.gd:16`；layout 17 baked-SH：`misc/feng-addons/feng-render-pipeline/passes/magic_gi_baked_sh_clv_cache.gd:8`。
- 因此：**v0 标签实验不得借用 exact/approx 开关**，必须新增独立开关（§10.1）。

### 4.5 bake 端每 cell 字节链（`[现有]`，是标签最自然的挂点）

`misc/feng-addons/feng-magic-gi/feng_magic_gi_clv_transfer_builder.gd`

- `:19` `var _validity := PackedByteArray()`、`:58-59` 分配清零、`:192` `_validity[destination] = 1`、`:84` `_source.clv_prepared_validity = _validity`、`:134` 返回 `{"operators", "validity", "stats"}`。
- 域判定复用点：`:195-231` `_add_constraint()`，其中 `:201`、`:219` 调用 `_geometry.point_is_inside_or_ambiguous_solid()`；`:200-205` 注释明确"用外部探针顶替会重新引入墙角漏光"。
- 采样邻域：`:233` `_gather()`、`:245` 法线朝向过滤。

序列化 / 归档 / 资源侧

- `misc/feng-addons/feng-magic-gi/feng_magic_gi_prepared_transfer_brick.gd:21`（`@export_storage var validity := PackedByteArray()`）、`:64`（字节统计）、`:106`（`if validity[cell] > 1: return false` —— 当前只允许 0/1，扩展语义必须放宽此处）、`:111`。
- `misc/feng-addons/feng-magic-gi/feng_magic_gi_prepared_brick_archive.gd:38`、`:59-66`。
- `misc/feng-addons/feng-magic-gi/feng_magic_gi_volume_source_chunk.gd:53`（`validity`）、`:78`（`clv_prepared_validity`）、`:95`、`:130-132`、`:178`（字节统计）、`:388`。
- **关键约束**：prepared 车道的 GPU 上传只有算子数组——`feng_magic_gi_volume_source_chunk.gd:197-198`（`if has_preinterpolated_clv(): return clv_prepared_operators.size() * 4`）。故任何"运行时可读标签"都需要**新增**上传与绑定。
- 分页：`misc/feng-addons/feng-magic-gi/feng_magic_gi_paged_source_baker.gd:116`、`:176`。
- 边界张量（另一条 bake 端域/边界分类路径）：`misc/feng-addons/feng-magic-gi/feng_magic_gi_boundary_tensor_builder.gd:4-5`、`:13`（`closed_mesh_boundary_tensor_v1`）、`:16`（0.25）、`:367`（solid 节点无可信点采样）、`:1277`（窄缝）。

### 4.6 surface Probe 与 layout 5 cell 的语义差异

工程自述（**仓外路径**，仅作现状佐证）：PRT probe 保持表面锚定（位置 + 法线 + 安全偏移），而 CLV 是**另一套**三维自由空间格（最细 0.25 m），两者不是同一对象集合——`F:\godot\PROJECT\白光盒子测试场景\README.md:7`。本文不依赖该路径：M1/M4 使用的场景与 fixture 必须是仓内或由用户显式指定的工程（§11.1、§12）。因此：

- `subject_kind=probe` 的标签服务表面采样与 legacy 车道；
- `subject_kind=clv_cell` 的标签服务 layout 5；
- **两者不得混在同一列训练数据里当同分布样本。**

### 4.7 现有 vs 提议

| 组件 | 状态 |
| --- | --- |
| layout 5 prepared 缓存 / 采样器 / LOD 混合 | `[现有]` |
| `clv_prepared_validity` 字节链、brick 归档、分页 | `[现有]` |
| gather 候选级可见性拒绝、Chebyshev 距离矩 | `[现有]` |
| domain_class 标签语义、sidecar、审核状态机 | `[提议]` |
| 编辑器 Analyze/Review/Approve/Export 入口 | `[提议]` |
| 离线训练脚本、模型权重、编辑器推理 | `[提议]` |
| layout 5 插值前标签过滤 | `[提议]`，未验证 |
| 任何运行时代码改动 | 本文**不含** |

---

## 5. 产品工作流

### 5.1 主流程（`[提议]`）

1. **布置 Probe / 烘焙配置**：沿用现有 Volume 设置（`use_clv`、`clv_cell_size`、`clv_cache_backend`，`feng_magic_gi_volume.gd:201,210,220`）。
2. **几何分析**：在编辑器内对 scene 做静态几何分析，产出初始 `domain_class`（几何规则，见 §8.2 的 teacher）。
3. **（后续）AI 建议**：v1 起可对几何分析结果叠加模型推理，输出预测 + 置信度/弃权。
4. **overlay 可视化**：在编辑器中按域着色显示 probe / cell，标记 `UNSET` 与低置信。
5. **人工接受 / 修改 / 拒绝**：逐项或批量，记录 reviewer 与时间戳。
6. **复核**：第二人复核或同一人二次确认（状态机见 §7.4）。
7. **保存已批准标签**：写入 sidecar，不覆盖 bake 资源。
8. **导出训练集**：从 gold/silver/pseudo 分层导出（§11.1）。
9. **离线训练**：Python/PyTorch 训练小模型并导出带版本权重（§9.1）。
10. **导入模型到编辑器**：登记模型版本与特征 schema（§9.3）。
11. **编辑器推理**：对当前 scene 建议标签，回到第 4 步进入审核。

### 5.2 追加写与失效规则（`[提议]`）

- **不可变追加**：`dataset.jsonl` 只追加不可变 revision 事件，字段含 `record_id`/`revision`/`supersedes`；任何"生效标签"的变更都产生新 revision，不原地改写旧记录。
- **唯一生效指向**：`manifest.json` 显式记录每 `subject_id` + 哈希组的 `active_revision`，其值为 `record_id@revision`（§7.3）；**只指向 `review_state=approved` 的 revision**。冲突与重复由 manifest 唯一指向解决，**不靠文件尾部顺序或时间戳猜测**。Approve 产生新 revision；历史 gold 保留作审计，但其哈希组与当前不匹配时**不得**作为当前生效标签。
- **二次复核与 gold**：沿用上面的 append-only revision，**不新增冲突状态**。`modified` 只是**待复核的工作/历史态**，**不得**置 `gold_flag`；必须在**再次渲染复核**后创建新的 `approved` revision 才可成为 gold，该 revision 记录 `review_round`、`render_evidence_ref` 与 `confirmed_by`/`confirmed_at`（复核人可与最终批准同人，**不要求双人**）。
- **失效范围**（按来源区分，不搞一刀切）：
  - `geometry` / `probe_layout` / **影响标签的** `bake_config` 哈希变化 → 当前审核 `stale`，需重审；
  - `model_version` 变化 → 仅使 `ai_pred`/`pseudo` 失效，**不**使 human gold 失效；
  - `teacher_version`（几何规则或既有算法版本）变化 → 仅使 silver 失效；
  - `code_version`（读写该 sidecar 的代码版本）变化 → 不自动作废标签，但必须先重放/回归校验，通过后才改写 `active_revision`。

### 5.3 几何边界情形（`[提议]`）

- 非封闭网格、portal/门洞、薄墙、曲面窄缝：几何或审核语义**明确存在歧义**时标 `AMBIGUOUS`，不强行二分类。
- 无生效标签或无法判定：`UNSET`，渲染侧回退**既有几何可见性**（§6.1、§6.3、§10），不得当作 `EXTERIOR`，也不得在像素阶段现场跑 NN。
- 相关现成线索：`feng_magic_gi_boundary_tensor_builder.gd:16`（0.25 对齐）、`:367`、`:1277`；`feng_magic_gi_clv_transfer_builder.gd:200-205`。

---

## 6. 标签契约

### 6.1 主输出：`domain_class`（v0/v1）

建议 `uint8` 编码，取值固定为：

| 值 | 名称 | 含义 | 渲染含义 |
| ---: | --- | --- | --- |
| 0 | `UNSET` | **无生效标签**（未标注、未审核，或弃权后未采纳任何建议） | 回退既有几何可见性；不启用新域拒绝 |
| 1 | `EXTERIOR` | 外部（可视为天空可见域） | 仅作混合许可的**先验**，见 §6.3 |
| 2 | `INTERIOR` | 内部（封闭空间） | 同上；**并非所有 INTERIOR 之间天然可混合** |
| 3 | `AMBIGUOUS` | 几何或审核语义**明确存在歧义**（不是"暂时没想好"） | v0 未获人工有效决定时按 `UNSET` 处理：不启用新域拒绝 |

**弃权（abstain）不是类别**：模型输出的 `ai_abstain`/`ai_confidence` 是独立的推理侧信号，**不占用** `domain_class` 取值。弃权时保留 `UNSET`，或采纳 teacher 建议并**必须**进入人工审核；渲染一律回退既有几何可见性。**禁止**在回退路径上递归调用同一分类器（否则没有终止条件）。

**受监督类别集合只有 `EXTERIOR`/`INTERIOR`/`AMBIGUOUS`**：`UNSET` 是**存储/生效状态**（无生效标签或弃权流程产生），`abstain` 是独立信号，二者都**不**作为分类 logit，也**不**作为交叉熵目标（§8.2、§11.2）。

### 6.2 `region_id` 的定位

`scene-local region_id` 由**可见性连通性 / portal 派生**，用于区分**互不相通的室内区域**（同一建筑中不同房间、portal 两侧）；它只是场景内派生数据（显示、分区审核、连通域统计），**不得**作为全局训练类别；导出时可作为附加字段，但训练主目标只有 `domain_class`。

### 6.3 接收侧与混合许可（v0 硬约束）

`domain_class` 只是**粗粒度先验**：`INTERIOR` 与 `INTERIOR` 之间也可能被墙隔开（互不相通的房间、portal 两侧）。因此域门控必须**可判定**，且结果为三态：

| 门控结果 | 渲染语义 |
| --- | --- |
| `ALLOW` | 放行该候选，但仍**交既有几何可见性**做最终裁决（遮挡/距离矩照旧） |
| `REJECT` | 在**归一化前置零**：该候选不进入加权累加，因而不进入分母 |
| `ABSTAIN` | **完全保持既有可见性**（既不放行也不拒绝；**不是**全拒） |

判定规则（**先拓扑、后类别**）：

1. 双方任一为 `UNSET`/`AMBIGUOUS`，**或** `region_id`/portal 拓扑不可信（缺失、哈希不符、无法判定）→ `ABSTAIN`。
2. 拓扑可信时：
   - 同 `region_id` 且 `domain_class` 一致 → `ALLOW`；
   - 同 `region_id` 但 `domain_class` 不一致 → **标记不一致**并 `ABSTAIN`（交人工审核，不在渲染侧强行裁决）；
   - 异 `region_id`，存在可信 **OPEN** portal 关系 → `ALLOW`（portal 只提供混合许可，最终仍由既有几何可见性/遮挡裁决）；
   - 异 `region_id`，无开放 portal **或**存在可信 **CLOSED** portal → `REJECT`；
   - 关系**未知** → `ABSTAIN`。

portal 的"开放/闭合"是**静态 bake 状态**（随几何/布局哈希固化）；**动态**开关门仍属非目标（§2.2）。本矩阵与 §10.2 的 M4 前置、§12 的 M0 表述绑定：只有该矩阵成立时，"混合许可不再需要决策"才为真。

**接收者 domain/region 的来源与 `UNSET` 策略**：

| 接收者 | domain/region 来源 | `UNSET`/`AMBIGUOUS` 策略 |
| --- | --- | --- |
| v0 gather 合成 fixture | 由测试**显式注入**接收者域，仅验证候选拒绝的归一化数学 | 不适用（fixture 全量注入） |
| M1 静态 surface receiver | bake 时用**同一确定性几何规则**求 domain/region，并与 `geometry`/`probe_layout` 哈希绑定 | 不启用新域拒绝，只走既有可见性 |
| layout 5 自由空间 cell | M4 前必须固定的设计/测试前置（§10.2、§12） | 同上；像素阶段不得现场判定 |

**禁止**：在像素/片元阶段现场运行神经网络判定域。推理只在编辑器/烘焙前（离线）进行，结果以标签 + 哈希固化后随资源发布。

### 6.4 主任务与扩展任务分离

- 主任务：逐 subject 的 `domain_class` 分类（+ 不确定性/弃权）。
- 扩展任务（未来）：可学习的 **Probe 对 / 边混合权重**（即"这两者之间允许多大程度的混合"）。它与 `domain_class` **不是同一个目标**，必须独立 schema、独立模型头、独立评估，不得混进同一列标签。

### 6.5 `subject_kind`

固定枚举：`probe`（surface Probe）、`clv_cell`（layout 5 自由空间 cell）。每条记录必须且只能属于一种。

**v1 的每个模型契约只允许一种 `subject_kind`，首选 `probe`**：`clv_cell` 使用**独立的特征 schema 与独立模型**（或完全由几何规则派生），**不与 probe 混训**。特征注册与模型注册条目均必须含 `subject_kind` 字段；跨 `subject_kind` 合并训练只能作为未来独立实验，不得默认开启（示例见 §7.3 的说明）。

### 6.6 运行时紧凑标签 vs 训练 sidecar

- 运行时：每 subject 的紧凑标签（文章所称的"约 1 byte/Probe"量级的紧凑表示，**仅为形态参考**），只用于渲染决策。
- 训练：sidecar 携带完整审核元数据与特征引用；其体积与 1 byte **无关**，不得用紧凑表示反推数据集规模。

---

## 7. 编辑器入口与 sidecar 设计

### 7.1 入口（全部为 `[提议]`）

| 入口 | 作用 | 说明 |
| --- | --- | --- |
| Analyze | 几何分析 +（v1）模型推理，产出建议标签 | 不写 bake 资源 |
| Review | overlay 审核：并列显示 `ai_pred`/`confidence`、`teacher_label`、`human_label` | 未审核 AI 标签不得进入 gold |
| Approve | 把审核结果固化为 `final_label` 并置 `gold_flag` | 记录 reviewer/时间戳 |
| Export | 按分层导出训练集 | 输出去向由用户指定 |

现有可复用表面（只读参考）：`misc/feng-addons/feng-magic-gi/editor/magic_gi_inspector_plugin.gd`（Inspector 状态文本与运行时状态读取，例如 `:290-302`）、`misc/feng-addons/feng-magic-gi/feng_magic_gi_volume.gd:295`（CLV cell 可视化开关）与 `feng_magic_gi_volume.gd:283-292`（probe/SH 显示开关）。

### 7.2 目录布局（`[提议]`）

与 bake 产物分离，避免覆盖现有资源（现有 bake 输出约定见 `misc/feng-addons/feng-magic-gi/README.md:72`）：

```
res://magicgi_review/<scene_and_volume_id>/
  dataset.jsonl                 # 不可变 revision 事件（追加写，§5.2）
  manifest.json                 # 每 subject + 哈希组的 active_revision = record_id@revision（§5.2、§7.3）
  features/<subject_kind>.bin   # 原始特征；offset/len 单位为 byte
  reviewer_notes.md             # 人工说明
  model/<model_version>.json    # 模型登记（含 subject_kind、版本、schema、哈希）
res://magicgi_review/export/<scene_and_volume_id>/<split>.jsonl
```

`scene_and_volume_id` 沿用现有 bake 目录命名习惯（`misc/feng-addons/feng-magic-gi/README.md:72`），**同一 scene 的多个 Volume 不得混入同一档案**；记录内同时保留 `scene_id` 与 `volume_id`（§7.3）。

### 7.3 记录 schema（示例，非最终字段名表）

```json
{
  "schema": "magicgi.domain_label.v0",
  "schema_version": 1,
  "feature_version": 1,
  "label_version": 1,
  "code_version": "magicgi-domain-review@0",
  "model_version": "mlp-domain-probe-v1",
  "scene_id": "box_test",
  "volume_id": "MagicGIVolume",
  "subject_kind": "clv_cell",
  "subject_id": "clv:l0:12,7,3",
  "hashes": {
    "hash_scheme": "sha256-canonical-v1",
    "geometry": "<sha256>",
    "probe_layout": "<sha256>",
    "bake_config": "<sha256>"
  },
  "record_id": "6f1c2a90",
  "revision": 3,
  "supersedes": "6f1c2a90@2",
  "features": {"ref": "features/clv_cell.bin", "offset": 0, "len": 256, "unit": "byte", "recomputable": true},
  "teacher_version": "geom-teacher-v1",
  "teacher_label": 2,
  "ai_pred": 2,
  "ai_confidence": 0.41,
  "ai_abstain": false,
  "human_label": 2,
  "final_label": 2,
  "source": "human",
  "review_state": "approved",
  "gold_flag": true,
  "review_round": 2,
  "render_evidence_ref": "captures/<scene>_<camera>_<config>.json",
  "confirmed_by": "<id>",
  "confirmed_at": "<iso8601>",
  "reviewer": "<id>",
  "timestamp": "<iso8601>"
}
```

> 上例用 `clv_cell` **只为展示 schema 形状**；v1 的训练契约首选 `probe`，`clv_cell` 走独立模型/schema（§6.5）。

要求：

- **版本字段必须逐项出现在每条记录中**（不能只写在本文的要求段）：`feature_version`、`label_version`、`code_version`、`model_version`、`schema_version`，或语义等价的独立字段。
- **规范哈希 `sha256-canonical-v1`**：对固定字段集按稳定排序、带字段名与长度前缀拼接后取 SHA-256；浮点按 IEEE-754 **float32 位型**、显式小端字节序序列化。v0 只对**明确序列化值**求哈希（不做量化/取整）；未来若改为量化表示，必须同时提升 `feature_version` 与哈希方案版本，否则视为不同标签。
  - `geometry`：网格内容、世界变换、以及影响标签的材质信息。
  - `probe_layout`：`subject_kind`、稳定 ID、位置、法线、密度/间距参数。
  - `bake_config`：**仅**包含影响标签的配置项；其它渲染/性能项不得进入该哈希。
- **稳定 ID 与空值规则**：`subject_id` 必须能由 `subject_kind` + 布局参数确定性重建（probe：布局序号/格坐标；clv_cell：LOD + 格坐标）。哈希组任一字段缺失或不可计算时，记录必须写 `null` 并把 `review_state` 置 `stale`，**不得**用空串或 `0` 冒充。
- `scene_id` 与 `volume_id` 必须同时存在，且与 §7.2 的目录命名一致；`features` 的 `offset`/`len` 单位为 **byte**。
- **revision 身份 = `record_id@revision`**：`supersedes` 指向**同一 `record_id`** 的前一 revision（如 `6f1c2a90@2`）；`manifest.json` 的 `active_revision` 也使用这一对，且**只指向 `approved`**（§5.2）。
- **二次复核字段**：`review_round`（该 subject 的第几轮渲染复核）、`render_evidence_ref`（复核所用渲染/相机/场景配置引用）、`confirmed_by`/`confirmed_at`（复核确认，可与最终批准同人，不要求双人）。只有这些字段齐备且 `review_state=approved` 的 revision 才可置 `gold_flag`。

### 7.4 分层与状态机

| 层 | 产生方式 | 用途 |
| --- | --- | --- |
| gold | 人工批准/修正 | 唯一高可信真值 |
| silver | teacher（几何规则或既有算法） | 预训练/对照，权重低于 gold |
| pseudo | 模型未审核预测 | 隔离存放，**绝不进 gold**，是否参与训练由实验决定 |

`review_state ∈ {pending, approved, modified, rejected, stale}`；`stale` 由 §5.2 的哈希变化触发。**当前生效标签由 `manifest.json` 的 `active_revision`（`record_id@revision`）唯一决定，且只指向 `approved`**（§5.2）：只有 `review_state=approved`、`review_round`/`render_evidence_ref`/`confirmed_by`/`confirmed_at` 齐备、且哈希组与当前 human 批准 revision 匹配的条目才构成 gold 真值；`modified` 属待复核工作态，**不得**带 `gold_flag`；历史 revision 仅作审计。

---

## 8. 模型决策

### 8.1 候选比较

| 方案 | 优势 | 代价/风险 | v1 定位 |
| --- | --- | --- | --- |
| 几何规则 | 可解释、零训练、可复现 | 覆盖有限，边界/portal 易错 | teacher + 回退（既有几何可见性） |
| MLP（固定局部特征） | 训练/部署最简单，编辑器易前向 | 表达能力有限，需要手工特征 | **v1 基线** |
| DeepSets / GraphSAGE | 天然处理无序射线/邻居集合与 probe 图 | 特征构建与图构建成本高 | M3 备选 |
| Transformer | 长程、变长全局关系 | 数据/算力/部署成本高；注意力 K 邻居约 O(K²) | v1 明确不用，M3 后按需评估 |

### 8.2 v1 基线（可调起点，非事实）

- 输入：固定局部几何特征（到最近几何/墙体的距离与方向、射线命中模式统计、法线一致性、所在 cell 与邻近 cell 的占用状态等；**不移动 probe**）。
- 结构：**2 层、约 128 隐藏单元**的 MLP。
- 输出：`domain_class` 分布 + **独立**的不确定性/弃权信号（`ai_abstain`/`ai_confidence`，**不是**第 5 个类别）；弃权时保留 `UNSET`，渲染回退既有几何可见性（§6.1、§6.3）。
- 损失：加权交叉熵，**受监督类别只有 `EXTERIOR`/`INTERIOR`/`AMBIGUOUS`**；`UNSET` **不是** logit，也**不是** CE 目标（它表示"无生效标签"，由无标注或弃权流程产生）；`abstain` 仍是独立信号（§6.1）。类别不平衡在三个受监督类别内处理；人工 gold 权重最高。
- 每个模型契约只服务一种 `subject_kind`（§6.5）：v1 首选 `probe`。
- 上述规模是**可调起点**；本文不给出所需样本数、训练时长或成功率。

### 8.3 Transformer 的进入条件

仅当满足以下全部条件时才评估：长程/变长全局关系被实验证明是主要误差来源；gold 数据与算力足以支撑；编辑器侧推理预算可接受。否则不引入。

---

## 9. 训练与推理部署

### 9.1 离线训练（`[提议]`，非现有依赖）

- 建议后续用 Python/PyTorch 训练小 MLP，导出**带版本**的权重与特征 schema。
- 训练真值：仅 **human gold** 作为高可信真值；silver/pseudo 分层使用并单独记录其影响。
- 必须保留**未见场景**的 gold 测试集（§11.1）。
- 本仓库现有 Python 测试脚本的组织方式可作参考（`misc/scripts/test_magic_gi.py:18-33`、`:89-99`），但**本文不新增依赖、不改脚本**。

### 9.2 编辑器推理（`[提议]`）

- Godot 编辑器侧做轻量前向（小 MLP 直接前向即可），**v1 避免引入 ONNX 运行时**。
- 推理结果只作为建议写入 sidecar（`source=ai`、`review_state=pending`），必须经人工批准才成为 gold。

### 9.3 版本化与重跑触发

特征定义、模型结构/权重、schema 任一变化：必须提升 `feature_version` / `label_version` / `model_version` / `schema_version`（或语义等价字段），并重跑渲染回归（§10.4、§11.3）；失效范围按 §5.2 分来源处理。旧 sidecar 不得被静默重解释。

---

## 10. 渲染接入

### 10.1 v0 正确性实验：在 gather 候选累加前拒绝（`[提议]`）

- 位置：`misc/feng-addons/feng-render-pipeline/library/magic-gi/magic_gi_gather.glslinc:459-460`（候选可见性计算后、加权累加前）；同文件 `:534` 为另一处累加点。
- 规则：候选 domain 与接收者 domain 不兼容 → 不进入加权累加，因而**不进入归一化分母**（与 `misc/feng-addons/feng-magic-gi/README.md:112`"被遮挡候选不参与归一化"同构）。
- 开关：**新增独立开关**（在 `magic_gi_pass.gd:288-325` 的导出一族中新增，默认关闭）。**不得**复用 `approximate_clv_volume_enabled`（`:310`）或 `exact_clv_corner_visibility_enabled`（`:316`），它们属于 layout 9/14 生产分支（`:6389-6405`）。
- **v0 边界（不夸大）**：本实验只验证三件事——域标签的**接线**、跨域候选被拒后的**归一化数学**（被拒候选不进入分母）、以及开关关闭时的**无回归**。它**不**声称修复 layout 5 的跨域混合，也不作为漏光验收。
- **新增可判别合成 fixture**：仓内 fixture，含**已知接收者域**、**两个异域候选**与**可手工计算的权重**，使期望输出可解析求出；配套**新增 gather 专用测试**。现有 `test_magic_gi_clv_sampling.gd` 只能作**风格参考**，不构成 gather 车道的既有覆盖（§10.4）。

### 10.2 layout 5：只能在插值前处理（`[提议]`，均未验证）

| 方案 | 做法 | 已知代价/风险 | 状态 |
| --- | --- | --- | --- |
| 显式 8 角过滤 | 把 `magic_gi_dynamic_volume_sample.glslinc:339-354` 的 7 次硬件采样换成逐角取值、按 domain 跳过、以接受权重重新归一化 | 约 56 次取值/LOD（**未测**）；**全拒**路径的 LOD 回退语义需 M4 先固定（现有 `:385-393` 只做相邻 LOD 混合，**未定义**"全拒"） | 未验证 |
| 分域纹理 | 按域分纹理，接收者只采自身域的纹理 | 内存与绑定翻倍；资源生命周期复杂 | 未验证 |
| nearest / UV 吸附 | 关闭插值或把 UV 吸附到 cell 中心 | 出现接缝/块状 | 未验证 |

可参考的逐角实现先例（不同车道）：`magic_gi_dynamic_volume_sample.glslinc:193-216`（`:209` 跳过无效角）、`:270-311`（`:282`、`:299-302`）。

**M4 设计前置（未固定前不得开工）**：① layout 5 接收者与细胞的 domain/region 从何而来、何时固化；② "全拒"的判定与全拒时的 LOD 回退语义；③ 与 §6.3 **三态门控矩阵（ALLOW/REJECT/ABSTAIN）** 的一致性——含 portal 开放/闭合的静态判定如何进入哈希，以及 `ABSTAIN` 分支如何保证"完全保持既有可见性"。

**新增可复现混合 fixture**：构造已知 cell 域分布的 mini 场景，断言 (a) post-gate 无法消除已混入的跨域能量（证明 post-filter 不充分）、(b) 全拒与 LOD 回退符合 ① 的固定语义。该 fixture 与 §10.1 的 gather fixture **分开**，结论不得互相冒充。

### 10.3 为什么 post-filter 不充分

`magic_gi_dynamic_volume_sample.glslinc:339-354` 的硬件三线性输出为 Σwᵢcᵢ；若角 i 属异域，其 cᵢ 错误，而 wᵢ 在采样后不可得。`:355-358` 的 `coverage > 0.5` 只能整段接受/拒绝，**无法解混**。因此"在 layout 5 采样返回值上按域拒绝"不是充分方案；插值前处理或分域采样才是。

### 10.4 验证用例（`[现有]` 测试，本文**未执行**）

- 采样/混合与 LOD：`misc/feng-addons/feng-render-pipeline/tests/test_preinterpolated_clv_sky_ownership.gd:35-49`（编译生产 sampler）、`:145-146`、`:164-168`（调用 `frp_magic_gi_dynamic_volume_sample`）。
- 拒绝语义**风格**参考（**不是** gather 覆盖）：`misc/feng-addons/feng-render-pipeline/tests/test_magic_gi_clv_sampling.gd:1266`（zero CLV coverage）、`:1416`（exactly-zero-weight corner）。
- 支持/认证语义：`misc/feng-addons/feng-render-pipeline/tests/test_magic_gi_clv_visibility_support.gd:74`、`:113`。
- 序列化往返：`misc/feng-addons/feng-magic-gi/tests/test_source_archive.gd:33-40`、`misc/feng-addons/feng-magic-gi/tests/test_prepared_brick_archive.gd:35-45`。
- 烘焙集成：`misc/feng-addons/feng-magic-gi/tests/test_volume_free_space_bake_integration.gd:2`、`:78`。
- 无 GPU 的 CPU 契约：`misc/feng-addons/feng-render-pipeline/tests/test_paged_clv_layout.gd:2-3`、`:153`。
- 高成本真实工程验收（1920×1080、真实场景）：`misc/feng-addons/feng-render-pipeline/tests/test_magicdawn_clv_prt_contract.gd:5-12`。

---

## 11. 数据集与验收

### 11.1 划分

- 按 **scene / level** 划分 train/val/test；**不得**把同一场景的 probe/cell 随机拆到不同集合。
- **M1 必须至少建立两个场景**：一个开发场景 + 一个**独立留出的验收场景**（几何不同）；只有开发场景不足以进入 M2。
- **M2 入口条件**：能按 scene 形成 train/val/test 三个**互不相交**集合；数量不足时先补场景。允许先以**流程冒烟**方式跑通全链路，但不得声称统计泛化。
- 另留"未见几何类型"集合（例如某类门洞/薄墙）只出现在 test。
- 记录每个 split 的 scene 列表与哈希，随数据集版本一起归档。

### 11.2 指标（不设无依据阈值）

- 分类侧**分别报告**：① 三分类（`EXTERIOR`/`INTERIOR`/`AMBIGUOUS`）各类 precision/recall 与混淆矩阵；② 缺标注覆盖率（`UNSET` 占比，**不并入分类指标**）；③ 弃权率（`abstain`）；④ 按场景分组的方差。
- 渲染侧（工具与口径在 §11.3 的观测量中固定）：可见漏光、局部过黑、门洞/薄墙传光、relight 稳定性（光照变化后是否跳变），以及 GPU 时间、显存/内存增量与烘焙成本变化。
- **阈值待测量后确定**；本文不给数值、不构成性能承诺。

### 11.3 测试清单（`[提议]` 新增 + `[现有]` 基础）

| 类型 | 内容 | 基础 |
| --- | --- | --- |
| 单元 | 标签枚举编解码、哈希失效、状态机迁移 | 新增 |
| 序列化 | sidecar 往返字节一致、schema 版本拒绝 | 参考 `test_source_archive.gd:33-40` |
| 审核状态 | 未审核 AI 标签不得置 gold；stale 阻断导出 | 新增 |
| 数据集污染防护 | 同场景跨 split 检测；pseudo 混入 gold 检测 | 新增 |
| GPU gather（**新增**） | 合成 fixture：已知接收者域 + 两个异域候选 + 手工可算权重；断言被拒候选**不进入归一化分母**，且开关关闭时无回归 | 风格参考 `test_magic_gi_clv_sampling.gd:1266`（**非**既有 gather 覆盖） |
| layout 5 混合（**新增**） | 可复现混合 fixture：证明 post-gate 不充分；全拒与 LOD 回退按 §10.2 固定语义 | 参考 `test_preinterpolated_clv_sky_ownership.gd:35-49` |
| 渲染观测量（**新增**） | 漏光/过黑/门洞传光/relight 稳定，以及 GPU 时间与内存的观测记录 | 新增 |

---

## 12. 分阶段里程碑

| 阶段 | 入口条件 | 交付物 | 退出标准 |
| --- | --- | --- | --- |
| **M0** 文档 | 本文评审通过 | 本文件 | 标签语义、数据归属、模型基线、审核闭环与**混合许可（§6.3）**不再需要新决策——该表述**仅当 §6.3 三态门控矩阵（含 portal 静态开放/闭合判定）成立时为真** |
| **M1** 几何 + 审核 + 导出（无 NN） | M0 冻结 | 几何 teacher、overlay 审核入口、sidecar 与 manifest、状态机、**开发场景 + 独立留出验收场景** | 在开发场景完成"分析→审核→批准→导出"，gold 可追溯且哈希绑定；无运行时代码改动 |
| **M2** MLP 训练 / 导入 / 推理 | M1 交付，且能按 scene 形成 train/val/test **三个互不相交集合**（不足先补场景） | Python 训练脚本、带版本权重、编辑器前向、pseudo 隔离、含 `subject_kind` 的模型登记 | 在未见场景 gold 上可复现评估（允许先流程冒烟，不声称泛化）；弃权时回退既有可见性生效 |
| **M3** 按需图模型 | M2 误差分析证明局部特征不足 | DeepSets/GraphSAGE 实验结论（含是否评估 Transformer） | 结论有数据支撑，或明确不做 |
| **M4** layout 5 优化 | M2/M3 标签质量稳定，且 §10.2 的三项设计前置已固定 | 基于**仓内 fixture** 的方案实测对比与开关化实现（不依赖仓外路径） | 关闭开关时回归一致；跨域混合按 §10.2 固定语义消除，且成本已测 |

---

## 13. 风险与开放问题

- 域标签不能修复错误的 probe 布局；布局变化须重审（§5.2）。
- v0 对 `UNSET`/`AMBIGUOUS` **一律不启用新域拒绝**，因此不会因标签缺失而改变现有画面；代价是 v0 也不可能"修好"layout 5（§10.1）。
- 多室内域场景中 `region_id` 的派生质量决定混合许可质量（§6.2、§6.3）：连通性判错会表现为跨房间传光。
- layout 5 插值前方案的成本（取址次数、内存、绑定）尚未测量（§10.2）；"全拒"语义尚未定义。
- silver/pseudo 的权重策略会显著影响结果，需实验隔离。
- 人工审核成本与一致性（多人标注一致性）尚无数据。
- 动态几何、透明表面、地形细节不在本文范围（现状限制见 `misc/feng-addons/feng-magic-gi/README.md:114`）。

---

## 14. 引用

- 公开文章（OLV 名称/用途）：<https://zhuanlan.zhihu.com/p/2020903414117201233>。**该文及转载中的任何量化指标均为文章自报，本文未独立核实其账号官方性，也未复现。**
- GDC 2026 公开演讲 PDF（CLV PRT"预插值传输 → CLV block relight → 硬件插值"流程）：<https://media.gdcvault.com/gdc2026/Slides/Sheng_Feng_IlluminatingRocosLegacyScalableGlobalIlluminationfromTheorytoPractice.pdf>。项目自述对该流程的参考关系见 `misc/feng-addons/feng-magic-gi/README.md:82`。
- 仓库内证据：本文 `path:line` 默认相对仓库根 `F:\godot\feng-godot`；唯一**仓外**引用已在 §4.6 显式标注为仓外。
- 文档约定先例：`doc/frp-source-audit-20261007.md:1`、`:7`（H1 与 **Evidence scope** 体例）。
