# FRP 管线配置化改造（多 Agent 协作计划）

## 现状核实（2026-09-10）

- M0 改名已被提交 `2a2216147e` 回滚，工作区干净：`deferred_clustered/`、`"deferred"` 字符串、`test_deferred_pipeline.py`、`deferred_passes.gd`、`doc/feng-terrain-deferred.md`、`misc/deferred-renderer-plan.md` 均为旧名；`misc/frp-pipeline-plan.md` 不存在；`shaders/frp_clustered/` 残留 2 个 gen.h 构建产物需删除。
- 插件现状：`FengComputePass`（extends CompositorEffect，单次 compute dispatch）+ `FengPassTexture`（输入声明）+ `examples/tint.tres` + 空 `editor_plugin.gd`。
- 引擎：deferred 渲染器在 `servers/rendering/renderer_rd/deferred_clustered/`，Compositor 9 阶段回调，GBuffer scope `"deferred_clustered"`。
- 测试：`misc/scripts/test_deferred_pipeline.py`（GPU 回归，D3D12/Vulkan，不能 headless）。

## Agent 拆分与依赖链

```
Agent1 (M0 改名) ──> Agent2 (M1 pass 核心) ──> Agent3 (M2 renderer 组合层) ──> Agent4 (M3 内置库) ──> Agent5 (M4 UI+测试+文档)
```

严格顺序执行，每个 agent 完成后由主线程验证再启动下一个。所有文本替换用 Python 脚本（UTF-8 读写），禁止 PowerShell 直接读写含中文文件。

## Agent 1 — M0 改名 deferred → frp

**输入**：干净基线（当前工作区）。

**任务**：
1. 删除残留 `servers/rendering/renderer_rd/shaders/frp_clustered/`（仅 gen.h 构建产物）。
2. `git mv` 重命名：`deferred_clustered/` → `frp_clustered/`（4 文件 + SCsub）、`shaders/deferred_clustered/` → `shaders/frp_clustered/`（`deferred_lighting.glsl` → `frp_lighting.glsl`、`scene_deferred_clustered*.glsl` → `scene_frp_clustered*.glsl`）、`test_deferred_pipeline.py` → `test_frp_pipeline.py`、`tests/deferred_passes.gd` → `tests/frp_passes.gd`、`doc/feng-terrain-deferred.md` → `doc/feng-terrain-frp.md`、`misc/deferred-renderer-plan.md` → `misc/frp-renderer-plan.md`。
3. Python 脚本替换（大小写敏感，仅渲染器相关标识符）：
   - 类名：`RenderDeferredClustered`→`RenderFRPClustered`、`SceneShaderDeferredClustered`→`SceneShaderFRPClustered`、`RenderBufferDataDeferredClustered`→`RenderBufferDataFRPClustered`、`GeometryInstanceDeferredClustered`→`GeometryInstanceFRPClustered`、`DeferredLightingMode`→`FrpLightingMode`、`DEFERRED_LIGHTING_MODE_`→`FRP_LIGHTING_MODE_`、`DeferredLightingShaderRD`→`FrpLightingShaderRD`、`struct DeferredLighting`→`struct FrpLighting`、`RB_SCOPE_DEFERRED_CLUSTERED`→`RB_SCOPE_FRP_CLUSTERED`、`MODE_DEFERRED_LIGHTING`→`MODE_FRP_LIGHTING`。
   - **注意**：gen.h 类名是 title case（`glsl_builders.py:194` 规则），`scene_frp_clustered.glsl` 生成 `SceneFrpClusteredShaderRD`（Frp 非 FRP），`frp_lighting.glsl` 生成 `FrpLightingShaderRD`。
   - 路径/字符串：`deferred_clustered`→`frp_clustered`、`"deferred"`→`"frp"`、`"Deferred"`→`"FRP"`（仅渲染器相关处）。
4. 引擎接入点（已核实行号）：`main/main.cpp:2502/2526/2612`、`renderer_compositor_rd.cpp:38/378/384`、`renderer_viewport.cpp:1026/1449`、`rendering_device.cpp:8383`（`"Deferred"`→`"FRP"`）、`shader_preprocessor.cpp:1355`、`environment_storage.cpp:457/652/774/821`、`shader_language.cpp:10068`、`core/config/project_settings.cpp:110`（feature tag `"Deferred"`→`"FRP"`）。
5. 新建项目 UI：`editor/project_manager/project_dialog.cpp` 按钮文本 `TTRC("Deferred")`→`TTRC("FRP")`、meta `"deferred"`→`"frp"`、默认值判断、信息文本分支、feature tag `"Deferred"`→`"FRP"`。
6. SCsub：`renderer_rd/SCsub`、`shaders/SCsub` 的 SConscript 路径。
7. doc XML：`doc/classes/CompositorEffect.xml`、`RenderingServer.xml` 的 "Deferred only"→"FRP only"、scope 名。
8. 测试/fixture/插件：`test_frp_pipeline.py`（方法字符串、`deferred_passes.gd`→`frp_passes.gd`）、`frp_passes.gd`（scope `"deferred_clustered"`→`"frp_clustered"`）、`feng-renderdoc-capture/tests/fixture/project.godot:5`、`pass_texture.gd`/`compute_pass.gd` 的 scope。
9. 文档内容同步：`doc/feng-terrain-frp.md`、`misc/frp-renderer-plan.md` 全文替换（Python 处理中文）。
10. 重建 `misc/frp-pipeline-plan.md`（本计划文档，含 M0-M4 全部内容）。

**不改清单**：`pipeline_deferred_rd.h`（延迟编译 helper）、`call_deferred`/`deferred_drag_mode` 等上游 API、翻译 .po 文件、`connections_dialog.cpp`/`animation_player.cpp` 的上游词汇。

**验收**：
- `scons platform=windows target=editor -j8` 编译通过（清 shader 缓存重编，gen.h 重新生成）。
- 精确 grep（`RenderDeferredClustered|SceneShaderDeferredClustered|"deferred_clustered"|"deferred"` 等）在引擎/测试/插件/文档目录 0 命中（不改清单除外）。
- `bin/godot.windows.editor.x86_64.exe --headless --rendering-method frp --rendering-driver d3d12 --quit` 正常启动。
- `python misc/scripts/test_frp_pipeline.py`（D3D12）全过。

## Agent 2 — M1 pass 核心抽象

**输入**：M0 完成（scope 为 `frp_clustered`）。

**任务**（全部在 `misc/feng-addons/feng-render-pipeline/`）：
1. `passes/pass_base.gd`：`FengPass extends CompositorEffect`。声明 `stage`（复用引擎 EffectCallbackType）、`inputs: Array[FengPassTexture]`、`outputs: Array[FengPassOutput]`、needs 标志；钩子 `_setup(rd)` / `_render_callback`（内部校验输入可用 → 调 `_render`）/ `_cleanup(rd)`；`_render` 为虚方法。
2. `passes/pass_texture.gd`：现 `FengPassTexture` 增强，新增 `Source.PIPELINE`（按 name 从 scope `"frp_pipeline"` 取），保留 CUSTOM。
3. `passes/pass_output.gd`：`FengPassOutput` 资源：`{name, data_format, usage(SAMPLED/STORAGE), size(INTERNAL/half/quarter), msaa}`。
4. `passes/texture_manager.gd`：`FengTextureManager extends CompositorEffect`，Pre GBuffer 阶段每帧 `buffers.has_texture(&"frp_pipeline", name)` 否则 `create_texture(...)`；按视口生命周期管理，分辨率切换自动重建。
5. `passes/shader_pass.gd`：`FengShaderPass extends FengPass`，compute 模式吸收现 `FengComputePass` 全部能力（shader、绑定、vec4 push constant、workgroup），输出走 `outputs` 声明。
6. 迁移：`compute_pass.gd`/`pass_texture.gd` 旧文件删除或改为 re-export 兼容（生态仅 tint，直接升级不留别名）；`examples/tint.tres` 更新为新类。

**验收**：A pass 声明输出 → texture_manager 自动创建 → B pass 按名读取，画面正确；分辨率切换重建无泄漏；`frp_passes.gd` 增补中间纹理生产-消费链测试通过。

## Agent 3 — M2 renderer 组合层 + raster 模式

**输入**：M1 完成。

**任务**：
1. `renderer.gd`：`FengRenderer extends Resource`，`passes: Array[FengPass]`；`apply(compositor)` 把 enabled passes 按 stage 分组、组内按列表序，连同 texture_manager 写入 `Compositor.compositor_effects`；pass 的 `enabled` 双向绑定。
2. `compositor.gd`：`FengCompositor extends Compositor`，持 `renderer` 引用，changed 时自动同步 effects。
3. `shader_pass.gd` 增加 raster 模式：全屏三角形 pipeline（参考引擎 `effects/copy_effects`/`specular_merge` 模式），输出到声明的输出纹理或颜色附件。

**验收**：列表拖拽改序、逐项开关即时生效；光栅 pass 输出到中间纹理与颜色附件画面正确；同一份 renderer 配置多相机复用；`frp_passes.gd` 增补光栅/排序/复用测试通过。

## Agent 4 — M3 内置 pass 库

**输入**：M2 完成。

**任务**：`library/` 下每个库 pass = glsl + 预配参数的 `FengShaderPass` .tres 模板：
- `tint`（从 examples 迁入）
- `blur`（可分离两趟，half 尺寸中间纹理）
- `fxaa`
- `color-grade`（LUT/曲线参数）
- `bloom-lite`（降采样 + 模糊 + 合成）

**验收**：库 pass 逐个画面回归（D3D12）；tint 迁移后 `frp_passes.gd` 原 tint 测试段仍过。

## Agent 5 — M4 编辑器 UI + 测试扩充 + 文档

**输入**：M3 完成。

**任务**：
1. `editor_plugin.gd`：Add Pass from Library 菜单（扫描 `library/*.tres`，点击实例化插入 passes）。
2. 编辑期校验：stage-数据可用性表（复用 `doc/feng-terrain-frp.md` 契约）、输出重名、引用不存在的输出、绑定重复，错误在 inspector 标红。
3. 测试扩充：`frp_passes.gd` 覆盖组合/开关/排序/中间纹理/光栅/库加载；`test_frp_pipeline.py` 同步。
4. 文档：插件 README 重写（三层架构用法）；`doc/feng-terrain-frp.md` 增补 FRP 配置章节。

**验收**：库菜单一键添加；错误配置编辑期标红；全部测试 D3D12 + Vulkan 通过；README 完整。

## 全局验收

- 全部 5 个 agent 完成后：`scons` 编译通过、`test_frp_pipeline.py` D3D12+Vulkan 全过、新建项目对话框出现 FRP 按钮且创建项目正常、导出 feature 校验无报错、地形插件与 renderdoc-capture fixture 回归。
- 提交：每个 agent 完成后独立提交（M0 一个提交，M1-M4 各一个），提交信息含里程碑号。
