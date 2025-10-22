extends RigidBody3D

@export var hover_height := 1.0          # meters (target: bottom of collider to ground)
@export var ray_length := 2.0            # meters
@export var height_kp := 800.0           # spring (N per meter)
@export var height_kd := 24.0           # damper (N per m/s)
@export var upright_kp := 30.0           # torque gain
@export var upright_kd := 4.0            # angular damping gain
@export var max_up_force := 40.0       # clamp for stability

@onready var _collider: CollisionShape3D = $"CollisionShape3D"
var _box: BoxShape3D
var _local_bottom := Vector3.ZERO
var _ray: RayCast3D

func _ready() -> void:
	_box = _collider.shape as BoxShape3D
	if _box == null:
		push_warning("Expected a BoxShape3D on the collider.")
		return

	# Bottom of the collider in its local space (BoxShape3D.size is FULL size in Godot 4)
	_local_bottom = Vector3(0.0, -_box.size.y * 0.5, 0.0)

	# Single RayCast3D: origin at collider bottom, target 2m below in GLOBAL space.
	_ray = RayCast3D.new()
	_ray.collide_with_areas = false
	_ray.collide_with_bodies = true
	add_child(_ray)
	_ray.enabled = true
	_place_raycast()

	can_sleep = false  # keep it active so it continuously stabilizes

func _place_raycast() -> void:
	var start_global := _collider.to_global(_local_bottom)
	var end_global := start_global + Vector3.DOWN * ray_length
	_ray.global_transform.origin = start_global
	# RayCast3D.target_position is local to the ray; convert world end to local:
	_ray.target_position = _ray.to_local(end_global)

func _physics_process(delta: float) -> void:
	if _box == null:
		return

	# Keep the ray attached to the collider bottom in world space each tick.
	_place_raycast()

	# --- Hover control (vertical only) ---
	if _ray.is_colliding():
		var start_global := _ray.global_transform.origin
		var hit_point := _ray.get_collision_point()
		var distance := start_global.distance_to(hit_point)  # bottom-of-collider → ground

		# PD controller on height (positive = push up)
		var up := Vector3.UP
		var v_up := linear_velocity.dot(up)
		var height_error := hover_height - distance

		var spring := height_kp * height_error
		var damper := -height_kd * v_up

		# Gravity compensation so 0 error holds level
		var g_scalar := ProjectSettings.get_setting("physics/3d/default_gravity") as float
		var gravity_comp := mass * g_scalar

		var force_up := spring + damper + gravity_comp
		force_up = clamp(force_up, 0.0, max_up_force)  # no downward push; let gravity handle that

		# Apply central upward force
		apply_central_force(up * force_up)
	# If no hit within ray_length, do nothing vertical: gravity will bring it back.

	# --- Upright stabilization (roll/pitch only) ---
	# Align the body's up (basis.y) to world up; yaw remains unconstrained.
	var current_up := global_transform.basis.y.normalized()
	var desired_up := Vector3.UP
	var error_axis := current_up.cross(desired_up)  # direction to rotate current_up toward desired_up

	# PD torque: proportional to tilt, damped by angular velocity
	var torque := error_axis * upright_kp - angular_velocity * upright_kd
	apply_torque(torque)
	
	var fuck_niggers
	pass
	
