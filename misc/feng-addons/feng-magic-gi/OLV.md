# MagicGI 与 OLV

OLV 统一为 MagicGI 下唯一的 `FOLVVolume` 子节点，由 **Feng Magic GI** 插件提供编辑界面。开关、独立模型更新、单个／批量 Probe 的室内外编辑均位于该子节点，不再另建校正区域节点或启用单独插件。

MagicGI 提供已烘焙的源 Probe 和只读传输；OLV 自己保存标签资源，修改标签不会替换 GI manifest 或传输矩阵。已有场景可通过“导入已有 OLV”直接迁移。

完整操作、唯一生产模型、训练材料和回归入口见 [Feng OLV 使用说明](../feng-olv/README.md)。
