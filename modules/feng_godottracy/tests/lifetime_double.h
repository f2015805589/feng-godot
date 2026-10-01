// Narrow engine/Tracy boundary double for the unmodified production translation unit.
#pragma once
#include <algorithm>
#include <any>
#include <cassert>
#include <cstdint>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#define GDCLASS(a, b)
#define D_METHOD(...) "method"
#define DEFVAL(...) 0
#define CLAMP(value, low, high) std::clamp(value, low, high)
#define ERR_FAIL_COND_MSG(condition, message) do { if (condition) { return; } } while (false)
struct Object {};
struct Color { float r = 0, g = 0, b = 0; };
namespace boundary {
inline std::map<const char *, bool> temporary_buffers;
inline std::vector<const char *> borrowed_messages, plots, frames;
inline std::vector<std::string> copied_messages;
inline std::map<uint64_t, bool> source_live;
inline uint64_t next_source = 1;
inline int begins = 0;
inline bool connected = false;
}
struct CharString {
	std::string data;
	explicit CharString(std::string value) : data(std::move(value)) { boundary::temporary_buffers[data.c_str()] = true; }
	~CharString() { boundary::temporary_buffers[data.c_str()] = false; }
	const char *get_data() const { return data.c_str(); }
	size_t length() const { return data.size(); }
};
struct String : std::string {
	using std::string::string;
	String(const std::string &value) : std::string(value) {}
	CharString utf8() const { return CharString(*this); }
	bool is_empty() const { return empty(); }
	bool is_valid_int() const { return false; }
	int to_int() const { return 0; }
};
using StringName = String;
template <typename... T> String vformat(const char *value, const T &...) { return String(value); }
struct Variant { template <typename T> Variant &operator=(const T &) { return *this; } };
struct Dictionary { Variant &operator[](const char *) { static Variant value; return value; } };
struct ClassDB { template <typename... T> static void bind_method(T...) {} };
struct OS { static OS *get_singleton() { static OS os; return &os; } String get_environment(const char *) const { return {}; } };
struct Thread { static uint64_t get_caller_id() { return std::hash<std::thread::id>()(std::this_thread::get_id()); } };
using Mutex = std::mutex;
struct MutexLock { std::unique_lock<Mutex> guard; explicit MutexLock(Mutex &mutex) : guard(mutex) {} };
template <typename T> struct Vector : std::vector<T> {
	bool is_empty() const { return this->empty(); }
	const T *ptr() const { return this->data(); }
	void remove_at(size_t index) { this->erase(this->begin() + index); }
};
template <typename K, typename V> struct HashMap : std::map<K, V> {
	V *getptr(const K &key) { auto it = this->find(key); return it == this->end() ? nullptr : &it->second; }
	void insert(const K &key, const V &value) { (*this)[key] = value; }
};
namespace tracy {
namespace Version { constexpr int Major = 0, Minor = 11, Patch = 1; }
constexpr int ProtocolVersion = 69;
struct SourceLocationData { const char *name; };
struct Interned { std::string name; SourceLocationData source; explicit Interned(std::string value) : name(std::move(value)), source{name.c_str()} {} };
inline std::map<std::string, std::unique_ptr<Interned>> names;
inline std::mutex names_mutex;
inline const SourceLocationData *intern_source_location(const void *, const StringName &, const StringName &, const StringName &name, uint32_t, bool) {
	std::lock_guard<std::mutex> lock(names_mutex);
	auto &entry = names[name];
	if (!entry) { entry = std::make_unique<Interned>(name); }
	return &entry->source;
}
}
struct TracyCZoneCtx { uint32_t id = 0; int active = 0; };
#define TracyCIsStarted 1
inline int ___tracy_connected() { return boundary::connected; }
inline void ___tracy_emit_messageL(const char *text, int) { boundary::borrowed_messages.push_back(text); }
inline void ___tracy_emit_messageLC(const char *text, uint32_t, int) { boundary::borrowed_messages.push_back(text); }
inline void ___tracy_emit_message(const char *text, size_t size, int) { boundary::copied_messages.emplace_back(text, size); }
inline void ___tracy_emit_messageC(const char *text, size_t size, uint32_t, int) { boundary::copied_messages.emplace_back(text, size); }
inline void ___tracy_emit_plot(const char *name, double) { boundary::plots.push_back(name); }
inline void ___tracy_emit_frame_mark(const char *name) { boundary::frames.push_back(name); }
inline void ___tracy_set_thread_name(const char *) {}
inline uint64_t ___tracy_alloc_srcloc_name(uint32_t, const char *, size_t, const char *, size_t, const char *, size_t, uint32_t) {
	const uint64_t id = boundary::next_source++;
	boundary::source_live[id] = true;
	return id;
}
inline TracyCZoneCtx ___tracy_emit_zone_begin_alloc(uint64_t source, int active) {
	// Actual Tracy consumes/frees this payload once. Detect misuse deterministically
	// even when its fast allocator would make a duplicate free appear to succeed.
	assert(boundary::source_live.at(source) && "source-location payload reused after transfer");
	boundary::source_live[source] = false;
	++boundary::begins;
	return {uint32_t(boundary::begins), active && boundary::connected};
}
inline void ___tracy_emit_zone_end(TracyCZoneCtx) {}
