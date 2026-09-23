extends SceneTree
## The near field's page budget: the two settings, their clamps and the cross-constraint between
## them. The motion-driven escalation itself is exercised by the snap probe
## (`vt_project_lifetime_probe.py`), which has a live view to move; this test pins the part a script
## can decide on its own - that no ordering of the two setters can leave a tier reading a number it
## was not clamped to.

func _initialize() -> void:
	call_deferred("run")

func _require(condition: bool, message: String) -> void:
	if not condition:
		push_error("REGRESSION: " + message)
		quit(1)

func run() -> void:
	var terrain := Terrain3D.new()
	var settings: Dictionary = terrain.get_vt_settings()
	_require(int(settings.avt_batch_default_pages) == 16, "the stable tier defaults to the shipped 16")
	_require(int(settings.avt_batch_max_pages) == 64, "the escalated tier defaults to 64")
	_require(int(settings.avt_batch_peak_setting) == 64, "the configured peak is the max")
	_require(int(settings.avt_batch_ceiling) == 256, "the ceiling is 256")
	# At rest the live ceiling is the stable tier, which is what every existing acceptance reading
	# was calibrated against.
	_require(int(settings.avt_batch_max) == 16, "the live ceiling at rest is the stable tier")
	_require(String(settings.avt_batch_tier_name) == "stable", "nothing has moved, so the tier is stable")
	# A non-positive budget is not a rate: the floor is one page.
	terrain.surface_vt_page_batch_default = 0
	_require(terrain.surface_vt_page_batch_default == 1, "a zero default clamps up to one page")
	terrain.surface_vt_page_batch_default = -7
	_require(terrain.surface_vt_page_batch_default == 1, "a negative default clamps up to one page")
	terrain.surface_vt_page_batch_max = 0
	_require(terrain.surface_vt_page_batch_max == 1, "a zero max clamps up to one page")
	terrain.surface_vt_page_batch_max = -3
	_require(terrain.surface_vt_page_batch_max == 1, "a negative max clamps up to one page")
	terrain.surface_vt_page_batch_default = 16
	terrain.surface_vt_page_batch_max = 64
	# The ceiling may not sit below the stable rate: a max under the default is raised to it rather
	# than refused, so the property reads back the ordering the caller asked for.
	terrain.surface_vt_page_batch_max = 4
	_require(terrain.surface_vt_page_batch_max == 16, "a max below the default is raised to the default")
	terrain.surface_vt_page_batch_max = 9999
	_require(terrain.surface_vt_page_batch_max == 256, "an oversized max clamps to the ceiling")
	# A default above the max raises the max with it.
	terrain.surface_vt_page_batch_max = 16
	terrain.surface_vt_page_batch_default = 64
	_require(terrain.surface_vt_page_batch_max == 64, "raising the default above the max raises the max")
	_require(int(terrain.get_vt_settings().avt_batch_max) == 64, "the live ceiling follows the raised default")
	_require(int(terrain.get_vt_settings().avt_batch_peak_setting) == 64, "the peak follows the raised default")
	# An oversized default is clamped by the same ceiling as an oversized max, and raises the max with
	# it rather than leaving the escalated tier below the stable one.
	terrain.surface_vt_page_batch_default = 9999
	_require(terrain.surface_vt_page_batch_default == 256, "an oversized default clamps to the ceiling")
	_require(terrain.surface_vt_page_batch_max == 256, "the raised max is inside the ceiling too")
	_require(int(terrain.get_vt_settings().avt_batch_peak_setting) == 256, "the peak never passes the ceiling")
	# A configuration with no headroom has one tier: this is how the shipped 16-page arm is run, and
	# it must read as the constant it always was.
	terrain.surface_vt_page_batch_default = 16
	terrain.surface_vt_page_batch_max = 16
	_require(int(terrain.get_vt_settings().avt_batch_max) == 16, "a collapsed budget is the shipped 16")
	# The allowance is the near field's share of that rate while the far field is drawing from the
	# same pool, which is the shipped even split: 16 / 2. A view nothing has served yet takes the
	# whole 16, which is the one thing `avt_view_unserved` changes.
	_require(int(terrain.get_vt_settings().avt_allowance) == 8, "the collapsed allowance is the shipped even share")
	_require(int(terrain.get_vt_settings().avt_batch_peak_setting) == 16, "a collapsed budget has no headroom")
	# Both are settings, so they serialize with the node and come back as they were.
	terrain.surface_vt_page_batch_default = 20
	terrain.surface_vt_page_batch_max = 40
	var packed := PackedScene.new()
	_require(packed.pack(terrain) == OK, "the terrain with a configured budget packs")
	var restored: Terrain3D = packed.instantiate()
	_require(restored.surface_vt_page_batch_default == 20, "the default pages round-trip")
	_require(restored.surface_vt_page_batch_max == 40, "the max pages round-trip")
	restored.free()
	terrain.free()
	print("PASS AVT page budget clamps and cross-constraints")
	quit(0)
