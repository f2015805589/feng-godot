# Magic GI OLV-like 一键漏光修正：可执行实施计划

> **状态：待执行；本次仅修订计划，不代表功能已经实现。**
>
> **代码基线：** `c75f67546bfd8bba2fac4964c51eddbbf046d45d`（2026-10-26 核查）。
>
> **最终目标：**模型训练完成后，在 `FMagicGIVolume` 上按一次“AI 漏光修正（OLV）”，完成校验、室内外域推理、标签应用、缓存刷新，并支持 A/B 与撤销。
>
> **证据边界：**用户提供的 MagicDawn 原文 3.1–3.4 将 OLV 描述为“基于神经网络优化 Probe 可见性标签，自动划分室内/外区域”。本文据此确定问题形态，不推测其未公开的网络、接收者域映射或训练实现。原文中的修复率、耗时和包体指标均未在本项目复现，不作为本计划验收承诺。

---

## 0. 先澄清：OLV 不是 Probe 位置回归

美术在 PRT/Probe GI 中处理漏光，可能做两类不同工作：

1. **调整采样位置或密度**：移动 Probe、设置安全偏移、局部加密，解决采样点落入几何、锚点不合理或采样不足。
2. **标记可见性/可混合域**：用 Volume、Tag 或遮挡区区分室内外，避免插值把墙另一侧的结果混进来。

本计划中的 **OLV 主路线自动化的是第二类**，网络输出是可见性域标签，不是 Probe 坐标。移动 Probe 有时确实能减少漏光，但不能单独保证解决硬件三线性造成的跨域混合；反之，位置完全合理的 Probe 也仍可能需要可见性标签。

### 0.1 按根因选择路线

| 主要根因/场景 | 应采用路线 | 是否属于本 OLV v1 |
| --- | --- | --- |
| Probe 落入实体、安全偏移不合理、局部采样不足 | 几何约束的 placement / relocation / adaptive density | 否；保留为独立位置优化路线 |
| 开放世界或建筑室内外分界明显，跨室内外插值漏光 | **OLV 室内外可见性标签 + 插值前门控** | **是，主线** |
| 多个室内房间互相漏光；所有房间都可能同为 `INTERIOR` | **Depth / 混合可见性方案** | 否；不得用室内外二分类冒充已解决 |
| 错误 TransferMatrix、错误材质/几何、SH 截断、动态门 | 修复对应数据或重新 Bake | 否 |
| 已经把多个角点混合后的最终颜色 | post-filter 无法可靠“解混” | 必须改插值前流程 |

用户提供的原文也把 OLV 的适用场景限定为“开放世界、室内室外分界明显”，并指出传统标注/Tag 难以处理多个室内房间，把 Depth 作为另一套方案。因此本计划**收窄此前 region/portal 扩展，不再把它当作 OLV v1 的默认交付**。

### 0.2 推荐执行顺序

```text
P0 冻结 OLV 标签与渲染契约
  → P1 无 AI 的 layout 7/8 插值前垂直切片
  → P2 无 AI 的室内外真实场景端到端闭环
  → P3 数据集、标签训练与编辑器推理
  → P4 一键 AI 漏光修正（OLV）
  → P5 未见场景、性能与发布验收
```

数据场景准备和人工标注可与 P2 并行；**不要在 P1 之前把主要成本投入模型训练**。位置优化与 Depth 可独立评估，但不阻塞边界清晰的 OLV v1。

### 0.3 已确定的实施决策

| 决策项 | 本计划采用的方向 | 原因 |
| --- | --- | --- |
| 网络输出 | `EXTERIOR / INTERIOR / AMBIGUOUS` 标签与独立弃权信号 | 对齐 OLV 的可见性标签问题；不是坐标输出 |
| 首要学习对象 | `clv_cell` | 当前默认 prepared 路径实际插值的是自由空间 cell |
| 首要渲染目标 | 新 Bake 默认优先 **layout 7**；**layout 8** 做兼容回归 | 当前 prepared SH2 使用这两个布局，不再是旧 layout 5 |
| 渲染接入点 | **插值前**逐角裁决 | 硬件混合后的 post-filter 无法恢复各角点贡献 |
| 训练位置 | 离线 Python/PyTorch | 编辑器按钮不现场训练 |
| 推理位置 | Godot 编辑器内、按按钮批量执行 | 本自研 v1 不在每帧像素阶段运行神经网络 |
| 运行时动态适配 | 根据 shading point 查询已固化的标签/接收者域；未知时回退 | 支持移动时的域选择，但不猜测腾讯的运行时实现 |
| v1 模型 | 固定局部几何特征 + 小 MLP；暂不使用 Transformer | 部署和数值一致性验证最简单 |
| 运行时输入 | 独立、版本化、带哈希的标签 payload | 不直接读取审核 JSONL；不复用 `validity` 冒充 domain |
| 低置信/未知接收者域 | `ABSTAIN`，保持旧路径 | 不把缺失标签强行当成室内或室外 |
| AI 自动应用与 gold | 分离 | 一键应用不阻塞产品流程；只有人工复核样本进入高可信训练集 |
| 发布策略 | 独立开关，先默认关闭，验收后按 Volume 开放 | 保证旧资源与旧画面可回归 |

---

## 1. 当前代码事实与方案差距

### 1.1 当前生产路径

| 事实 | 代码证据 | 对计划的影响 |
| --- | --- | --- |
| Volume 默认 `use_clv=true`、backend 1、0.25 m | [feng_magic_gi_volume.gd:201–227](../misc/feng-addons/feng-magic-gi/feng_magic_gi_volume.gd#L201-L227) | 目标是 MagicDawn prepared CLV，不是旧 surface Probe 查询 |
| 新 backend-1 Bake 走 free-space source，并发布 prepared manifest | [feng_magic_gi_volume.gd:863–879](../misc/feng-addons/feng-magic-gi/feng_magic_gi_volume.gd#L863-L879)、[feng_magic_gi_volume.gd:930–1018](../misc/feng-addons/feng-magic-gi/feng_magic_gi_volume.gd#L930-L1018) | 新默认链路优先按分页 layout 7 验证 |
| 整块 prepared cache 是 layout 8、schema 2、4 个响应字段 | [magic_gi_preinterpolated_volume_cache.gd:6–22](../misc/feng-addons/feng-render-pipeline/passes/magic_gi_preinterpolated_volume_cache.gd#L6-L22)、[magic_gi_preinterpolated_volume_cache.gd:64–99](../misc/feng-addons/feng-render-pipeline/passes/magic_gi_preinterpolated_volume_cache.gd#L64-L99) | layout 8 需要上传与采样回归 |
| 分页 prepared cache 是 layout 7、schema 2、4 个响应字段 | [magic_gi_paged_prepared_volume_cache.gd:1–8](../misc/feng-addons/feng-render-pipeline/passes/magic_gi_paged_prepared_volume_cache.gd#L1-L8)、[magic_gi_paged_prepared_volume_cache.gd:27–76](../misc/feng-addons/feng-render-pipeline/passes/magic_gi_paged_prepared_volume_cache.gd#L27-L76) | 分页 resident、halo 和滚动上传是必测项 |
| 当前 sampler 只接受 7/8，每 LOD 读取 4 个硬件三线性字段，并处理相邻 LOD 混合 | [magic_gi_dynamic_volume_sample.glslinc:323–401](../misc/feng-addons/feng-render-pipeline/library/magic-gi/magic_gi_dynamic_volume_sample.glslinc#L323-L401) | OLV 标签必须作用于这四个字段的角点来源 |
| SH2 解码使用 filtered coverage 归一化 | [magic_gi_sh4_tensor.glslinc:34–55](../misc/feng-addons/feng-render-pipeline/library/magic-gi/magic_gi_sh4_tensor.glslinc#L34-L55) | 删角后必须分别定义传输归一化与 support/coverage |
| prepared `validity` 只表示支持/有效算子；校验只接受 0/1 | [feng_magic_gi_clv_transfer_builder.gd:194–230](../misc/feng-addons/feng-magic-gi/feng_magic_gi_clv_transfer_builder.gd#L194-L230)、[feng_magic_gi_prepared_transfer_brick.gd:114–128](../misc/feng-addons/feng-magic-gi/feng_magic_gi_prepared_transfer_brick.gd#L114-L128) | OLV domain 使用独立数据；缺标签不得把有效 cell 变成 invalid |
| free-space source 已有受限安全 relocation；状态 2 保存实际偏移 | [feng_magic_gi_volume_source_baker.gd:430–474](../misc/feng-addons/feng-magic-gi/feng_magic_gi_volume_source_baker.gd#L430-L474)、[feng_magic_gi_volume_source_chunk.gd:39–56](../misc/feng-addons/feng-magic-gi/feng_magic_gi_volume_source_chunk.gd#L39-L56) | 位置修正已有基础，但它不是 OLV 标签，也不是任意移动运行时 cell |
| source 的 Transfer/距离矩从实际 relocation 后的位置积分 | [feng_magic_gi_volume_source_baker.gd:481–529](../misc/feng-addons/feng-magic-gi/feng_magic_gi_volume_source_baker.gd#L481-L529)、[feng_magic_gi_volume_source_chunk.gd:63–71](../misc/feng-addons/feng-magic-gi/feng_magic_gi_volume_source_chunk.gd#L63-L71) | 改变位置后不能只改坐标；必须维护或重算相关传输数据 |
| layout 7 按全局 `level:x:y:z` 合并 resident 样本与 halo | [magic_gi_paged_prepared_volume_cache.gd:118–174](../misc/feng-addons/feng-render-pipeline/passes/magic_gi_paged_prepared_volume_cache.gd#L118-L174) | 标签身份使用 LOD + 全局格坐标，不能用 brick-local index |
| 原生采样绑定没有 OLV domain/receiver-domain 数据 | [render_frp_clustered.cpp:5818–5858](../servers/rendering/renderer_rd/frp_clustered/render_frp_clustered.cpp#L5818-L5858) | 需要新增显式 ABI、上传和生命周期 |

### 1.2 位置、OLV 与 Depth 在当前项目中的边界

- 现有 relocation 是 **Bake 期 source 采样点安全偏移**，不是神经网络位置优化，也不是室内外标签。
- 当前 prepared cell 是 cell-aligned 的几何约束线性算子；随意移动运行时 cell 会破坏布局与算子语义，不属于 OLV v1。
- source 中保存距离矩不等于默认 prepared 像素路径已经执行 Depth 防漏光；OLV 与 Depth 的上传、绑定和采样应分别验证。
- legacy/gather 的候选过滤可以作为数学参考，但不是默认 prepared 的后处理；仅在 gather 中接入标签不能宣称修复当前默认路径。

### 1.3 当前没有交付的 OLV 部分

以下均是**待实现**：

- `domain_class` 标签、接收者域映射及其版本化资源；
- 标签审核、自动应用批次、训练集导出与哈希失效；
- 训练脚本、模型权重、模型登记、编辑器 MLP 推理；
- layout 7/8 的插值前门控、原生绑定和完整回归；
- “AI 漏光修正（OLV）”按钮、A/B、撤销和验收数据。

多房间 Depth/混合方案与神经网络位置优化不是 OLV v1 的隐含交付，见 §6。

---

## 2. 目标与非目标

### 2.1 OLV v1 产品目标

针对**静态几何、有效 PRT Bake、室内外分界较明确、可信标签与接收者域**条件下的跨室内外 CLV 插值漏光：

1. 用可审核、可学习的数据描述 cell 与接收者的室内外可见性域。
2. 在编辑器内一键推理并应用可信标签，不改变 Probe/Cell 坐标。
3. 在 prepared CLV 插值前按域裁决角点，并明确 support、coverage 和 LOD 语义。
4. 保留实时方向光、天空和已支持发光源的 relight 能力。
5. 旧路径始终可回退；修正结果可比较、可撤销、可复现。

### 2.2 OLV v1 非目标

- 不承诺消除所有漏光，特别是不承诺解决多个室内房间的互相漏光。
- 不回归 Probe 位置、密度或安全偏移，不修复错误布点或错误 TransferMatrix。
- 不把现有 source relocation 改写成 OLV，也不随意移动 prepared runtime cell。
- 不恢复 SH2 已丢弃的 L2 方向细节，不增加镜面传输。
- 不支持动态门、动态几何或透明表面语义；变化后按现有规则重新 Bake/分析。
- 不在游戏运行时训练或执行神经网络；运行时只做轻量数据查询与渲染门控。
- 不把 gather-only 实验当作 layout 7/8 修复证据。
- 不采用原文自报的 99%、0.1 ms 或总包体 `Probe 数 × 1 byte` 作为本项目未经验收的承诺。

---

## 3. 最终“一键”产品契约

### 3.1 按钮前置条件

按钮位于当前 Volume 的 Inspector；现有入口可复用 [magic_gi_inspector_plugin.gd:12–48](../misc/feng-addons/feng-magic-gi/editor/magic_gi_inspector_plugin.gd#L12-L48)，直接绑定被检查的 Volume，不查找场景中的“第一个 Volume”。

点击后先检查：

- 场景已保存；scene identity 与 Volume scene-relative path 可稳定重建。现有身份辅助见 [feng_magic_gi_scene_tracker.gd:19–45](../misc/feng-addons/feng-magic-gi/feng_magic_gi_scene_tracker.gd#L19-L45)。
- 当前为受支持的 PRT prepared 路径，存在有效 Bake；Surfel 模式不显示或禁用此按钮。
- 模型、`subject_kind`、特征 schema、标签 schema 与 OLV 室内外任务匹配。
- geometry、cell layout、影响标签的 bake config 哈希匹配。
- cell 标签与接收者域映射可用；仅模型置信度高但接收者域未知时仍不得自动修正。

任一条件失败：不修改现有 Bake/runtime payload，明确显示原因，不显示“修正成功”。

### 3.2 一次按钮执行的事务

```text
Preflight
→ 提取/复用当前 clv_cell 几何特征
→ 编辑器内批量 MLP 推理室内外域
→ 生成独立 auto-apply correction batch
→ 高置信且接收者域映射可信的标签进入 runtime payload
→ 低置信、UNSET、AMBIGUOUS 或未知接收者域保持 ABSTAIN
→ 校验 payload 与哈希
→ 上传并刷新受影响缓存
→ 原生采样 A/B 验证
→ 报告修正数、跳过数、失败数与性能
```

执行应可取消；失败时保留上一代有效 payload。按钮不重写原始 TransferMatrix，不改变 Probe/Cell 坐标，也不把 sidecar 操作伪造成场景资源修改。

**运行时移动适配：**标签由编辑器离线固化；shading point 变化时只查询接收者域并执行渲染门控，不重新训练或逐帧运行 MLP。该设计是本项目的部署选择，不是对腾讯 OLV 私有实现的推断。

### 3.3 用户可见结果

- `Applied`：实际进入 runtime payload 的 cell 数；
- `Abstained`：低置信、接收者域未知或数据缺失的数量与原因；
- `Stale/Rejected`：哈希、schema、模型或资源不匹配数量；
- `A/B`：旧路径与 OLV 修正路径对比；
- `Undo`：恢复上一代 runtime payload，不重新训练、不破坏原 Bake。

### 3.4 自动应用与训练真值分离

- AI 自动应用记录为 correction batch/pseudo 应用历史，**不得自动标记为 human gold**。
- 人工 Review 是低置信处理和数据生产入口，不阻塞高置信的一键流程。
- 只有带人工审核、渲染证据和确认信息的 approved revision 才能进入 gold。
- 更换模型只使相关 AI 建议/自动应用批次失效，不删除既有 human gold。

---

## 4. 必须先冻结的 OLV 技术契约

### 4.1 Subject 与稳定身份

v1 模型只服务 `subject_kind=clv_cell`；surface Probe 若后续支持，使用独立 schema 和独立模型。

每个 cell 的持久身份至少包含：

```text
scene_id / volume_id / lod / global_cell_x,y,z / layout_revision
```

要求：

- 分页 halo 与核心格使用同一个全局身份；
- 同一全局 cell 的重复 halo 标签必须一致；
- 不使用对象 `instance_id` 或 brick-local index 作为持久身份；
- scene 中多个 Volume 不得混入同一个审核档案。

### 4.2 标签与接收者域

| 数据 | 含义 | 缺失时行为 |
| --- | --- | --- |
| `UNSET` | 无生效标签；不是训练类别 | `ABSTAIN` |
| `EXTERIOR` | 外部可见性域 | 与接收者域比较后才决定能否混合 |
| `INTERIOR` | 内部可见性域；不区分不同房间 | 同上；多房间转 Depth/混合路线 |
| `AMBIGUOUS` | 几何或审核存在明确歧义 | `ABSTAIN` |
| `abstain/confidence` | 独立推理信号，不是额外出分类 logit | 按模型登记策略回退 |
| `receiver_domain` | 当前 shading point 的可信接收者域 | 未知时 `ABSTAIN` |

本项目的 v1 实验门控，**不是腾讯未公开算法细节的断言**：

| 条件 | 决策 |
| --- | --- |
| receiver/candidate 标签可信且 domain 相同 | `ALLOW` |
| receiver/candidate 标签可信且 domain 不同 | `REJECT` |
| 任一方 UNSET/AMBIGUOUS、接收者域未知或哈希不符 | `ABSTAIN` |

`REJECT` 必须在插值和归一化前发生；`ABSTAIN` 必须完整走旧行为，不能解释为“全部拒绝”。

两个房间可以同为 `INTERIOR`，所以该门控**不声称解决多房间隔离**。开放门洞、室内外过渡区也必须做专门测试：如果简单二域门控阻断合理传输或造成过黑，应调整接收者域/采用 Depth 混合路线，而不是把失败隐藏为“模型准确率”。

### 4.3 审核面与运行面分离

**审核/训练面：**

- append-only revision 记录 teacher、AI、人工决定、证据和版本；
- manifest 显式指向 active revision，不能靠 JSONL 最后一行猜测；
- manifest 原子替换、写后校验及写失败恢复必须有测试；
- 特征引用使用受约束的相对路径，拒绝绝对路径与 `..`；
- scene 级 train/val/test 分割信息与数据集一起归档。

**运行面：**

- 从已批准或自动应用批次编译独立、紧凑、版本化 payload；
- 包含 cell domain、接收者域映射、schema 与哈希；
- 与 `validity`、relocation 分离；无标签时不得删除原有有效算子或改变坐标；
- 有明确的 archive/load、resident 对齐、分页滚动、释放和撤销生命周期；
- 原生 shader 不读 JSONL，不跑分类器。

“每 cell 一个紧凑标签”可以作为设计目标，但索引、版本、接收者映射和校验仍是额外数据；不得把标签大小等同于总包体大小。

### 4.4 P0 必须签出的渲染语义

在写生产 shader 前，用解析 fixture 固定：

1. 接收者 domain 的来源、查询精度、哈希和 `UNSET` 区域；
2. 每个角点的 `ALLOW/REJECT/ABSTAIN` 合成规则；
3. 被拒绝角点不进入传输归一化分母；
4. accepted weight 与 support/coverage 的关系，兼容当前 SH2 filtered-coverage 解码；
5. 全部 `REJECT` 时的返回值、Sky ownership 和过黑风险处理；
6. 任一角 `ABSTAIN` 时如何保证整个相关路径完全回退；
7. 细/粗 LOD 分别门控后的混合规则，以及只有一级可用时的行为；
8. 开放门洞与室内外过渡区的合法传输如何保留；
9. 除零、非有限值、coverage 越界与非法 payload 的失败行为。

这些项目未冻结前，P1 只能做实验 fixture，不能进入默认生产路径。

---

## 5. 分阶段执行任务

### P0：当前基线与可测试契约

**入口：**本计划评审通过。

**任务：**

- [ ] 以 layout 7/8、SH2 schema 2、4 fields 更新所有相关设计引用。
- [ ] 冻结 §4 的身份、室内外标签、接收者域、coverage、全拒、ABSTAIN 和 LOD 语义。
- [ ] 画出 review sidecar → runtime compiler → payload → resident → native sampler 的数据所有权图。
- [ ] 定义 feature/model/schema/hash 版本及失效矩阵。
- [ ] 写出可手算的 2×2×2 室内外 fixture，另含开放门洞/过渡区用例。
- [ ] 明确多房间、位置问题和 Depth 问题不属于 OLV v1 的隐形验收范围。

**交付物：**冻结后的契约、fixture 数值说明、测试矩阵。

**退出标准：**不再需要边写 shader 边决定标签、接收者域或归一化语义。

### P1：无 AI 的 GPU 渲染垂直切片

**入口：**P0 完成。

**目标：**先证明“当前 prepared sampler 能在插值前正确处理室内外域”，不证明 AI。

**任务：**

- [ ] 参考现有 [test_preinterpolated_clv_sky_ownership.gd](../misc/feng-addons/feng-render-pipeline/tests/test_preinterpolated_clv_sky_ownership.gd)，新增独立 OLV fixture 与测试。
- [ ] 手工注入 cell 标签和接收者域；不依赖 Bake、模型或人工 UI。
- [ ] 在实验开关后实现逐角读取与 P0 定义的门控。
- [ ] 保留 post-gate 对照，证明已混合能量不能靠最终 domain/coverage 解混。
- [ ] 测试拒绝后的传输归一化、support/coverage、全拒和 LOD。
- [ ] 测试开放门洞/过渡区，检查是否误删合理传输或产生过黑。
- [ ] 用两个同为 INTERIOR 的房间记录 OLV 能力边界，不把该反例包装成已解决。
- [ ] 测试开关关闭和 `ABSTAIN` 与旧结果一致；测试无 NaN/Inf。

**建议新增测试：**`misc/feng-addons/feng-render-pipeline/tests/test_magic_gi_olv_preinterpolation.gd`。

**退出标准：**layout 7/8 共享采样数学的解析 fixture 通过，且适用边界明确；只声称“数学与契约可行”。

**成本预警：**朴素方案是每 LOD `8 角 × 4 fields = 32` 次取值，另加标签读取；这是待测实现成本，不是性能结论。

### P2：无 AI 的真实场景端到端闭环

**入口：**P1 通过。

**目标：**用确定性几何 teacher 打通室内外标签数据链，再引入学习模型。

**任务：**

- [ ] 建立一个仓内开发场景，覆盖清晰室内外边界、薄墙、曲面、窄缝、开放门洞和歧义区域。
- [ ] 实现室内外几何 teacher 与接收者域生成；不确定时输出 `ABSTAIN`。
- [ ] 保留现有 source relocation 与传输语义，不在 OLV 操作中移动采样点。
- [ ] 实现标签 overlay、Review/Approve、sidecar、manifest、哈希失效与导出。
- [ ] 实现独立 runtime compiler/payload；完成序列化往返和损坏输入拒绝。
- [ ] 接入 archive/load、layout 7 resident 上传、原生 ABI/binding 和缓存刷新。
- [ ] 对分页 halo、重复全局 cell、滚动 resident、预算释放做一致性测试。
- [ ] layout 7 完成真实场景 A/B；layout 8 完成上传和采样 smoke。
- [ ] 增加独立开关；关闭时不改变现有结果，旧资源无需自动迁移。
- [ ] 在 Inspector 提供“分析/应用已批准 OLV 标签”，此阶段不命名为“AI 自动修复”。

**退出标准：**真实场景的人工室内外标签能影响默认 layout 7 插值前采样；已知跨域用例按契约减少，开放门洞没有未解释的过黑。

### P3：数据集、训练、导出与编辑器推理

**入口：**P1 已证明渲染数学；P2 的数据生产接口可用。模型最终接入必须等 P2 运行时链路通过。

**任务：**

- [ ] 至少形成几何不同的 train/val/test 三个 scene 集合，严格按 scene 隔离。
- [ ] 另留只出现在 test 的未见几何类型；记录 scene 列表、哈希和数据集版本。
- [ ] 导出固定版本局部几何特征；teacher/silver、pseudo、human gold 分层保存。
- [ ] 以小 MLP 为基线，2 层约 128 hidden units 只作为可调起点。
- [ ] 受监督 logits 只有 EXTERIOR/INTERIOR/AMBIGUOUS；UNSET 与 abstain 不作为 CE 类别。
- [ ] 分别报告各类 precision/recall、混淆矩阵、覆盖率、弃权率和按场景分组结果。
- [ ] 在验证集上选择置信/弃权策略；测试集只用于最终评估。
- [ ] 导出带版本、schema、subject_kind、哈希的模型包。
- [ ] Godot 编辑器实现同一 MLP 前向；v1 优先避免 ONNX 运行时。
- [ ] 用固定权重和样本做 Python/GDScript 数值一致性测试。
- [ ] 保留一套合成数据流程冒烟，但不得把冒烟结果宣称为泛化。

**建议工具目录：**`misc/scripts/magicgi_olv/`，包含训练、评估、导出和推理一致性检查。

**退出标准：**模型在未见场景 gold 上得到可复现评估，编辑器前向一致，弃权可生效；不以同场景随机拆 cell 的结果充当泛化。

### P4：一键 AI 漏光修正（OLV）

**入口：**P2、P3 均通过，且模型包登记完整。

**任务：**

- [ ] 在 Volume Inspector 增加“AI 漏光修正（OLV）”和进度/取消状态。
- [ ] 实现 §3 的 preflight、推理、auto-apply、payload 校验、上传与刷新事务。
- [ ] 高置信且接收者域映射可信者自动应用；其余明确跳过，不为了覆盖率强行分类。
- [ ] 自动应用批次与 human gold 分离，模型更换只失效对应 AI 数据。
- [ ] 增加 A/B、Undo、失败诊断和修改数量统计。
- [ ] 验证取消、写失败、哈希过期、模型不匹配时旧 Bake/payload 保留。
- [ ] 验证选择节点、状态 Timer 和 Inspector 刷新不会隐式写 sidecar；只有显式操作才写。
- [ ] 验证多 Volume、未保存场景、切节点和关场景没有串数据或 stale callback。

**退出标准：**训练完成后用户只需一次按钮即可完成受控 OLV 修正；无模型、无有效 Bake 或低置信时不会伪造成功。

### P5：验收、性能与发布

**任务：**

- [ ] 在未见场景测试室内外漏光、局部过黑、薄墙、曲面、窄缝和非封闭网格。
- [ ] 专门检查开放门洞与过渡区，防止把合理光照一并拒绝。
- [ ] 多次改变太阳/TOD/支持的发光输入，检查 relight 后标签仍稳定。
- [ ] 测试旧资源、开关关闭、ABSTAIN、模型缺失和 stale hash 回归。
- [ ] 测试分页滚动、halo、resident 重映射、多个 Volume 和撤销恢复。
- [ ] 测量完整 GPU 成本，包括原生 Lighting 中的采样；同时记录显存、CPU、推理和上传成本。
- [ ] 与当前旧路径做同设备、同场景、同视角、同光照的配对测量。
- [ ] 多房间用 Depth/混合路线单独评估，不计入 OLV v1 的“已修复”统计。
- [ ] 先默认关闭；验收后按 Volume 开放，保留一键回退。

**发布门槛：**正确性、回退和未见场景验收优先于模型平均准确率；任何性能承诺必须来自实际测量。

---

## 6. 独立路线：位置优化与 Depth

### 6.1 Probe 位置/密度优化（不是 OLV 标签模型）

只有当诊断证明主要问题是采样位置或密度时才进入：

- [ ] 先以现有几何 relocation、安全间距和自适应布局为基线。
- [ ] 评估候选位置是否满足实体外、OBB、净空、表面侧和稳定 ID 约束。
- [ ] 位置变化后重新计算或验证 TransferMatrix、天空/发光传输、距离矩与 prepared 算子。
- [ ] 对比“原布局”“几何 relocation”“候选位置优化”的最终图像与传输误差，而不只看 Probe 可视化。
- [ ] 如未来研究 NN 位置偏移，使用独立模型、特征、目标和版本；不得与 OLV 标签输出混为一谈。

**为什么不一上来让 NN 移 Probe：**位置与传输积分耦合，移动后可能需要重新 Bake；它不能保证解决跨域插值，还会引入墙面穿越、稳定身份和过黑风险。它可以是一键“重新布局并重烘”的另一项功能，但不是原文所述 OLV 的必然要求。

### 6.2 Depth / 混合可见性（多房间优先评估）

当需求包含多个室内房间或更一般的遮挡关系时：

- [ ] 独立设计每 Probe/Cell 的 DistanceMap/Depth 数据、稀疏存储和 streaming。
- [ ] 根据 shading point 与候选 Probe 的遮挡关系计算权重，而不是只比较室内外 Tag。
- [ ] 验证默认 prepared layout 7/8 的实际数据上传与原生绑定，不把 source 中有距离矩当成运行时已接入。
- [ ] 测量 DistanceMap、间接索引、额外采样和显存成本。
- [ ] 与 OLV 在同一场景做 A/B：OLV 负责室内外粗域，Depth 负责更细遮挡时，再评估混合路线。

原文对 Depth 的通用性描述同样是文章自报；本项目仍需独立验证，不承诺无场景限制。

---

## 7. 最终完成定义（Definition of Done）

只有同时满足以下条件，才能宣称“训练后一键 OLV 漏光修正”已交付：

- [ ] 默认 layout 7 的真实渲染链路消费室内外标签，且发生在插值前；layout 8 的支持范围明确并通过对应测试。
- [ ] 用户不需要逐 cell 审核高置信结果，只需按一次按钮。
- [ ] 低置信/未知接收者域会安全弃权，不静默套用错误标签。
- [ ] 训练不出现在按钮或每帧渲染中；运行时不读取审核 JSONL。
- [ ] 自动应用不会污染 human gold；数据按 scene 无泄漏划分。
- [ ] 原 Bake 与 Probe/Cell 坐标不被 OLV 操作破坏，A/B、Undo、取消与失败恢复可用。
- [ ] 旧路径回归、开放门洞、coverage/全拒/LOD、分页和 relight 测试通过。
- [ ] 未见场景的室内外漏光与过黑结果、性能和资源成本有归档证据。
- [ ] 多房间没有被计入 OLV 已解决范围；如有该需求，Depth/混合路线单独验收。

---

## 8. 可行性与主要风险

| 项目 | 当前判断 | 风险控制 |
| --- | --- | --- |
| 编辑器一键标签推理、应用、A/B、撤销 | 工程上可行 | 独立事务、版本化 payload、保留上一代结果 |
| 静态几何、室内外分界清晰的特定跨域插值漏光 | 有条件可行 | P1 先证明数学，P2 再证明真实链路 |
| 让 NN 直接移动 Probe 来替代 OLV | 不是同一任务，且通常需要重算传输 | 独立位置路线；先几何基线，后评估是否有学习价值 |
| 多个室内房间互相漏光 | OLV 室内外标签不充分 | Depth/混合可见性，不计入 OLV v1 成功率 |
| 模型泛化 | 未证实 | scene 隔离、未见几何测试、弃权与人工 gold |
| 性能与显存 | 未测量 | 逐角实验先测成本，再考虑合并读取、紧凑标签或其他优化 |
| 错误标签导致过黑/传光 | 真实风险 | 接收者域校验、开放门洞测试、ABSTAIN、A/B、Undo |

**最大项目风险不是 MLP 是否足够大，也不是能否回归一个坐标，而是室内外标签与接收者域能否在当前 layout 7/8 的插值前正确落地。**因此 P1/P2 是一键 AI 之前不可跳过的门槛。

---

## 9. 参考资料

- OLV 与 Depth 的公开说明（文章自报，本文未独立复现）：<https://zhuanlan.zhihu.com/p/2020903414117201233>。
- GDC 2026 CLV PRT 公开流程：<https://media.gdcvault.com/gdc2026/Slides/Sheng_Feng_IlluminatingRocosLegacyScalableGlobalIlluminationfromTheorytoPractice.pdf>。
- 当前 Magic GI 使用与数据契约：[feng-magic-gi/README.md](../misc/feng-addons/feng-magic-gi/README.md)。
