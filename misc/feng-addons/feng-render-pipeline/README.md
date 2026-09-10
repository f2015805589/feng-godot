# Feng Render Pipeline

FRP（Feng Render Pipeline）是引擎内置 FRP 渲染器（`rendering_method = "frp"`）之上的
声明式后处理管线插件。三层架构：

```
FengRenderer (Resource)          —— 声明式管线：passes 列表
  └─ FengPass (CompositorEffect) —— 单个 pass：stage + inputs + outputs
       ├─ FengShaderPass         —— compute 或全屏光栅 shader pass
       └─ (自定义子类)            —— 继承 FengPass 实现 _render()
  └─ FengTextureManager (隐藏)   —— 自动创建/重建 pass 声明的中间纹理
FengCompositor (Compositor)      —— 绑定 renderer，改动自动同步 effects
```

## 快速开始

1. 项目设置 `rendering/renderer/rendering_method = "frp"`。
2. 启用插件（Project → Project Settings → Plugins → Feng Render Pipeline）。
3. 创建 `FengRenderer` 资源，在 Passes 里添加 pass（或使用编辑器菜单
   **Add Pass from Library** 一键插入内置模板）。
4. 创建 `FengCompositor` 资源，把 Renderer 指向它；赋给 Camera3D 或
   WorldEnvironment 的 Compositor。

## Pass 配置

- **Stage**：9 个引擎回调阶段（Pre/Post Opaque、Post Sky、Pre/Post Transparent、
  Pre/Post GBuffer、Pre/Post Lighting）。同阶段按列表顺序执行。
- **Inputs**：`FengPassTexture` 声明 set=0 的纹理绑定。来源包括当前帧
  Color/Depth、GBuffer（Albedo/ORM/Emission/Normal-Roughness）、PIPELINE
  （本管线中间纹理，按名引用）和 CUSTOM（任意 scope）。
- **Outputs**：`FengPassOutput` 声明中间纹理 `{name, data_format, usage, scale}`。
  `FengTextureManager` 在 Pre GBuffer 阶段自动创建，分辨率切换自动重建。
- **Parameters**：16 字节 vec4 push constant，shader 内 `params` 读取。
- **Enabled**：原生开关，运行时切换即时生效，无需重新 apply。

`FengShaderPass` 两种模式：

- **Compute**：`mode = COMPUTE`，`workgroup_size` 控制调度；`dispatch_target`
  指定输出纹理（空 = 内部渲染尺寸）。
- **Raster**：`mode = RASTER`，全屏三角形；`raster_target` 指定颜色附件
  （空 = 视口颜色）。输入输出不能是同一张纹理（反馈保护）。

## 内置库（library/）

| Pass | 说明 |
|------|------|
| `tint` | 颜色乘法，示例/调试 |
| `blur` | 可分离高斯模糊，H+V 两趟，half 尺寸中间纹理 |
| `fxaa` | 简易边缘混合抗锯齿 |
| `color-grade` | 饱和度/对比度/亮度/伽马 |
| `bloom-lite` | 降采样提亮 + 模糊 + 合成 |

每个库 pass = glsl + 预配参数的 .tres 模板，编辑器菜单一键实例化。

## 校验

- 每个 pass 的 `get_configuration_warnings()` 检查绑定范围/重复、输出重名、
  阶段-数据可用性（Pre GBuffer 不可读本帧颜色/深度/GBuffer）。
- `FengRenderer.get_configuration_warnings()` 跨 pass 检查：输出重名、
  引用不存在的管线纹理、绑定重复。错误在 Inspector 标红。

## 与手写 CompositorEffect 混排

`FengPass` 本身就是 `CompositorEffect`，可以和其他手写 effect 混排在
`Compositor.compositor_effects` 里。`FengRenderer.apply()` 只负责把
passes 列表写入 effects；手写 effect 直接加在数组里即可。

## 测试

- `misc/scripts/test_frp_pipeline.py`：GPU 回归（D3D12/Vulkan，不能 headless）。
- `misc/scripts/tests/frp_passes.gd`：阶段/排序/开关、GBuffer 访问、MSAA、
  中间纹理生产-消费链、分辨率重建、renderer 组合、raster、库 pass、校验警告。

Pass 阶段和纹理契约详见引擎 `doc/feng-terrain-frp.md`。
