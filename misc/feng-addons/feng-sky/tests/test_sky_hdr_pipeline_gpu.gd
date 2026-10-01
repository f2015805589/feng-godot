extends "test_sky_motion_gpu.gd"
## Diagnostic readbacks after sky, fog, TAA and color grade. All 13 authored
## passes stay enabled; four temporary observer passes never enter performance QA.
func run_cases(compositor: Compositor, physical_units: bool, _temporal_aa, enabled_passes: int) -> void:
	var labels := ["native:4", "library:height_fog", "native:6", "library:color_grade"]
	var captures: Array = []
	var entries = _renderer.passes.duplicate()
	for label in labels:
		var capture = load("res://addons/feng-sky/tests/sky_hdr_capture.gd").new()
		capture.resource_name = "HDR Observer " + label
		entries.insert(entries.find(find_pass(label)) + 1, capture)
		captures.append(capture)
	_renderer.passes = entries
	_renderer.apply(compositor)
	var fog = load("res://addons/feng-fog/feng_height_fog.gd").new()
	fog.fog_density = 0.1
	fog.fog_height_falloff = 0.001
	_viewport.add_child(fog)
	_exposure.metering_mode = 2
	_exposure.apply_physical_camera_exposure = false
	var checked_channels := 0
	var case_index := 0
	for pre_exposure in [false, true]:
		_exposure.pre_exposure = pre_exposure
		for ev in [-16.0, 16.0]:
			_exposure.exposure_compensation = ev
			for lux in [60000.0, 10000000.0]:
				_sun.light_intensity_lux = lux
				_sun.light_energy = 1.0 if physical_units else lux / PI
				_sky.sun_angular_radius_deg = 0.01 if case_index % 2 == 0 else 0.26785
				_sun.rotation_degrees.y = case_index * 17.0
				_camera.look_at(_camera.position + _sun.global_transform.basis.z,Vector3.UP)
				_renderer.apply(compositor)
				await settle(48)
				var actual_exposure: float = await exposure_scale()
				var expected_exposure := pow(2.0,ev)
				require(absf(log(actual_exposure / expected_exposure) / log(2.0)) < 0.01, "manual EV did not reach active render parameters")
				for capture in captures:
					capture.requested = true
				for stage in captures.size():
					var values: PackedFloat32Array = await captures[stage].captured
					var nonfinite := 0
					var maximum := 0.0
					for pixel in values.size() / 4:
						for channel in 3:
							var value := values[pixel*4+channel]
							if not is_finite(value) or absf(value) > 65504.0:
								nonfinite += 1
							maximum = maxf(maximum,value)
							checked_channels += 1
					require(nonfinite == 0, "non-finite HDR after " + labels[stage])
					print("SKY HDR PIPELINE case=",case_index," pre=",pre_exposure," ev=",ev," lux=",lux,
						" stage=",labels[stage]," invalid_channels=",nonfinite," max=",maximum," pre_scale=",captures[stage].last_pre_exposure)
					var expected_pre := expected_exposure if pre_exposure else 1.0
					require(absf(log(captures[stage].last_pre_exposure / expected_pre) / log(2.0)) < 0.01, "pre-exposure did not reach this HDR stage")
				await sample_sun("hdr_pipeline_%d" % case_index,true)
				case_index += 1
	_viewport.free()
	await process_frame
	if not _failed:
		print("SKY HDR PIPELINE GPU PASS cases=",case_index," checked_channels=",checked_channels," authored_passes=",enabled_passes)
	quit(1 if _failed else 0)
