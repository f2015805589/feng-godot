@tool
extends RefCounted
## One worker owns one probe's arrays; only the main thread merges completed jobs.

const Data = preload("feng_magic_gi_data.gd")
const DirectionalBaker = preload("feng_magic_gi_directional_baker.gd")
const MomentBaker = preload("feng_magic_gi_moment_baker.gd")
var result: Data
var valid := false

func initialize(data: Data, probe: int) -> void:
	result = Data.new()
	result.positions = PackedVector3Array([data.positions[probe]])
	result.normals = PackedVector3Array([data.normals[probe]])
	if data.stable_probe_ids.size() == data.probe_count():
		result.stable_probe_ids = PackedInt64Array([data.stable_probe_ids[probe]])
	result.bake_samples = data.bake_samples
	result.bake_bounces = data.bake_bounces
	result.bake_distance = data.bake_distance
	result.emitter_keys = data.emitter_keys
	result.transfer.resize(27)
	result.primary_sky_visibility.resize(9)
	result.emitter_transport.resize(data.emitter_count() * 6)
	result.visibility_moments.resize(Data.VISIBILITY_TEXELS_PER_PROBE * 2)
	result.directional = Data.DirectionalData.new()
	result.directional.allocate(1, data.emitter_count())

func run(geometry: RefCounted, signature: int, probe: int,
		coordinates: Array[PackedFloat64Array], minimum_coordinates: Array[PackedFloat64Array],
		extra_coordinates: Array[PackedFloat64Array], visibility_rays: int) -> void:
	var rng := RandomNumberGenerator.new()
	var stable_id := int(result.stable_probe_ids[0]) if not result.stable_probe_ids.is_empty() else probe
	rng.seed = int(hash(([Data.SAMPLER_REVISION, stable_id, "visibility-moments"]
			if not result.stable_probe_ids.is_empty() else
			[signature, Data.SAMPLER_REVISION, probe, "visibility-moments"])))
	var shift := Vector2(rng.randf(), rng.randf())
	if not MomentBaker.bake(result, geometry, 0, shift, visibility_rays, minimum_coordinates, extra_coordinates):
		return
	rng.seed = int(hash(([Data.SAMPLER_REVISION, stable_id]
			if not result.stable_probe_ids.is_empty() else
			[signature, Data.SAMPLER_REVISION, probe])))
	var shifts := PackedFloat32Array()
	shifts.resize((result.bake_bounces + 1) * 2)
	for dimension in shifts.size():
		shifts[dimension] = rng.randf()
	var emitter_shifts := PackedFloat32Array()
	emitter_shifts.resize((result.bake_bounces + 1) * result.emitter_count() * 3)
	if result.stable_probe_ids.is_empty():
		rng.seed = int(hash([signature, Data.SAMPLER_REVISION, probe, "emission"]))
		for dimension in emitter_shifts.size():
			emitter_shifts[dimension] = rng.randf()
	else:
		for emitter in result.emitter_count():
			var emitter_rng := RandomNumberGenerator.new()
			emitter_rng.seed = int(hash([Data.SAMPLER_REVISION, stable_id,
					result.emitter_keys[emitter], "emission"]))
			for dimension in (result.bake_bounces + 1) * 3:
				emitter_shifts[emitter * (result.bake_bounces + 1) * 3 + dimension] = emitter_rng.randf()
	DirectionalBaker.bake_probe(result, geometry, 0, result.bake_samples, result.bake_bounces,
		result.bake_distance, coordinates, shifts, emitter_shifts)
	valid = true

func merge(destination: Data, probe: int) -> void:
	for k in 27:
		destination.transfer[probe * 27 + k] = result.transfer[k]
	for k in 9:
		destination.primary_sky_visibility[probe * 9 + k] = result.primary_sky_visibility[k]
	for k in result.visibility_moments.size():
		destination.visibility_moments[probe * result.visibility_moments.size() + k] = result.visibility_moments[k]
	for k in 243:
		destination.directional.transfer[probe * 243 + k] = result.directional.transfer[k]
	for k in 81:
		destination.directional.sky[probe * 81 + k] = result.directional.sky[k]
	for emitter in result.emitter_count():
		for k in 6:
			destination.emitter_transport[(emitter * destination.probe_count() + probe) * 6 + k] = result.emitter_transport[emitter * 6 + k]
		for k in 54:
			destination.directional.emission[(emitter * destination.probe_count() + probe) * 54 + k] = result.directional.emission[emitter * 54 + k]
