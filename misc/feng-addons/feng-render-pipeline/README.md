# Feng Render Pipeline

FRP 使用一个 `FengRenderer` 资源编排引擎原生操作与自定义 Pass。`FengCompositor`
把该资源连接到 Camera3D / WorldEnvironment。列表顺序直接驱动 FRP 原生渲染器，
不再只是按 CompositorEffect 阶段分组的后处理列表。

## 使用

1. 设置 `rendering/renderer/rendering_method = "frp"`，启用 Feng Render Pipeline 插件。
2. 创建 `FengRenderer`，默认包含下列 16 个原生操作和 8 个库 Pass。
3. 创建 `FengCompositor`，设置 Renderer，赋给 Camera3D 或 WorldEnvironment。
4. 在 Inspector 的 Passes 数组中拖动排序，编辑资源的 Enabled。条目显示具体名称，
   例如 `Deferred Lighting`、`Blur Horizontal`、`Bloom Composite`；`FengShaderPass`
   是它们共用的资源类型，不是效果名称。
5. 在 Inspector 选中 Renderer 或 FengCompositor 后，使用工具菜单
   **Add Pass from Library** 添加库效果。添加和排序支持编辑器撤销、重做。

## 原生操作

| ID | 名称 | 内容 |
|---|---|---|
| 0 | GBuffer | 不透明材质数据、深度及相关 resolve |
| 1 | Lighting Preparation | 阴影、GI、SSAO/SSIL/SSR、Cluster、体积雾准备 |
| 2 | Deferred Lighting | 全屏延迟光照 |
| 3 | Opaque Forward Fallback | 不适合 GBuffer 的特殊不透明材质 |
| 4 | Motion Vectors | 运动矢量 |
| 5 | Opaque Resolve | 不透明阶段附件 resolve |
| 6 | Debug Geometry | GI 调试几何 |
| 7 | Sky | 天空 |
| 8 | Sky Resolve | 天空后附件 resolve |
| 9 | Subsurface + Specular Merge | 次表面散射、分离高光合并 |
| 10 | Screen/Depth Copy | 透明材质使用的屏幕与深度副本 |
| 11 | Transparent | 透明物体前向绘制 |
| 12 | Final Resolve | 最终颜色、深度、运动矢量 resolve |
| 13 | SSIL/SSR History Copy | 历史帧副本 |
| 14 | Temporal AA / Upscale | TAA、FSR2、MetalFX Temporal |
| 15 | Post Process / Tonemap | 引擎后处理和最终输出 |

这些条目执行真实的原生操作，但粒度是上述组合步骤，不是逐个 GPU draw/dispatch。
例如 Lighting Preparation 内部的阴影、GI 和 SSAO 尚未拆成可独立排序的条目。
反射探针和普通 Compositor 保留原有阶段调度。

排序受数据依赖约束：GBuffer 必须先于光照准备和延迟光照，最终 resolve 必须先于
Tonemap；天空、前向补绘等可以在符合约束的范围内移动。当前 0、1、2、12、15 是
完整输出必需的操作，不能删除或禁用，也尚不支持用自定义 Pass 替换它们。

其余条目可以关闭；部分条目还受视口/材质设置约束，例如开启 TAA/FSR2 时不能关闭
对应的运动矢量和时域处理。遇到这种运行时冲突，引擎告警并使用默认阶段管线。
Inspector 显示配置依赖错误。无效配置保留上次有效的原生顺序，并暂停该 Renderer
的自定义效果，避免禁用上游纹理生产者后，下游继续读取失效纹理；修正配置后恢复。

## 内置库同步

`DEFAULT_LIBRARY_ENTRIES` 是库清单，每项包含稳定 `id`、模板 `path` 和显示 `name`。
新增效果时放入 GLSL + `.tres`，在清单的期望位置登记：

```gdscript
{"id": "library:my_effect", "path": "my-effect/my_effect.tres", "name": "My Effect"},
```

已有 Renderer 在访问 Passes、检查配置或 apply 时自动补入新项：优先插入最近的
已有后继库条目前，否则放在前驱后，最后回退到 Temporal AA 前。默认库整体位于
History Copy 与 Temporal AA 之间。同步保留现有条目的相对顺序、开关和参数，
不会把你删除过的条目加回来；通过库菜单可以明确重新添加。

稳定 ID 应保持不变。同步补充新增条目和旧资源的名称/身份，不会强行合并已实例化
模板的参数改动。旧版只有自定义效果的 `.tres` 会迁移为完整列表，并按原 Stage
安排初始位置，保留旧的库删除记录。

## 自定义 Pass

- 继承 `FengPass` 实现 `_setup(rd)`、`_render(buffers, view, rd)`、`_cleanup(rd)`。
- 或创建 `FengShaderPass`，配置 Compute / 全屏 Raster、`shader_file`、`parameters`
  （vec4 push constant）、`inputs`、`outputs` 和目标纹理。
- `FengPassTexture` 支持 Color、Depth、GBuffer、管线中间纹理及自定义 scope。
  `FengPassOutput` 声明名称、格式、用途和尺寸比例，隐藏的 Texture Manager 管理分配。
- 在 FengRenderer 中，自定义效果按列表位置运行。`stage` 仅保留为回调参数及旧资源
  迁移提示；在普通 Compositor 中仍按原 Stage 调度。
- 当前 `Color` 指内部 HDR 颜色；依赖它的效果应位于 Deferred Lighting 后、Tonemap 前。
  自定义纹理必须先生产再消费。同一 Pass 的 storage-image 输出绑定可以引用自身输出。

禁用的自定义 Pass 仍保留在 effects 中，重新启用不再需要重新插入。FengCompositor
合并资源 changed 通知后自动 apply。脚本直接修改数组内容时，使用整个数组重新赋值
或在修改后调用 `renderer.emit_changed()`；手动使用普通 Compositor 时显式 apply。

## RenderDoc 对照

Renderer 资源需要通过 FengCompositor 挂到 WorldEnvironment 或正在使用的 Camera3D。
仅创建、选中 Renderer 资源不会改变场景。编辑器自由视角使用编辑器自己的相机；
需要自由视角也使用同一配置时，把 FengCompositor 挂在 WorldEnvironment 上。

GPU 事件按 `FRP Scene → 列表序号 + Pass 名称 → 内部操作 → Commands (L…)`
分组。自定义名称来自 `resource_name`，与 Inspector 列表一致。显式管线在 Pass
边界建立命令依赖，防止渲染图把命令移到其他 Pass 前后；单个 Pass 内部仍按资源
依赖优化。`L` 是底层命令图层级，不是列表序号。

禁用的 Pass 和当前帧没有 GPU 工作的步骤不会产生事件，例如未开启 MSAA 时的
Resolve、场景没有透明物体时的 Transparent。GBuffer 内含普通场景几何 draw；
当前地形 Shader 使用顶点变形，归入 Opaque Forward Fallback，应在该组查看其几何。
Deferred Lighting 的全屏 draw 消费 GBuffer，不代表所有物体只画了一次全屏三角形。
编辑器最后把 Scene 纹理绘制到 UI 的步骤也不是场景几何绘制。

## 验证

```text
python misc/scripts/test_frp_pipeline.py --driver d3d12
python misc/scripts/test_frp_pipeline.py --driver vulkan
```

测试使用隔离项目和真实 GPU，覆盖延迟渲染、库效果、保存迁移、新增条目插入位置、
开关、原生/自定义排序、MSAA，以及编辑器资源选择、库菜单、撤销和重做。
