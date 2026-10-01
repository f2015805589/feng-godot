#include "lifetime_double.h"
#include "feng_godottracy.h"
#include <iostream>

static bool stable(const char *pointer) {
	if (pointer == nullptr) {
		return true;
	}
	for (const auto &entry : tracy::names) {
		if (entry.second->source.name == pointer) {
			return true;
		}
	}
	return false;
}
int main() {
	FengGodotTracy api;
	for (bool connected : {false, true}) {
		boundary::connected = connected;
		for (int i = 0; i < 1000; ++i) {
			api.begin_zone("Repeated dynamic zone");
			assert(api.get_zone_depth() == 1);
			api.begin_zone("Nested dynamic zone");
			assert(api.get_zone_depth() == 2);
			api.end_zone();
			api.end_all_zones();
			assert(api.get_zone_depth() == 0);
		}
	}
	assert(boundary::begins == 4000);
	api.message("dynamic message 中文");
	api.message_colored("colored message 中文", {1, 0.25f, 0});
	assert(boundary::borrowed_messages.empty() && "dynamic messages must be copied");
	assert(boundary::copied_messages == std::vector<std::string>({"dynamic message 中文", "colored message 中文"}));
	api.message(String(65535, 'x'));
	assert(boundary::copied_messages.size() == 2 && "oversized messages must not hit Tracy's uint16 assertion");
	for (int i = 0; i < 1000; ++i) {
		api.plot("Stable plot 中文", 0.5);
		api.frame_mark("Stable frame 中文");
	}
	api.frame_mark();
	assert(tracy::names.size() == 2 && "repeated categories must reuse the engine interner");
	for (const char *name : boundary::plots) { assert(stable(name)); assert(std::string(name) == "Stable plot 中文"); }
	for (const char *name : boundary::frames) { assert(stable(name)); if (name) { assert(std::string(name) == "Stable frame 中文"); } }
	assert(boundary::plots.front() == boundary::plots.back());
	assert(boundary::frames.back() == nullptr);
	// Zone state belongs to each calling thread, including while disconnected.
	std::thread worker([&]() { api.begin_zone("worker"); assert(api.get_zone_depth() == 1); api.end_zone(); });
	worker.join();
	assert(api.get_zone_depth() == 0);
	std::cout << "PASS actual Tracy module: source ownership, copied UTF-8, stable category names, nested/thread-local zones\n";
}
