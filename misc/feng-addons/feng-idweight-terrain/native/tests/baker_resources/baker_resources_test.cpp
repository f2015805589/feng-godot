#include "device_double.h"
#include "baker_features.inc"

// Only the surrounding Godot object is replaced. Structs and tested method bodies
// are read from production for every run, including when testing a baseline checkout.
class Terrain3DSurfaceBaker {
public:
	enum { TIER_AVT, TIER_SVT, TIER_COUNT };
	static constexpr int ENCODE_CHANNELS = 3, ENCODE_PAGES_MAX = 128, ENCODE_RING_NONE = 255;
	static constexpr uint32_t SOURCE_UPLOAD_MAX_BYTES = 16u * 1024u * 1024u, SOURCE_UPLOAD_MAX_PAGES = 16u;
#include "baker_types.inc"
	RenderingDevice *_rd = nullptr;
	test_std::mutex _mutex{1}, _encode_mutex{2};
	ResourceBundle _resources;
	TierState _tiers[TIER_COUNT];
	uint64_t _resource_generation = 0, _migrated_pages = 0, _generation = 1;
	uint64_t _encode_failures = 0, _encode_readbacks = 0;
	bool _encode_warned = false;
	std::vector<EncodedLayer> _encoded_layers;
	int _resource_page_count = 0, _page_count = 8, _stored_size = 8, _staging_layers = 0;
	int _encode_region_bytes = 0, _encode_region_words = 0;
	std::atomic<int> _encode_ring_allocated{4};
	std::atomic<bool> _ring_only{false};
	bool _retire_ready = false;
	std::vector<std::pair<uint64_t, ResourceBundle>> _retired;
	std::vector<uint8_t> _ready, _sampled_channel_mask, _slot_tier, _slot_scratch, _encode_pending, _encode_ring_held;
	std::vector<uint64_t> _produced_frame, _slot_sequence;
	std::vector<int> _source_upload_batch;

	static void _collect_bundle_rids(const ResourceBundle &, Array &, Array &);
	static void _free_rids(RenderingDevice *, const Array &, const Array &);
	static void _free_bundle(RenderingDevice *, const ResourceBundle &);
	uint64_t _take_resources(ResourceBundle &);
	bool _acquire_device();
	bool _ensure_resources(uint64_t, int, int, const RID &, const RID &, const PackedByteArray &);
	bool _adopt_grown_pages(const ResourceBundle &, ResourceBundle &, int, const std::vector<uint8_t> &, uint64_t, int);
	void _adopt_bundle(ResourceBundle &, uint64_t, int);
	bool _create_bake_core_resources(ResourceBundle &, const PackedByteArray &, int);
	bool _create_page_resources(ResourceBundle &, int, int);
	bool _compile_compute_pipeline(const char *, const String &, RID &, RID &, bool = false);
	bool _compile_pipeline(ResourceBundle &);
	bool _compile_encode_pipeline(ResourceBundle &);
	bool _compile_source_upload_pipeline(ResourceBundle &, int, int);
	bool _rebuild_uniform_set(ResourceBundle &, const RID &, const RID &);
	static RID _staging_rd_of(const ResourceBundle &, int);
	bool _tier_uses_sampled(int) const;
	uint8_t _tier_channel_mask(int, bool) const;
	bool _any_tier_uses_sampled(bool) const;
	bool _staging_is_scratch() const;
	RID _sampled_rd(int, int) const;
	bool _tier_channel_uses_sampled(int, int) const;
	int _tier_channel_codec(int, int, bool) const { return 1; }
	void _mark_encode_failed(int, uint64_t, uint64_t);
	void _release_encode_page(int);
#if BAKER_READBACK_BUFFER_TOKEN
	void _on_encode_readback(const PackedByteArray &, int, int, int, int, uint64_t, uint64_t, const RID &);
#else
	void _on_encode_readback(const PackedByteArray &, int, int, int, int, uint64_t, uint64_t);
#endif
	void readback(const PackedByteArray &data, uint64_t generation, uint64_t sequence, RID buffer) {
#if BAKER_READBACK_BUFFER_TOKEN
		_on_encode_readback(data, 0, 0, 0, 0, generation, sequence, buffer);
#else
		(void)buffer;
		_on_encode_readback(data, 0, 0, 0, 0, generation, sequence);
#endif
	}
	// The texture and sampler API boundary has no real format/driver in this test.
	static RID _create_texture(RenderingDevice *rd, RenderingDevice::DataFormat, int size,
			int layers, uint64_t, const PackedByteArray & = {}) {
		assert(size > 0 && layers > 0);
		return rd->state.allocate("texture");
	}
	static RID _create_sampler(RenderingDevice *rd, RenderingDevice::SamplerFilter,
			RenderingDevice::SamplerRepeatMode, float) { return rd->state.allocate("sampler"); }
	void _resolve_material_rd(const ResourceBundle &resources, RID &albedo, RID &normal, RID, RID) const {
		albedo = resources.dummy_albedo_rd;
		normal = resources.dummy_normal_rd;
	}
	int _encode_ring_depth_ceiling() const { return 4; }
	void _refresh_encode_ring_capacity() {}

	void compressed() {
		for (auto &tier : _tiers) {
			tier.requested = SURFACE_PAGE_BC7;
			tier.effective = SURFACE_PAGE_BC7;
			tier.normal_effective = 1;
			tier.format = RenderingDevice::BC7;
			tier.format_srgb = RenderingDevice::BC7_SRGB;
			tier.normal_format = RenderingDevice::BC7;
		}
	}
	bool build(int pages = 8, uint64_t generation = 1) {
		return _ensure_resources(generation, pages, _stored_size, {}, {}, {});
	}
	void dispose() {
		_free_bundle(_rd, _resources);
		_resources = {};
		for (const auto &retired : _retired) { _free_bundle(_rd, retired.second); }
		_retired.clear();
	}
};
#define std test_std
#include "baker_methods.inc"
#undef std

static void encoder_failure() {
	for (bool null_spirv : {false, true}) {
		DeviceState state;
		RenderingDevice rd(state);
		RenderingServer server(rd);
		Terrain3DSurfaceBaker baker;
		baker.compressed();
		state.fail_compile = "encode";
		state.null_spirv = null_spirv;
		assert(!baker.build());
		state.assert_empty(); // Baseline loses six compressed textures and six wrappers.
		for (const auto &tier : baker._tiers) {
			assert(tier.effective == 0 && tier.applied == 0 && tier.normal_effective == 0);
			assert(tier.normal_applied == 0 && !tier.params_encoded);
			assert(tier.params_format == RenderingDevice::DATA_FORMAT_MAX);
			assert(tier.requested == SURFACE_PAGE_BC7); // Retain the request for diagnostics.
		}
		state.fail_compile.clear();
		assert(baker.build()); // Retry builds a canonical page-sized bundle.
		assert(baker._staging_layers == 8 && !baker._resources.encode_pipeline.is_valid());
		assert(baker._resources.output_albedo_rs.is_valid());
		baker.dispose();
		state.assert_empty();
	}
	std::cout << "PASS encoder failure: both SPIR-V failures release every sampled RID, then retry canonical\n";
}

static int successful_allocation_count(bool ring_only, bool compressed) {
	DeviceState state;
	RenderingDevice rd(state);
	RenderingServer server(rd);
	Terrain3DSurfaceBaker baker;
	baker._ring_only = ring_only;
	if (compressed) { baker.compressed(); }
	assert(baker.build());
	const int allocations = state.allocations;
	assert(baker._resources.pipeline.is_valid());
	assert(baker._resources.output_albedo_rd.is_valid() != ring_only);
	if (compressed && !ring_only) {
		assert(baker._staging_layers == 4);
		for (const auto &set : baker._resources.sampled) { assert(set.albedo_rs.is_valid() && set.normal_rs.is_valid() && set.params_rs.is_valid()); }
	}
	assert(baker.build() && state.allocations == allocations); // Existing bundle is reused.
	baker.dispose();
	state.assert_empty();
	baker.dispose(); // Empty cleanup is safe.
	state.assert_empty();
	return allocations;
}

static void every_allocation_failure() {
	int tested = 0;
	for (bool ring_only : {false, true}) {
		for (bool compressed : {false, true}) {
			const int count = successful_allocation_count(ring_only, compressed);
			for (int failure = 0; failure < count; ++failure) {
				DeviceState state;
				RenderingDevice rd(state);
				RenderingServer server(rd);
				Terrain3DSurfaceBaker baker;
				baker._ring_only = ring_only;
				if (compressed) { baker.compressed(); }
				state.fail_allocation = failure;
				const bool built = baker.build();
				if (!built) {
					state.assert_empty(); // A failed candidate never reaches _resources.
					assert(!baker._resources.shader.is_valid());
					state.fail_allocation = -1;
					assert(baker.build());
				}
				baker.dispose();
				state.assert_empty();
				++tested;
			}
		}
	}
	std::cout << "PASS allocation rollback: " << tested << " failures across canonical/compressed/ring-only, retries and dependency-safe frees\n";
}

static void growth_and_retirement() {
	for (int failed_copy : {-1, 0, 1, 2, 3, 4, 5}) {
		DeviceState state;
		RenderingDevice rd(state);
		RenderingServer server(rd);
		Terrain3DSurfaceBaker baker;
		assert(baker.build());
		baker._ready[0] = baker._ready[1] = 1;
		const RID previous = baker._resources.output_albedo_rd;
		const size_t old_devices = state.devices.size(), old_wrappers = state.wrappers.size();
		state.fail_copy = failed_copy;
		const bool grown = baker.build(16);
		assert(grown == (failed_copy == -1));
		if (!grown) {
			assert(baker._resources.output_albedo_rd == previous && baker._retired.empty());
			assert(state.devices.size() == old_devices && state.wrappers.size() == old_wrappers);
			state.fail_copy = -1;
			assert(baker.build(16));
		}
		assert(baker._resource_page_count == 16 && baker._retired.size() == 1);
		assert(baker._migrated_pages == 2 && state.devices.count(previous.id));
		const int allocations = state.allocations;
		assert(baker.build(32) && state.allocations == allocations); // Wait for retirement before another growth.
		baker.dispose();
		state.assert_empty();
	}
	std::cout << "PASS growth: six copy failures preserve the live bundle, retry migration, retain old RIDs until retirement\n";
}

static void fallback_and_replacement() {
	for (const char *program : {"bake", "upload"}) {
		DeviceState state;
		RenderingDevice rd(state);
		RenderingServer server(rd);
		Terrain3DSurfaceBaker baker;
		state.fail_compile = program;
		const bool optional = std::string(program) == "upload";
		assert(baker.build() == optional);
		if (optional) { assert(!baker._resources.source_upload_enabled); }
		baker.dispose();
		state.assert_empty();
	}
	DeviceState state;
	RenderingDevice rd(state);
	RenderingServer server(rd);
	Terrain3DSurfaceBaker baker;
	state.support_storage = false;
	assert(baker.build() && !baker._resources.source_upload_enabled);
	const RID previous = baker._resources.output_albedo_rd;
	assert(baker.build(8, 2) && baker._retired.size() == 1 && state.devices.count(previous.id));
	baker.dispose();
	state.assert_empty();
	Terrain3DSurfaceBaker ring;
	ring._ring_only = true;
	assert(ring.build());
	const RID old_shader = ring._resources.shader;
	assert(ring.build(8, 2) && ring._retired.empty() && !state.devices.count(old_shader.id));
	ring.dispose();
	state.assert_empty();
	std::cout << "PASS fallback and replacement: required/optional compilation, unsupported storage, page retirement and ring-core release\n";
}

static void stale_readback() {
	DeviceState state;
	RenderingDevice rd(state);
	RenderingServer server(rd);
	Terrain3DSurfaceBaker baker;
	baker.compressed();
	assert(baker.build());
	const RID old_buffer = baker._resources.encode_buffer;
	assert(baker.build(16)); // Same page generation and sequence, new encoder ring.
	baker._slot_sequence[0] = 10;
	baker._encode_ring_held[0] = 3;
	PackedByteArray bytes;
	bytes.resize(64);
	baker.readback(bytes, 1, 10, old_buffer);
	assert(baker._encode_ring_held[0] == 3 && baker._encoded_layers.empty());
	baker.dispose();
	state.assert_empty();
	std::cout << "PASS stale readback: same-generation growth cannot release or enqueue into the new encoder ring\n";
}

static void queue_lock_order() {
	DeviceState state;
	RenderingDevice rd(state);
	RenderingServer server(rd);
	Terrain3DSurfaceBaker baker;
	baker.compressed();
	assert(baker.build());
	baker._slot_sequence[0] = 10;
	baker._encode_ring_held[0] = 3;
	baker._ready[0] = 1;
	baker._sampled_channel_mask[0] = 7;
	baker._encoded_layers.resize(24);
	PackedByteArray bytes;
	bytes.resize(64);
	baker.readback(bytes, 1, 10, baker._resources.encode_buffer);
	assert(baker._encoded_layers.size() == 24 && baker._encode_ring_held[0] == 2);
	assert(baker._ready[0] == 0 && baker._sampled_channel_mask[0] == 0 && baker._encode_failures == 1);
	baker._encoded_layers.clear();
	baker.readback(bytes, 1, 10, baker._resources.encode_buffer);
	assert(baker._encoded_layers.size() == 1 && baker._encode_ring_held[0] == 1);
	baker.readback(bytes, 1, 9, baker._resources.encode_buffer); // Slot reuse still releases its old reservation.
	assert(baker._encoded_layers.size() == 1 && baker._encode_ring_held[0] == 0);
	baker.readback(bytes, 0, 10, baker._resources.encode_buffer); // Stale generation never queues or underflows.
	assert(baker._encoded_layers.size() == 1 && baker._encode_ring_held[0] == 0);
	bytes.resize(1);
	baker.readback(bytes, 1, 10, baker._resources.encode_buffer);
	assert(baker._encoded_layers.size() == 1 && baker._encode_failures == 2);
	baker.dispose();
	state.assert_empty();
	assert(test_std::mutex::held.empty());
	std::cout << "PASS readback locks: queue overflow, retry, slot reuse, stale generation, invalid data; world-before-encode ordering\n";
}

int main(int argc, char **argv) {
	const std::string selected = argc > 1 ? argv[1] : "all";
	if (selected == "all" || selected == "encoder_failure") { encoder_failure(); }
	if (selected == "all" || selected == "stale_readback") { stale_readback(); }
	if (selected == "all" || selected == "queue_lock_order") { queue_lock_order(); }
	if (selected != "all") { return 0; }
	every_allocation_failure();
	growth_and_retirement();
	fallback_and_replacement();
}
