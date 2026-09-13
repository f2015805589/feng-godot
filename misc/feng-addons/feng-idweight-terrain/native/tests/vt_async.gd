extends "res://vt_adaptive_base.gd"

func run() -> void:
    scene = Node3D.new()
    terrain = Terrain3D.new()
    terrain.region_size = 64
    terrain.vt_page_size = 32
    terrain.vt_page_count = 64
    terrain.surface_vt_texels_per_meter = 32
    terrain.surface_svt_enabled = false
    terrain.surface_svt_auto_bake = false
    scene.add_child(terrain)
    root.add_child(scene)
    add_assets()
    terrain.region_size = 64
    terrain.surface_density = 1
    terrain.data.add_region_blank(Vector2i.ZERO)
    camera = Camera3D.new()
    camera.position = Vector3(32, 4, 32)
    camera.rotation_degrees = Vector3(-60, 0, 0)
    root.add_child(camera)
    camera.current = true
    terrain.set_camera(camera)
    await frame_image(12)
    terrain.set_physics_process(false)
    # Submit work against the previous map, then immediately replace its source.
    terrain.update_surface_vt(16)
    set_region_material(Vector2i.ZERO, 1)
    terrain.data.update_maps()
    terrain.invalidate_surface_pages(Vector2i.ZERO)
    for frame in 240:
        terrain.update_surface_vt(16)
        await process_frame
        await RenderingServer.frame_post_draw
    var checked := 0
    for record in terrain.get_vt_pages():
        if record.kind != "AVT" or not record.ready: continue
        var image: Image = terrain.get_surface_vt().read_page(record.slot)
        var bytes := image.get_data()
        var rect: Rect2 = record.world_rect
        var size: int = terrain.vt_page_size
        var border: int = terrain.vt_page_border
        var stored := size + 2 * border
        for y in range(0, stored, 3):
            for x in range(0, stored, 3):
                var point := rect.position + Vector2(x - border + 0.5, y - border + 0.5) * rect.size.x / size
                if point.x >= 0 and point.y >= 0 and point.x < 64 and point.y < 64:
                    if bytes.decode_u16((y * stored + x) * 2) != ((1 << 11) | (1 << 6)):
                        print("BAD point=", point, " rect=", rect, " size=", image.get_size(), " format=", image.get_format(), " value=", bytes.decode_u16((y * stored + x) * 2), " region=", terrain.region_size, " source=", terrain.data.get_region(Vector2i.ZERO).get_surface_map().get_data().decode_u16(0))
                        require(false, "stale source reached a resident page after edit")
                        quit(1)
                        return
                    checked += 1
    require(checked > 100, "inspect actual completed async page payloads")
    # Exit with replacement work queued: worker must not access destroyed terrain.
    terrain.vt_page_size = 64
    terrain.update_surface_vt(16)
    scene.queue_free()
    camera.queue_free()
    await process_frame
    await process_frame
    if failed: quit(1)
    else:
        print("PASS async edit invalidation, payload sampling and teardown; samples=", checked)
        quit(0)
