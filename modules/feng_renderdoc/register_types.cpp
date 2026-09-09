#include "register_types.h"

#include "feng_renderdoc.h"

#include "core/object/class_db.h"

#include "modules/register_module_types.h"

static FengRenderDoc *_feng_renderdoc = nullptr;

void initialize_feng_renderdoc_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SERVERS) {
		return;
	}

	_feng_renderdoc = memnew(FengRenderDoc);
	ClassDB::register_class<FengRenderDoc>();

}

void uninitialize_feng_renderdoc_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SERVERS) {
		return;
	}
	if (_feng_renderdoc) {
		memdelete(_feng_renderdoc);
		_feng_renderdoc = nullptr;
	}
}
