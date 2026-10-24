extends RefCounted
## Tracks failures after the D3D12 ray-tracing capability check.
##
## A failed diffuse attempt releases ownership on the next renderer plan. After a
## short cooldown, one frame may retry so transient resource/device setup failures
## can recover without leaving MagicGI disabled forever.

const RETRY_INTERVAL_FRAMES := 120

var failure_reason := ""
var failure_frame := -1
var last_success_frame := -1


func get_status(hardware_supported: bool, hardware_reason: String, device: String,
		current_frame: int) -> Dictionary:
	if not hardware_supported:
		return {"available": false, "hardware_supported": false, "state": "unsupported",
			"reason": hardware_reason, "device": device}
	if not failure_reason.is_empty():
		var elapsed := maxi(0, current_frame - failure_frame)
		if elapsed < RETRY_INTERVAL_FRAMES:
			return {"available": false, "hardware_supported": true, "state": "cooldown",
				"reason": failure_reason, "device": device,
				"failure_frame": failure_frame,
				"retry_in_frames": RETRY_INTERVAL_FRAMES - elapsed}
		return {"available": true, "hardware_supported": true, "state": "retry_probe",
			"reason": "", "device": device,
			"previous_failure_reason": failure_reason,
			"failure_frame": failure_frame}
	return {"available": true, "hardware_supported": true,
		"state": "ready" if last_success_frame >= 0 else "probe_pending",
		"reason": "", "device": device,
		"last_success_frame": last_success_frame}


func report_diffuse_result(success: bool, reason: String, current_frame: int) -> void:
	if success:
		failure_reason = ""
		failure_frame = -1
		last_success_frame = current_frame
	else:
		failure_reason = reason if not reason.is_empty() else "diffuse_composite_not_dispatched"
		failure_frame = current_frame


func reset() -> void:
	failure_reason = ""
	failure_frame = -1
	last_success_frame = -1
