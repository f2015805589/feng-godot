# FRP v2 架构与演进方向

FRP 采用“引擎渲染原语 + 插件 Pass + 声明式管线资源”的分层。
本文说明已实现的结构与后续设计方向；完整可调用 API 见 [引擎契约](frp-engine-contract.md)，
使用与迁移见 [插件说明](../misc/feng-addons/feng-render-pipeline/README.md)。

## 当前分层

| 层 | 所有权 | 实现 |
|---|---|---|
| Core | 原生渲染操作、帧缓冲和底层执行 | `FRPPassContext`、`frp_clustered` |
| 原生规范 | 稳定 ID、Operation 展开、默认顺序和依赖 | `frp_pipeline_spec.h` |
| Pass 包 | 默认原生实现、独立效果、shader 和参数 | `passes/native/`、`passes/`、`library/` |
| 管线资源 | 条目顺序、实现选择、开关、作者参数 | `FengRenderer` |
| 视图绑定 | compositor、逐相机状态和效果 RID | `FengCompositor`、ViewState |
| 空间配置 | Volume 范围、字段权限内的参数混合 | `volume/` |

这一结构与 SRP Core/RenderPass 的职责划分相近：项目可通过脚本编排原语和替换效果，
原生绘制能力由引擎提供。当前引擎保留原生 Pass 表及无插件调度，作为规范和 fallback。

## 已实现的合同

1. **Pass 与 Operation 分层。** 管线展示组合后的条目，resolve、副本、高光合并等由所属
   条目完成。运动矢量与 GBuffer 同一遍几何生成。
2. **稳定身份与显式顺序。** 原生 ID 持久化，列表位置决定执行位置；校验器检查依赖与
   纹理来源。Bloom ID 8 位于 Post Process ID 7 之前。
3. **插件原生实现。** FengBuiltinPass 默认携带 FengNativePass 脚本，通过 Core 原语执行。
   清空 implementation 使用引擎实现；独立 Pass 可声明 `provides_native_ids` 接管原生工作。
4. **帧上下文与参数快照。** `_frp_execute(ctx)` 读取帧状态和按稳定键索引的最终参数。
   参数声明、条目覆盖、Volume 混合在插件侧完成。
5. **开关与视口特性一致。** 显式管线的 Temporal AA 条目控制 TAA/jitter，provided ID
   同样参与特性查询。时序上采样器保留自己的 jitter 所有权。
6. **HDR/LDR 效果。** 后处理、Bloom、Tonemap 和 Present 有独立原语；Post overlay 可选择
   Tonemap 前后，通过命名输出与 `Source.TONEMAPPED` 实现 LDR 处理。
7. **逐视图 Volume。** 字段由 Pass 代码开放，逐字段覆盖开关控制参与混合的值。每相机
   独立保存参数、效果绑定和纹理，按明确共享协议复用执行对象。
8. **帧前准备。** `_frp_prepare(ctx)` 在执行列表之前提交雾/大气元数据，绘制仍在原条目位置。

当前 Renderer schema 为 10；新资源的原生条目与默认库效果由代码清单生成。
已保存资源通过迁移与库同步维持身份和作者配置，具体默认顺序只在插件说明中维护。

## 后续设计方向

以下能力尚未作为通用接口提供，新增时需要具体消费者、兼容方案和测试：

- **更细的几何提交接口：** 直接选择 render list、pass mode 和 framebuffer；
  当前脚本使用 `draw_gbuffer()`、`draw_transparent()` 等组合原语
- **原语级 options：** 为底层绘制开放类型明确的选项；当前逐 Pass 参数快照仅供已有
  消费者使用，不能任意改变引擎内部 shader 或布局
- **可替换的内部光照 shader：** 当前可替换插件 Pass 和 overlay，原生 Core 使用引擎编译的 shader

这些方向不要求先移除原生 spec 或 fallback。扩展时保持原生 ID、序列化资源、已有方法签名
和无插件项目可用；依赖与参数策略继续由插件负责。

## 验证要求

- 同一原生工作经内置 token 和脚本 Core 路径执行，应在相同配置下得到一致画面
- 自定义接管必须同步 provided ID、附件需求、开关和 jitter
- 改序、禁用生产者与非法资源应得到明确校验结果
- Volume 和编辑器预览不得修改作者资源或泄漏逐相机状态
- 共享渲染代码变更同时覆盖 FRP 与 forward_plus

入口为 `misc/scripts/test_frp_pipeline.py` 与 `test_frp_volume_cpu.py`。
历史阶段的测量结果属于对应验证/审计记录；本文件维护当前架构及尚待设计的能力。
