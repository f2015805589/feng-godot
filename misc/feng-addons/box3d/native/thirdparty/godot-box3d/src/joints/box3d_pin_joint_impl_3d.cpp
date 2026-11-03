#include "box3d_pin_joint_impl_3d.hpp"

#include <box3d/box3d.h>

Box3DPinJointImpl3D::Box3DPinJointImpl3D(
		Box3DBodyImpl3D* p_body_a,
		Box3DBodyImpl3D* p_body_b,
		const Transform3D& p_local_frame_a,
		const Transform3D& p_local_frame_b) :
		Box3DJointImpl3D(p_body_a, p_body_b, p_local_frame_a, p_local_frame_b) {
}

b3JointId Box3DPinJointImpl3D::_create_joint_id(b3WorldId p_world_id, b3BodyId p_body_a, b3BodyId p_body_b, b3Transform p_local_frame_a, b3Transform p_local_frame_b) {
	b3SphericalJointDef def = b3DefaultSphericalJointDef();
	def.base.bodyIdA = p_body_a;
	def.base.bodyIdB = p_body_b;
	def.base.localFrameA = p_local_frame_a;
	def.base.localFrameB = p_local_frame_b;
	// Godot PinJoint3D constrains translation only. Box3D's spherical spring
	// is ANGULAR: enabling it would incorrectly restore the initial rotation
	// (and make a ragdoll hold its rest pose).
	def.enableSpring = false;
	return b3CreateSphericalJoint(p_world_id, &def);
}

real_t Box3DPinJointImpl3D::get_param(Param p_param) const {
	switch (p_param) {
		case PhysicsServer3D::PIN_JOINT_DAMPING:
			return damping;
		case PhysicsServer3D::PIN_JOINT_BIAS:
			return bias;
		case PhysicsServer3D::PIN_JOINT_IMPULSE_CLAMP:
			return impulse_clamp;
		default:
			return 0.0;
	}
}

void Box3DPinJointImpl3D::set_param(Param p_param, real_t p_value) {
	switch (p_param) {
		case PhysicsServer3D::PIN_JOINT_DAMPING:
			damping = p_value;
			if (p_value != 1.0) {
				WARN_PRINT_ONCE("Box3D: PinJoint3D's nondefault linear DAMPING has no Box3D equivalent and is ignored.");
			}
			break;
		case PhysicsServer3D::PIN_JOINT_BIAS:
			bias = p_value;
			if (!Math::is_equal_approx(p_value, (real_t)0.3)) {
				WARN_PRINT_ONCE("Box3D: PinJoint3D's nondefault linear BIAS has no Box3D equivalent and is ignored.");
			}
			break;
		case PhysicsServer3D::PIN_JOINT_IMPULSE_CLAMP:
			impulse_clamp = p_value;
			if (p_value != 0) {
				WARN_PRINT_ONCE("Box3D: PinJoint3D's nonzero IMPULSE_CLAMP has no Box3D equivalent and is ignored.");
			}
			break;
		default:
			break;
	}
}
