// Cache-context regression over the actual production cache sections.
#include <condition_variable>
#include <atomic>
#include <cstdint>
#include <iostream>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

using real_t = double;
using Array = std::vector<uint32_t>;
struct Bytes {
	uint32_t value = 0;
	bool is_empty() const { return value == 0; }
};
struct Variant {
	Bytes bytes;
	explicit Variant(Bytes p_bytes) : bytes(p_bytes) {}
	uint32_t hash() const { return bytes.value; }
};
struct Vector2i { int x, y; };
namespace TerrainVTCell {
std::atomic<int> computations{0};
Array source_hashes(uint32_t a, uint32_t b, uint32_t c) { return {a, b, c}; }
// Deliberately small hash double: every identity component affects the answer.
template <class F>
uint32_t signature(int64_t materials, real_t density, real_t spacing, int size, F read) {
	++computations;
	uint32_t value = uint32_t(materials) * 31 + uint32_t(density * 1000) * 37 +
			uint32_t(spacing * 1000) * 41 + uint32_t(size) * 43;
	for (int y = -1; y <= 1; ++y) {
		for (int x = -1; x <= 1; ++x) {
			value = value * 16777619u ^ uint32_t((y + 1) * 3 + x + 1);
			for (const uint32_t hash : read(x, y)) { value = value * 16777619u ^ hash; }
		}
	}
	return value;
}
}

struct Cell { Bytes controls, ids, heights; };
struct Snapshot {
	real_t spacing = 1;
	int region_size = 64;
	std::map<std::pair<int, int>, Cell> cells;
};
struct Request { bool svt = true; uint32_t materials = 3; real_t density = 1; };
struct Entry { Request request; std::shared_ptr<const Snapshot> source; };

class Cache {
	std::mutex _cache_mutex;
	std::shared_ptr<const Snapshot> _signature_source;
	uint32_t _signature_materials = 0;
	real_t _signature_density = 0;
	std::map<std::pair<int, int>, uint32_t> _signatures;
public:
	void prepare(const Entry &job) {
		(void)job;
#include "prepare.inc"
	}
	uint32_t lookup(const Request &request, const std::shared_ptr<const Snapshot> &p_source, int x) {
		const Snapshot &source = *p_source;
		const auto &entry = *source.cells.find({x, 0});
		const Vector2i location{entry.first.first, entry.first.second};
#include "signature.inc"
		return hash;
	}
};

using DecodedChannels = std::map<std::string, std::shared_ptr<int>>;

struct CellCache {
	std::map<std::string, DecodedChannels> entries;
	bool has(const std::string &key) const { return entries.find(key) != entries.end(); }
	DecodedChannels &operator[](const std::string &key) { return entries[key]; }
	void clear() { entries.clear(); }
	std::size_t size() const { return entries.size(); }
};

class CellAdmission {
public:
	std::mutex _cache_mutex;
	CellCache _cell_cache;
	uint64_t _cache_bytes = 0;

	DecodedChannels retain(const std::string &key, uint64_t bytes, const DecodedChannels &decoded) {
		const std::string cache_key = key;
		DecodedChannels channels = decoded;
#include "admission.inc"
		return channels;
	}
};

bool test_cell_cache_admission() {
	const auto image = std::make_shared<int>(17);
	const DecodedChannels decoded = { { "albedo_height", image }, { "normal_roughness", image }, { "params", image } };
	constexpr uint64_t limit = 256ull * 1024 * 1024;

	CellAdmission normal;
	const DecodedChannels normal_result = normal.retain("normal", 1024, decoded);
	if (!normal._cell_cache.has("normal") || normal._cache_bytes != 1024 || normal_result.at("params") != image) {
		std::cerr << "FAIL normal decoded-cell cache admission\n";
		return false;
	}

	CellAdmission exact;
	const DecodedChannels exact_result = exact.retain("exact", limit, decoded);
	if (!exact._cell_cache.has("exact") || exact._cache_bytes != limit || exact_result.at("normal_roughness") != image) {
		std::cerr << "FAIL exact-budget decoded-cell admission\n";
		return false;
	}

	CellAdmission aggregate;
	aggregate.retain("old", limit - 8, decoded);
	const DecodedChannels aggregate_result = aggregate.retain("new", 16, decoded);
	if (aggregate._cell_cache.size() != 1 || aggregate._cell_cache.has("old") || !aggregate._cell_cache.has("new") ||
			aggregate._cache_bytes != 16 || aggregate_result.at("albedo_height") != image) {
		std::cerr << "FAIL aggregate decoded-cell cache eviction\n";
		return false;
	}

	CellAdmission oversized;
	oversized.retain("kept", 10, decoded);
	const DecodedChannels oversized_result = oversized.retain("too-large", limit + 1, decoded);
	if (oversized._cell_cache.size() != 1 || !oversized._cell_cache.has("kept") || oversized._cell_cache.has("too-large") ||
			oversized._cache_bytes != 10 || oversized_result.at("params") != image) {
		std::cerr << "FAIL oversized decoded cell must bypass retention and preserve current channels\n";
		return false;
	}

	CellAdmission entries;
	for (int i = 0; i < 64; ++i) { entries.retain("entry-" + std::to_string(i), 1, decoded); }
	entries.retain("entry-64", 1, decoded);
	if (entries._cell_cache.size() != 1 || !entries._cell_cache.has("entry-64") || entries._cache_bytes != 1) {
		std::cerr << "FAIL 64-entry decoded-cell cache eviction\n";
		return false;
	}

	return true;
}

// Every transition is a condition-variable handoff. No sleeps, timing races or
// probabilistic stress are needed to hold old/new jobs in flight at once.
class Steps {
	std::mutex mutex;
	std::condition_variable condition;
	int current = 0;
public:
	void wait(int wanted) {
		std::unique_lock<std::mutex> lock(mutex);
		condition.wait(lock, [&] { return current >= wanted; });
	}
	void advance(int next) {
		std::lock_guard<std::mutex> lock(mutex);
		current = next;
		condition.notify_all();
	}
};

uint32_t uncached(const Entry &job, int cell) {
	Cache fresh;
	fresh.prepare(job);
	return fresh.lookup(job.request, job.source, cell);
}

bool interleave(const Entry &a, const Entry &b, const char *label) {
	Cache cache;
	Steps steps;
	const int before = TerrainVTCell::computations.load();
	uint32_t a_hash[2] = {}, b_hash[2] = {};
	std::thread old_job([&] {
		cache.prepare(a);
		steps.advance(1);
		steps.wait(2);
		a_hash[0] = cache.lookup(a.request, a.source, 0);
		steps.advance(3);
		steps.wait(4);
		a_hash[1] = cache.lookup(a.request, a.source, 1);
		steps.advance(5);
	});
	std::thread new_job([&] {
		steps.wait(1);
		cache.prepare(b);
		steps.advance(2);
		steps.wait(3);
		b_hash[0] = cache.lookup(b.request, b.source, 0);
		steps.advance(4);
		steps.wait(5);
		b_hash[1] = cache.lookup(b.request, b.source, 1);
	});
	old_job.join();
	new_job.join();
	bool valid = true;
	const bool same_context = a.source == b.source && a.request.materials == b.request.materials &&
			a.request.density == b.request.density;
	const int computed = TerrainVTCell::computations.load() - before;
	if (computed != (same_context ? 2 : 4)) {
		std::cerr << "FAIL " << label << " computations=" << computed
				<< " expected=" << (same_context ? 2 : 4) << '\n';
		valid = false;
	}
	for (int cell = 0; cell < 2; ++cell) {
		const auto expected_a = uncached(a, cell), expected_b = uncached(b, cell);
		if (a_hash[cell] != expected_a || b_hash[cell] != expected_b) {
			std::cerr << "FAIL " << label << " cell=" << cell << " old=" << a_hash[cell]
					<< "/" << expected_a << " new=" << b_hash[cell] << "/" << expected_b << '\n';
			valid = false;
		}
	}
	return valid;
}

bool concurrent_stress(const Entry *jobs, int count) {
	std::vector<std::vector<uint32_t>> expected(count);
	for (int i = 0; i < count; ++i) {
		expected[i] = {uncached(jobs[i], 0), uncached(jobs[i], 1)};
	}
	Cache cache;
	Steps start;
	std::atomic<int> failed{0};
	std::vector<std::thread> workers;
	for (int i = 0; i < count; ++i) {
		workers.emplace_back([&, i] {
			cache.prepare(jobs[i]);
			start.wait(1);
			for (int lookup = 0; lookup < 1000; ++lookup) {
				if (cache.lookup(jobs[i].request, jobs[i].source, lookup % 2) != expected[i][lookup % 2]) {
					++failed;
				}
			}
		});
	}
	start.advance(1);
	for (auto &worker : workers) { worker.join(); }
	if (failed) { std::cerr << "FAIL concurrent signatures=" << failed << '\n'; }
	return failed == 0;
}

int main() {
	if (!test_cell_cache_admission()) { return 1; }
	auto first = std::make_shared<Snapshot>();
	first->cells[{0, 0}] = {{11}, {12}, {13}};
	first->cells[{1, 0}] = {{21}, {22}, {23}};
	auto second = std::make_shared<Snapshot>(*first);
	second->cells[{1, 0}].heights.value = 97;
	const Entry a{{true, 3, 1}, first};
	const Entry jobs[] = {
		{{true, 3, 1}, second}, {{true, 7, 1}, first}, {{true, 3, 2}, first},
		{{true, 7, 2}, second}, a, {{true, 3, 1}, std::make_shared<Snapshot>(*first)},
	};
	const char *labels[] = {"snapshot", "materials", "density", "all", "same-context", "equal-content-new-snapshot"};
	int failed = 0;
	for (int scenario = 0; scenario < 6; ++scenario) {
		if (!interleave(a, jobs[scenario], labels[scenario])) { ++failed; }
	}
	if (failed) { std::cerr << failed << "/6 signature scenarios failed\n"; return 1; }
	if (!concurrent_stress(jobs, 6)) { return 1; }
	std::cout << "PASS decoded-cell cache budget boundaries, 6 deterministic two-worker scenarios (24 lookups/cache reuse), 6000 concurrent lookups\n";
}
