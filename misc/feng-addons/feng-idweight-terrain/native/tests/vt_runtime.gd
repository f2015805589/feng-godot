# Run with a graphical rendering driver; see README.md in this directory.
#
# Virtual texture runtime: sector -> virtual block allocation, the indirection mip
# chain, physical page storage and the LRU/protected slot allocator. Everything is
# checked against GPU readback, not just the CPU mirror, because the indirection and
# the atlas are what the shader will actually sample.
extends SceneTree

const PAGE := 32
const BORDER := 2
const STORED := PAGE + 2 * BORDER # 36
const INDIRECTION := 64 # 7 mips: 64, 32, 16, 8, 4, 2, 1
const INVALID := 65535

var failed := false

func _initialize() -> void:
	call_deferred("run")

func require(value: bool, message: String) -> void:
	if not value:
		push_error("REGRESSION: " + message)
		failed = true

# A page image in the atlas format (R16, the same format as the surface map).
func make_page(value: int) -> Image:
	var bytes := PackedByteArray()
	bytes.resize(STORED * STORED * 2)
	for i in STORED * STORED:
		bytes.encode_u16(i * 2, value)
	return Image.create_from_data(STORED, STORED, false, Image.FORMAT_R16, bytes)

func make_vt(page_count: int) -> Terrain3DVirtualTexture:
	var vt := Terrain3DVirtualTexture.new()
	vt.set_page_size(PAGE)
	vt.set_page_border(BORDER)
	vt.set_page_count(page_count)
	vt.set_indirection_size(INDIRECTION)
	vt.set_minimal_block(4)
	vt.set_format(Image.FORMAT_R16)
	return vt

func indirection_pixel(vt: Terrain3DVirtualTexture, x: int, y: int) -> int:
	var image := RenderingServer.texture_2d_get(vt.get_indirection_rid())
	if image == null:
		return -1
	return int(round(image.get_pixel(x, y).r))

# Indirection writes are batched: request_page() only marks the CPU chain dirty, and
# commit() is what uploads it. Everything that inspects the GPU state goes through here.
func committed_pixel(vt: Terrain3DVirtualTexture, x: int, y: int) -> int:
	vt.commit()
	return indirection_pixel(vt, x, y)

func test_initialize(vt: Terrain3DVirtualTexture) -> void:
	require(vt.is_initialized(), "vt should be initialized")
	var stats := vt.get_stats()
	require(int(stats["stored_page_size"]) == STORED, "stored page size should include the border")
	require(int(stats["page_count"]) == 8, "page count")
	require(int(stats["indirection_mips"]) == 7, "64 indirection should give 7 mip levels")
	require(vt.get_level_count() == 7, "level count")
	require(vt.get_level_size(0) == 64 and vt.get_level_size(1) == 32 and vt.get_level_size(6) == 1,
			"mip chain should halve to 1")
	# Every texel starts invalid.
	require(vt.get_indirection_slot(0, 0, 0) == INVALID, "a fresh indirection holds no slot")
	require(indirection_pixel(vt, 0, 0) == INVALID, "GPU indirection starts invalid")
	print("PASS vt initialize: atlas + ", int(stats["indirection_mips"]), " level indirection")

func test_sector_allocation(vt: Terrain3DVirtualTexture) -> void:
	require(vt.register_sector(Vector2i.ZERO, 4), "sector (0,0) should allocate")
	require(vt.register_sector(Vector2i(1, 0), 4), "sector (1,0) should allocate")
	require(vt.register_sector(Vector2i(0, 1), 8), "sector (0,1) should allocate a 8x8 block")
	require(vt.has_sector(Vector2i(1, 0)), "sector should be registered")
	require(vt.get_sector_block_size(Vector2i(0, 1)) == 8, "block size should be the requested one")
	require(vt.register_sector(Vector2i.ZERO, 4), "re-registering with the same size is idempotent")
	require(not vt.register_sector(Vector2i.ZERO, 8),
			"re-registering with a different size must be refused, not allocate a second block")
	require(vt.get_sector_block_size(Vector2i.ZERO) == 4, "the original block must be untouched")
	# Blocks are disjoint and aligned to their own size.
	var boxes := []
	for sector in [Vector2i.ZERO, Vector2i(1, 0), Vector2i(0, 1)]:
		var size: int = vt.get_sector_block_size(sector)
		var ox: int = vt.get_sector_block_origin_x(sector)
		var oy: int = vt.get_sector_block_origin_y(sector)
		require(ox % size == 0 and oy % size == 0, "block origin must be aligned to its size")
		for other in boxes:
			var a: Rect2i = other
			var b := Rect2i(ox, oy, size, size)
			require(not a.intersects(b), "sector blocks must not overlap: %s vs %s" % [a, b])
		boxes.append(Rect2i(ox, oy, size, size))
	print("PASS vt sector blocks are disjoint and aligned")

func test_request_and_publish(vt: Terrain3DVirtualTexture) -> void:
	var sector := Vector2i.ZERO
	var ox: int = vt.get_sector_block_origin_x(sector)
	var oy: int = vt.get_sector_block_origin_y(sector)
	vt.reset_stats()
	var slot: int = vt.request_page(sector, 0, 0, 0)
	require(slot >= 0, "a page request should return a slot")
	require(int(vt.get_stats()["miss_count"]) == 1, "the first request should miss")
	# CPU mirror and the uploaded texture must agree.
	require(vt.get_indirection_slot(ox, oy, 0) == slot, "the indirection texel should publish the slot")
	require(committed_pixel(vt, ox, oy) == slot, "GPU indirection texel should hold the slot")
	# commit() is a no-op once the chain is uploaded.
	var commits: int = int(vt.get_stats()["commit_count"])
	vt.commit()
	require(int(vt.get_stats()["commit_count"]) == commits, "commit should be a no-op when nothing changed")
	# A second request is a hit and returns the same slot.
	var again: int = vt.request_page(sector, 0, 0, 0)
	require(again == slot, "a repeated request must return the same slot")
	require(int(vt.get_stats()["hit_count"]) == 1, "the repeated request should hit")
	require(vt.lookup_page(sector, 0, 0, 0) == slot, "lookup should find the published slot")
	print("PASS vt request publishes a slot to the GPU indirection and reuses it")

func test_page_roundtrip(vt: Terrain3DVirtualTexture) -> void:
	var sector := Vector2i.ZERO
	var slot: int = vt.request_page(sector, 0, 1, 0)
	require(slot >= 0, "second page should allocate")
	var page := make_page(0x1234)
	require(vt.write_page(slot, page), "write_page should succeed")
	var back := vt.read_page(slot)
	require(back != null and not back.is_empty(), "read_page should return an image")
	require(back.get_size() == Vector2i(STORED, STORED), "read back page size")
	require(back.get_data() == page.get_data(), "page content must round trip through the GPU atlas")
	# A wrong-sized or wrong-format page is rejected rather than uploaded.
	require(not vt.write_page(slot, make_page(1).get_region(Rect2i(0, 0, PAGE, PAGE))),
			"a page without the border must be rejected")
	print("PASS vt page content round trips through the GPU atlas")

func test_mip_walk(vt: Terrain3DVirtualTexture) -> void:
	# A block of 8 has local mips 0..3. Publishing only at mip 2 must still serve a
	# lookup from mip 0, because the walk halves the coordinate until it finds a slot.
	var sector := Vector2i(0, 1)
	require(vt.get_sector_block_size(sector) == 8, "block 8 sector")
	var ox: int = vt.get_sector_block_origin_x(sector)
	var oy: int = vt.get_sector_block_origin_y(sector)
	var slot: int = vt.request_page(sector, 2, 0, 0)
	require(slot >= 0, "a coarse page should allocate")
	require(vt.get_indirection_slot(ox >> 2, oy >> 2, 2) == slot, "published at local mip 2")
	require(vt.get_indirection_slot(ox, oy, 0) == INVALID, "mip 0 must stay empty")
	require(vt.lookup_page(sector, 0, 0, 0) == slot, "mip 0 lookup should fall back to the mip 2 slot")
	require(vt.lookup_page(sector, 1, 0, 0) == slot, "mip 1 lookup should fall back to the mip 2 slot")
	require(vt.lookup_page(sector, 2, 0, 0) == slot, "mip 2 lookup is an exact hit")
	# The fallback is real coverage, not a fabrication: the mip 2 page spans 4x4 mip 0
	# pages, so a neighbouring mip 0 page resolves to the same coarse slot.
	require(vt.lookup_page(sector, 0, 3, 3) == slot, "a mip 0 page inside the coarse page must resolve to it")
	var fine := vt.request_page(sector, 0, 0, 0)
	require(fine >= 0 and fine != slot, "requesting detail must allocate past an existing coarse fallback")
	require(vt.get_indirection_slot(ox, oy, 0) == fine, "detail must be published at the requested mip")
	require(vt.lookup_page(sector, 0, 3, 3) == slot, "refining one page must preserve its neighbours' fallback")
	# Pages outside the sector block do not exist at all.
	require(vt.lookup_page(sector, 0, 8, 0) == -1, "a page past the block edge must not resolve")
	require(vt.lookup_page(sector, 3, 1, 0) == -1, "mip 3 of a block 8 has a single page")
	require(vt.lookup_page(Vector2i(9, 9), 0, 0, 0) == -1, "an unregistered sector must not resolve")
	print("PASS vt indirection mip chain walks coarse-to-fine and halts at the block edge")

func test_lru_and_protection() -> void:
	var vt := make_vt(4)
	require(vt.initialize() == OK, "small vt should initialize")
	require(vt.register_sector(Vector2i.ZERO, 8), "eviction sector")
	var ox: int = vt.get_sector_block_origin_x(Vector2i.ZERO)
	var oy: int = vt.get_sector_block_origin_y(Vector2i.ZERO)
	# Fill all four physical pages. The free list hands them out in order.
	for i in 4:
		require(vt.request_page(Vector2i.ZERO, 0, i, 0) == i, "page %d should get slot %d" % [i, i])
	require(int(vt.get_stats()["free_count"]) == 0, "the atlas should be full")
	vt.reset_stats()
	# A fifth page has nowhere to go: the least recently used page (slot 0) is evicted.
	var slot: int = vt.request_page(Vector2i.ZERO, 0, 4, 0)
	require(slot == 0, "the least recently used slot should be reused, got " + str(slot))
	require(int(vt.get_stats()["evict_count"]) == 1, "exactly one eviction")
	require(vt.get_indirection_slot(ox, oy, 0) == INVALID,
			"eviction must invalidate the indirection texel that published the slot")
	require(committed_pixel(vt, ox, oy) == INVALID, "the GPU indirection must show the invalidation")
	require(vt.get_indirection_slot(ox + 4, oy, 0) == 0, "the new page publishes the reused slot")
	print("PASS vt eviction reuses the LRU slot and invalidates its indirection entry")

	# Protecting the LRU page moves eviction to the next oldest.
	vt.reset_stats()
	vt.protect_page(1, true)
	var slot2: int = vt.request_page(Vector2i.ZERO, 0, 5, 0)
	require(slot2 == 2, "a protected slot must be skipped, got " + str(slot2))
	require(vt.is_page_used(1) and vt.is_page_protected(1), "the protected slot stays resident")
	# With every slot protected there is nothing left to evict.
	for i in 4:
		vt.protect_page(i, true)
	require(vt.request_page(Vector2i.ZERO, 0, 6, 0) == -1, "a fully protected atlas cannot allocate")
	require(int(vt.get_stats()["protected_block_count"]) == 1, "the block should be counted")
	print("PASS vt protected pages survive eviction and block allocation when full")

	require(vt.unregister_sector(Vector2i.ZERO), "unregister should succeed")
	require(not vt.has_sector(Vector2i.ZERO), "the sector should be gone")
	vt.clear()
	require(not vt.is_initialized(), "clear should release the GPU resources")
	vt.free()

func test_shared_pool() -> void:
	var near := make_vt(2)
	require(near.initialize() == OK, "near view should initialize")
	require(near.register_sector(Vector2i.ZERO, 8), "near view should register a sector")
	var far := make_vt(2)
	far.set_world_space(true)
	far.share_physical_pool(near)
	require(far.initialize() == OK, "far view should initialize against the shared pool")
	require(near.get_atlas_rid() == far.get_atlas_rid(),
			"near and far views must expose one physical atlas RID")
	require(near.get_indirection_rid() != far.get_indirection_rid(),
			"near and far views must retain separate indirection textures")
	var near_slot: int = near.request_page(Vector2i.ZERO, 0, 0, 0)
	var far_slot: int = far.request_world_page(0, 0, 0)
	require(near_slot == 0 and far_slot == 1, "shared pool should assign global slot IDs")
	var owners: Array = far.get_page_metadata(far_slot)
	require(owners.size() == 1 and int(owners[0]["kind"]) == 1 and bool(owners[0]["world_space"]),
			"slot metadata should expose the far owner type and world addressing")
	# The next miss is serviced by the global LRU, even though the request arrives
	# through the near view. Its reverse owner callback must invalidate near's table.
	var recycled: int = near.request_page(Vector2i.ZERO, 0, 1, 0)
	require(recycled == near_slot, "the shared LRU should recycle the near slot")
	var near_origin_x: int = near.get_sector_block_origin_x(Vector2i.ZERO)
	var near_origin_y: int = near.get_sector_block_origin_y(Vector2i.ZERO)
	require(near.get_indirection_slot(near_origin_x, near_origin_y, 0) == INVALID,
			"cross-view eviction must invalidate the old owner's indirection")
	near.free()
	far.free()
	print("PASS shared physical page pool keeps global slots and cross-view eviction")

func test_sector_resize_preserves_pages() -> void:
	var vt := make_vt(8)
	require(vt.initialize() == OK, "resize view should initialize")
	var sector := Vector2i.ZERO
	require(vt.register_sector(sector, 4), "resize sector should register")
	var old_origin_x: int = vt.get_sector_block_origin_x(sector)
	var old_origin_y: int = vt.get_sector_block_origin_y(sector)
	var slot: int = vt.request_page(sector, 0, 1, 1)
	require(slot >= 0, "resize fixture page should allocate")
	require(vt.write_page(slot, make_page(12345)), "resize fixture has a distinctive payload")
	require(vt.resize_sector(sector, 8), "registered sector should resize to a larger POT block")
	var new_origin_x: int = vt.get_sector_block_origin_x(sector)
	var new_origin_y: int = vt.get_sector_block_origin_y(sector)
	require(vt.lookup_page(sector, 0, 2, 2) == slot,
			"doubling resolution must keep the payload over the same world footprint through mip 1")
	require(vt.lookup_page(sector, 0, 1, 1) == -1,
			"old local coordinates must not display a payload from a different world footprint")
	require(vt.get_indirection_slot((new_origin_x >> 1) + 1, (new_origin_y >> 1) + 1, 1) == slot,
			"resizing must shift the cached page's mip as well as its virtual address")
	var metadata: Array = vt.get_page_metadata(slot)
	require(metadata.size() == 1 and int(metadata[0]["mip"]) == 1 and
				int(metadata[0]["virtual_x"]) == (new_origin_x >> 1) + 1 and
				int(metadata[0]["virtual_y"]) == (new_origin_y >> 1) + 1,
			"resizing must update reverse owner metadata")
	var fine_slot: int = vt.request_page(sector, 0, 6, 6)
	require(vt.resize_sector(sector, 4), "registered sector should shrink back to a POT block")
	require(vt.lookup_page(sector, 0, 1, 1) == slot,
			"shrinking must restore the cached page's original world footprint")
	require(vt.get_page_metadata(fine_slot).is_empty(),
			"shrinking must discard fine pages that cannot represent a whole coarser footprint")
	vt.commit()
	require(int(round(vt.read_page(slot).get_pixel(2, 2).r * 65535.0)) == 12345,
			"the remapped physical payload remains unchanged")
	vt.protect_page(slot, true)
	vt.release_page(sector, 0, 1, 1)
	require(not vt.is_page_protected(slot), "released roots must not pin the next owner of their slot")
	vt.free()
	print("PASS sector resize remaps cached pages and reverse metadata")

func run() -> void:
	var vt := make_vt(8)
	require(vt.initialize() == OK, "vt should initialize")
	if not failed:
		test_initialize(vt)
	if not failed:
		test_sector_allocation(vt)
	if not failed:
		test_request_and_publish(vt)
	if not failed:
		test_page_roundtrip(vt)
	if not failed:
		test_mip_walk(vt)
	if not failed:
		test_lru_and_protection()
	if not failed:
		test_shared_pool()
	if not failed:
		test_sector_resize_preserves_pages()
	# Object is not reference counted, so the GPU resources have to be released by hand.
	vt.free()
	if failed:
		quit(1)
		return
	print("PASS virtual texture runtime")
	quit()
