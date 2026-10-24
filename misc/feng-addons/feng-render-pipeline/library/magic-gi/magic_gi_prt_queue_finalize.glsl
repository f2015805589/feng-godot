#[compute]
#version 450
// Queue metadata and indirect arguments are separate buffers. This shader runs
// after the producer barrier and writes arguments before the consumer barrier.
layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) readonly buffer PrtMissQueueControl {
	uint count;
	uint overflow;
} prt_miss_queue_control;

layout(set = 0, binding = 1, std430) writeonly buffer DispatchArgs {
	uint groups_x;
	uint groups_y;
	uint groups_z;
} dispatch_args;

layout(push_constant, std430) uniform FinalizeParams {
	uint pixel_count;
	uint width;
	uint height;
	uint consumer_workgroup_size;
	uint producer_local_size_x;
	uint producer_local_size_y;
} params;

void main() {
	if (prt_miss_queue_control.overflow != 0u) {
		// Recovery scans the same full-view 8x8 grid as the producer and filters
		// by marker value 1 in the consumer. No partially-filled queue is consumed.
		uint local_x = max(params.producer_local_size_x, 1u);
		uint local_y = max(params.producer_local_size_y, 1u);
		dispatch_args.groups_x = max(1u, (params.width + local_x - 1u) / local_x);
		dispatch_args.groups_y = max(1u, (params.height + local_y - 1u) / local_y);
		dispatch_args.groups_z = 1u;
		return;
	}

	uint count = min(prt_miss_queue_control.count, params.pixel_count);
	uint workgroup_size = max(params.consumer_workgroup_size, 1u);
	uint groups_x = (count + workgroup_size - 1u) / workgroup_size;
	// A zero count still gets a legal dispatch. Every lane returns before queue
	// or image access because its queue_index is >= count.
	dispatch_args.groups_x = max(groups_x, 1u);
	dispatch_args.groups_y = 1u;
	dispatch_args.groups_z = 1u;
}
