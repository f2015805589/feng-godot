# Copyright © 2023-2026 Cory Petkovsek, Roope Palmroos, and Contributors.
# Page tree rows for the Surface VT editor: the builders behind every node of the
# window's hierarchy - "settings", "surface", "avt", "svt", "pages" and
# "baked_pages".
#
# The window owns the widget, which view is shown and what the user selected;
# these are pure functions over a Snapshot of the live terrain, so the shape of
# the tree can be reasoned about - and exercised - without a window or a scene.
#
# TreeItem metadata is the interface back to the window: "location" selects a
# terrain region, "slot" and "kind" a physical page, "baked" and "preview" a
# stored cell source the inspector can show.
@tool
class_name TerrainVTEditorPageRows
extends RefCounted

# A pathological pool must not stall the editor's tree build, so long lists are
# truncated with a "…" row instead of being laid out in full.
const MAX_ROWS: int = 512


# One read of the live terrain for one details refresh. The window gathers it so
# that filling the tree never reaches back into the scene midway, and so every
# builder below takes data instead of a terrain.
class Snapshot extends RefCounted:
	var settings: Dictionary = {}
	var region_world: Vector2 = Vector2.ONE
	var locations: Array = []
	var avt_pages: Array = []
	var svt_pages: Array = []
	var all_pages: Array = []
	var baked_pages: Array = []
	var avt_stats: Dictionary = {}
	var svt_stats: Dictionary = {}
	var svt_page_world: float = 0.0
	var svt_density: float = 0.0
	var avt_enabled: bool = false
	var svt_enabled: bool = false
	var baked_mip: int = 0


static func snapshot(p_terrain: Object, p_data: Object, p_baked_mip: int) -> Snapshot:
	var shot := Snapshot.new()
	shot.settings = TerrainVTBridge.vt_settings(p_terrain)
	shot.region_world = region_world_size(p_terrain)
	shot.locations = TerrainVTBridge.region_locations(p_data)
	shot.all_pages = TerrainVTBridge.resident_pages(p_terrain, "")
	shot.avt_pages = TerrainVTBridge.resident_pages(p_terrain, "AVT")
	shot.svt_pages = TerrainVTBridge.resident_pages(p_terrain, "SVT")
	shot.baked_pages = TerrainVTBridge.baked_pages(p_terrain)
	shot.avt_stats = TerrainVTBridge.view_stats(p_terrain, "AVT")
	shot.svt_stats = TerrainVTBridge.view_stats(p_terrain, "SVT")
	shot.svt_page_world = float(TerrainVTBridge.call_method(p_terrain, "get_surface_svt_page_world"))
	shot.svt_density = float(TerrainVTBridge.call_method(p_terrain, "get_surface_svt_texels_per_meter"))
	shot.avt_enabled = bool(TerrainVTBridge.call_method(p_terrain, "is_surface_vt_enabled"))
	shot.svt_enabled = bool(TerrainVTBridge.call_method(p_terrain, "is_surface_svt_enabled"))
	shot.baked_mip = p_baked_mip
	return shot


# The pages one view owns. "" means every physical page, whatever tier published
# it, which is what the shared residency view lists.
static func pages_of(p_shot: Snapshot, p_kind: String) -> Array:
	if p_kind == "AVT":
		return p_shot.avt_pages
	if p_kind == "SVT":
		return p_shot.svt_pages
	return p_shot.all_pages


static func region_world_size(p_terrain: Object) -> Vector2:
	var region_size := float(TerrainVTBridge.call_method(p_terrain, "get_region_size"))
	var spacing := float(TerrainVTBridge.call_method(p_terrain, "get_vertex_spacing"))
	return Vector2(maxf(region_size * spacing, 1.0), maxf(region_size * spacing, 1.0))


# A page's block is decided by the centre of its world rectangle, not a corner, so
# a page straddling a block boundary still resolves to the block it mostly covers.
static func location_for_world_rect(p_rect: Rect2, p_region_world: Vector2) -> Vector2i:
	return Vector2i(floori((p_rect.position.x + p_rect.size.x * 0.5) / p_region_world.x), floori((p_rect.position.y + p_rect.size.y * 0.5) / p_region_world.y))


static func rect_text(p_rect: Rect2) -> String:
	return "world %.1f,%.1f %.1fx%.1f" % [p_rect.position.x, p_rect.position.y, p_rect.size.x, p_rect.size.y]


# The one place a TreeItem is created, so the four text columns keep one order:
# name, state, address, details.
static func add_row(p_tree: Tree, p_parent: TreeItem, p_name: String, p_state: String, p_address: String, p_details: String) -> TreeItem:
	var item := p_tree.create_item(p_parent)
	item.set_text(0, p_name)
	item.set_text(1, p_state)
	item.set_text(2, p_address)
	item.set_text(3, p_details)
	return item


static func add_settings_summary(p_tree: Tree, p_root: TreeItem, p_shot: Snapshot) -> void:
	var settings := p_shot.settings
	add_row(p_tree, p_root, "Shared atlas", "Ready" if bool(settings.get("shared_pool", false)) else "Pending", "", "%d pages · %d + %d border texels" % [int(settings.get("page_count", 0)), int(settings.get("page_size", 0)), int(settings.get("border", 0))])
	add_row(p_tree, p_root, "Adaptive AVT", "Enabled" if bool(settings.get("adaptive", false)) else "Disabled", "", "Adaptive blocks can resize while retaining overlap")
	add_row(p_tree, p_root, "Producer", "Active" if settings.has("producer") else "Unavailable", "", "Material pages are produced by the Surface VT baker")


static func add_surface_details(p_tree: Tree, p_root: TreeItem, p_shot: Snapshot) -> void:
	var settings := p_shot.settings
	add_row(p_tree, p_root, "Surface VT", "Shared", "", "AVT and SVT keep separate virtual addressing")
	add_row(p_tree, p_root, "AVT", "Enabled" if p_shot.avt_enabled else "Disabled", "", "%d resident pages" % p_shot.avt_pages.size())
	add_row(p_tree, p_root, "SVT", "Enabled" if p_shot.svt_enabled else "Disabled", "", "%d resident · %d baked" % [p_shot.svt_pages.size(), p_shot.baked_pages.size()])
	add_row(p_tree, p_root, "Shared pool", "Ready" if bool(settings.get("shared_pool", false)) else "Pending", "", "One physical slot budget is shared by both views")


static func add_avt_details(p_tree: Tree, p_root: TreeItem, p_shot: Snapshot) -> void:
	add_row(p_tree, p_root, "AVT runtime material", "Runtime", "", "AVT uses surface ID/weight source data; it is not an offline material bake")
	add_row(p_tree, p_root, "Resident", str(p_shot.avt_pages.size()), "", TerrainVTBridge.stats_text(p_shot.avt_stats))
	add_row(p_tree, p_root, "Adaptive", "Enabled" if bool(p_shot.settings.get("adaptive", false)) else "Disabled", "", "Shared page blocks may resize for demand")
	add_resident_page_rows(p_tree, p_root, p_shot, "AVT")
	add_region_rows(p_tree, p_root, p_shot)


static func add_svt_details(p_tree: Tree, p_root: TreeItem, p_shot: Snapshot) -> void:
	var region_world := p_shot.region_world
	add_row(p_tree, p_root, "SVT persisted material", "Runtime", "", "One baked source with a full mip chain per terrain block; GPU copies runtime cache pages")
	add_row(p_tree, p_root, "Resident", str(p_shot.svt_pages.size()), "", TerrainVTBridge.stats_text(p_shot.svt_stats))
	# The artist-facing answer to "how much material does one terrain block
	# carry": the addressable extent at the configured density, and how many
	# internal pages that extent is cut into. It is not a page count.
	var resolution := Vector2i(ceil(region_world.x * p_shot.svt_density), ceil(region_world.y * p_shot.svt_density))
	var page_edge := maxi(1, int(p_shot.settings.get("page_size", 256)))
	var page_grid := Vector2i(ceili(float(resolution.x) / page_edge), ceili(float(resolution.y) / page_edge))
	add_row(p_tree, p_root, "Result per terrain block", "%d x %d texels" % [resolution.x, resolution.y], "%.2f texels/m" % p_shot.svt_density, "%d x %d internal pages at mip 0; not separate terrain blocks" % [page_grid.x, page_grid.y])
	add_row(p_tree, p_root, "Physical page footprint", "%.3f m" % p_shot.svt_page_world, "mip 0", "%d baked cell sources, each containing its mip chain" % p_shot.baked_pages.size())
	add_resident_page_rows(p_tree, p_root, p_shot, "SVT")
	add_baked_page_rows(p_tree, p_root, p_shot)


static func add_all_page_details(p_tree: Tree, p_root: TreeItem, p_shot: Snapshot) -> void:
	add_resident_page_rows(p_tree, p_root, p_shot, "")
	add_baked_page_rows(p_tree, p_root, p_shot)


static func add_resident_page_rows(p_tree: Tree, p_root: TreeItem, p_shot: Snapshot, p_kind: String) -> void:
	var pages := pages_of(p_shot, p_kind)
	if pages.is_empty():
		add_row(p_tree, p_root, "Resident pages", "None", "", "No physical pages are currently published")
		return
	var count := 0
	for record in pages:
		if count >= MAX_ROWS:
			add_row(p_tree, p_root, "…", "Truncated", "", "%d more pages" % (pages.size() - count))
			break
		if typeof(record) != TYPE_DICTIONARY:
			continue
		var slot := int(record.get("slot", -1))
		var kind := TerrainVTBridge.record_kind(record)
		var address: Vector2i = record.get("address", Vector2i())
		var mip := int(record.get("mip", 0))
		var ready := bool(record.get("ready", false))
		var rect: Rect2 = record.get("world_rect", Rect2())
		var owners: Array = record.get("owners", [])
		var location := location_for_world_rect(rect, p_shot.region_world)
		var row := add_row(p_tree, p_root, "Slot %d · %s" % [slot, kind], str(record.get("state", "Ready" if ready else "Pending")), "%s m%d" % [address, mip], "%s · owners %d" % [rect_text(rect), owners.size()])
		# A page that is cached rather than freshly produced says why, and that
		# reason belongs on the state column of its row.
		var cache_reason := str(record.get("cache_reason", "")).strip_edges()
		if not cache_reason.is_empty():
			row.set_tooltip_text(1, cache_reason)
		row.set_metadata(0, {"slot": slot, "kind": kind, "location": location})
		for owner in owners:
			if typeof(owner) != TYPE_DICTIONARY:
				continue
			var child := add_row(p_tree, row, "Owner", str(owner.get("owner_type", kind)), str(owner.get("virtual", address)), "sector %s · mip %d" % [owner.get("sector", Vector2i()), int(owner.get("mip", mip))])
			child.set_metadata(0, {"slot": slot, "kind": kind, "location": location})
		count += 1


# Baked sources are listed per terrain block, because that is the unit the artist
# bakes and the unit the mip chain belongs to. A coarse tile that covers more than
# one block is listed once as shared coverage.
static func add_baked_page_rows(p_tree: Tree, p_root: TreeItem, p_shot: Snapshot) -> void:
	var pages := p_shot.baked_pages
	var filtered: Array = []
	for record in pages:
		if typeof(record) == TYPE_DICTIONARY and (record.get("storage", "") == "Baked cell mip chain" or int(record.get("mip", 0)) == p_shot.baked_mip):
			filtered.append(record)
	if filtered.is_empty() and not pages.is_empty() and p_shot.baked_mip != 0:
		add_row(p_tree, p_root, "Baked material tiles", "No selected mip", "mip %d" % p_shot.baked_mip, "Choose another mip from Baked mip")
		return
	if filtered.is_empty():
		add_row(p_tree, p_root, "Baked material tiles", "None", "mip %d" % p_shot.baked_mip, "Bake SVT cells to create persisted sources")
		return
	var groups := {}
	var region_world := p_shot.region_world
	for record: Dictionary in filtered:
		var rect: Rect2 = record.get("world_rect", Rect2())
		var group_key: Variant = "shared" if rect.size.x > region_world.x or rect.size.y > region_world.y else location_for_world_rect(rect, region_world)
		if not groups.has(group_key):
			groups[group_key] = []
		groups[group_key].append(record)
	var resolution := Vector2i(ceil(region_world.x * p_shot.svt_density / pow(2.0, p_shot.baked_mip)), ceil(region_world.y * p_shot.svt_density / pow(2.0, p_shot.baked_mip)))
	var rows_left := MAX_ROWS
	for group_key: Variant in groups:
		var entries: Array = groups[group_key]
		var shared := group_key is String
		var name_text := "Shared coarse coverage" if shared else "Terrain block %s" % group_key
		var parent := add_row(p_tree, p_root, name_text, "%d source files" % entries.size(), "mip %d" % p_shot.baked_mip, "Shared by multiple blocks" if shared else "%d x %d texels per block" % [resolution.x, resolution.y])
		parent.collapsed = true
		if not shared:
			parent.set_metadata(0, {"location": group_key, "kind": "SVT"})
		for record: Dictionary in entries:
			if rows_left <= 0:
				add_row(p_tree, parent, "More internal pages", "Not expanded", "", "The block summary includes all stored pages")
				break
			rows_left -= 1
			var rect: Rect2 = record.get("world_rect", Rect2())
			var preview = record.get("preview", null)
			var row := add_row(p_tree, parent, "Cell source %s" % record.get("address", Vector2i()), "Preview ready" if TerrainVTBridge.is_valid_image(preview) else "File only", "mip %d" % p_shot.baked_mip, rect_text(rect))
			row.set_metadata(0, {"slot": int(record.get("slot", -1)), "kind": "SVT", "baked": true, "location": location_for_world_rect(rect, region_world), "preview": preview})


static func add_region_rows(p_tree: Tree, p_root: TreeItem, p_shot: Snapshot) -> void:
	var locations := p_shot.locations
	if locations.is_empty():
		add_row(p_tree, p_root, "Terrain regions", "None", "", "No loaded regions")
		return
	var root := add_row(p_tree, p_root, "Terrain regions", str(locations.size()), "", "Click a region to inspect its Terrain3DRegion data")
	for location in locations:
		var child := add_row(p_tree, root, "Region %s" % location, "Loaded", str(location), "Terrain3DRegion")
		child.set_metadata(0, {"location": location})
