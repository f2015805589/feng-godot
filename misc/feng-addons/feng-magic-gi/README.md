# Feng Magic GI

FMagicGI 是依托于 FRP 管线的烘焙式全局光照插件(类 PRT-GI 初版):
在 Volume 内规则布点 → 烘焙每个探针的入射辐射为 3 阶球谐(SH3,9 系数 × RGB)
→ 渲染时在 FRP 的 "Magic GI" pass 内对每个像素做三线性插值并求
余弦卷积辐照度,作为漫反射 GI 叠加到光照结果上。

算法依据 Sloan et al. 2002《Precomputed Radiance Transfer》的 SH 投影与
Ramamoorthi & Hanrahan 2001 的辐照度环境贴图卷积权重(π, 2π/3, π/4)。

## 使用

1. 同时启用 `Feng Render Pipeline` 与 `Feng Magic GI` 插件
   (`link_plugin.ps1` 挂接后,`res://addons/feng-magic-gi/` 可用)。
2. 场景中创建 **FMagicGIVolume** 节点,调整 `size` 覆盖光照区域,
   `probe_dims` 控制每轴探针数(初版上限 64³)。
3. 选中 Volume,Inspector 中点 **Bake Probes**:每个探针对场景做 6 面
   90° 小孔相机捕获(共享世界 SubViewport,`bake_resolution` 为每面分辨率),
   逐像素按立体角权重投影到 SH。烘焙逐帧推进,探针多时会占用编辑器若干秒。
4. 在 FengRenderer 的 Passes 中通过 **Add Pass from Library → Magic GI**
   添加 pass(自动落在 `Post Lighting` 回调;确认顺序在 Lighting 之后)。
   已烘焙且 enabled 的 Volume 会被 `FMagicGIRuntime` 发布,
   pass 每帧读取最新快照(初版同时只生效一个 Volume:烘焙版本最新者)。

## 可视化(编辑器内)

- `show_probes`(默认开):Volume 内部每个探针位置画一个小球,
  颜色为探针 SH 的直流项(平均入射色);未烘焙为灰色。
- `show_sh_probes`:在探针位置上生成径向网格,顶点沿方向 d 拉伸
  |L(d)|、着色为 max(L(d), 0),直接还原每个探针的球谐形状;
  探针数超过 `MAX_SH_VIZ_PROBES`(256)时只画小球。
- Volume 移动/旋转/缩放后探针与烘焙场随动(SH 存于 Volume 局部系),
  但光照内容仍是烘焙时朝向采样,大角度旋转后建议重新烘焙。

## 数据布局

`FMagicGIData.sh`:每探针 27 个 float32,系数主序 `c0r,c0g,c0b,c1r,...`,
基序与 `feng_magic_gi_baker.gd` 的 `sh_basis` 一致
(Y0, Y1-1(y), Y10(z), Y11(x), Y2-2(xy), Y2-1(yz), Y20(3z²-1), Y21(xz), Y22(x²-y²))。
打包成 `probe_count*7 × 1` 的 RGBA32F 一行图集传入着色器,
`texelFetch(sh_atlas, 7*p+k)` 读取。

## 已知限制(初版)

- 仅漫反射 GI;无多次反弹、无遮蔽可见性(SH-VCTP 那种)。
- 同一时刻只应用一个已烘焙 Volume(不做多 Volume 叠加/混合)。
- 烘焙在编辑器 CPU 侧逐面读回,离线用途;运行时重烘焙未做。
- Volume 非均匀缩放时法线变换为近似(mat3(world_to_grid))。
- 透明物体、天空不做 GI(只有不透明几何的深度处才叠加)。
