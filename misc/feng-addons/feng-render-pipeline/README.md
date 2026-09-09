# Feng Render Pipeline

1. 给 Camera3D 或 WorldEnvironment 添加 Compositor。
2. 在 Compositor Effects 中添加 **FengComputePass**，或拖入 `examples/tint.tres`。
3. 选择 Effect Callback Type、Shader File、Textures 和 Parameters。
4. 同阶段的 Pass 按数组顺序执行；拖动排序，Enabled 控制开关。

每个 FengPassTexture 声明一个 set=0 的纹理绑定，可选采样输入或 Storage Image。
内置来源包括 Color、Depth、Normal/Roughness、Albedo、ORM、Emission；Custom
可引用其他 Pass 创建的 RenderSceneBuffersRD 纹理。Shader 使用 16 字节 vec4
Push Constant，默认工作组 8×8。HDR Color 的 Storage Image 格式为 rgba16f；
Albedo/ORM 为 rgba8，Emission 为 rgba16f。深度使用采样绑定，不能作为 Storage Image。

GBuffer 效果使用 Deferred: Post GBuffer / Pre Lighting；颜色后处理使用
Post Transparent。需要早期解析深度时启用 Access Resolved Depth；需要额外法线、
Motion、Specular 时设置继承的 Needs 标记。不要读取尚未产生的本帧数据。
Custom 输出必须由你的 Pass 提前创建，helper 不猜测格式、尺寸或生命周期。

Shader 保存在游戏项目中，导入后直接执行，修改无需重新编译引擎。
需要光栅 Pass、多个 Compute Dispatch、自定义纹理或不同 Push Constant 时，
直接继承 CompositorEffect 实现 `_render_callback`；可以和 FengComputePass 混排。
引擎会跟踪 RenderingDevice 的资源访问与屏障；没有实现任意依赖的自动拓扑排序。

Pass 阶段和纹理契约详见引擎 `doc/feng-terrain-deferred.md`。
