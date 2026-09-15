#include "register_types.h"

#include "feng_godottracy.h"

#include "core/config/engine.h"
#include "core/object/class_db.h"

static FengGodotTracy *_feng_godottracy = nullptr;

void initialize_feng_godottracy_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}

	ClassDB::register_class<FengGodotTracy>();
	// The singleton makes the class name usable from scripts and keeps the
	// object alive for the whole run.
	_feng_godottracy = memnew(FengGodotTracy);
	Engine::get_singleton()->add_singleton(Engine::Singleton("FengGodotTracy", _feng_godottracy));
}

void uninitialize_feng_godottracy_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	if (_feng_godottracy) {
		Engine::get_singleton()->remove_singleton("FengGodotTracy");
		memdelete(_feng_godottracy);
		_feng_godottracy = nullptr;
	}
}
