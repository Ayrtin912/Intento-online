extends CharacterBody3D

# UI + debug line
@export var crosshair_size := 3.0
@export var crosshair_color := Color(1, 1, 1, 0.9)
@export var grab_line_radius := 0.01
@export var grab_line_color := Color(0.2, 0.8, 1.0, 0.95)

var _crosshair: ColorRect
var _ui_layer: CanvasLayer

var _grab_line: MeshInstance3D
var _grab_line_mesh: CylinderMesh
var _grab_line_mat: StandardMaterial3D
var _drag_start_world := Vector3.ZERO

# CharacterController.gd
# Godot 4.x (attach to a CharacterBody3D)
@export var grab_ray_length: float = 4.0
@export var grab_kp: float = 180.0          # spring strength
@export var grab_kd: float = 22.0           # damping on the grabbed point's velocity
@export var grab_max_force: float = 440.0  # clamp for stability
@export var grab_dist_limits := Vector2(0.6, 8.0)

var _grabbed: RigidBody3D
var _grab_local: Vector3
var _grab_distance: float = 0.0



@export var walk_speed: float = 5.0
@export var sprint_speed: float = 9.0
@export var jump_velocity: float = 4.5
@export var mouse_sensitivity: float = 0.002   # radians per pixel
@export var invert_y: bool = false
@export var show_mesh: bool = true            # first-person => off by default

var _yaw: float = 0.0
var _pitch: float = 0.0
var _head: Node3D
var _camera: Camera3D

const _PITCH_LIMIT := deg_to_rad(89.0)

func _ready() -> void:
	# Capture mouse for FPS look
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	_build_rig()
	_ensure_input_map()

@export var push_impulse_scale := 2.0

func _physics_process(delta: float) -> void:
	# Gravity
	var g: float = ProjectSettings.get_setting("physics/3d/default_gravity")
	if not is_on_floor():
		velocity.y -= g * delta

	# Move input -> local space (yaw only)
	var input_vec := Vector2(
		Input.get_action_strength("move_right") - Input.get_action_strength("move_left"),
		Input.get_action_strength("move_back")  - Input.get_action_strength("move_forward")
	)
	if input_vec.length() > 1.0:
		input_vec = input_vec.normalized()

	var speed := sprint_speed if Input.is_action_pressed("sprint") else walk_speed
	var wish_dir := (transform.basis * Vector3(input_vec.x, 0.0, input_vec.y))
	wish_dir.y = 0.0
	if wish_dir.length() > 0.0:
		wish_dir = wish_dir.normalized()

	velocity.x = wish_dir.x * speed
	velocity.z = wish_dir.z * speed

	# Jump
	if is_on_floor() and Input.is_action_just_pressed("jump"):
		velocity.y = jump_velocity

	move_and_slide()
	_update_grab(delta)  # after move_and_slide() and your push-assist loop

func _unhandled_input(event: InputEvent) -> void:
	# Mouse look
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		var dy   :float= event.relative.y
		var dx :float= event.relative.x
		_yaw   -= dx * mouse_sensitivity
		_pitch -= (-dy if invert_y else dy) * mouse_sensitivity
		_pitch = clamp(_pitch, -_PITCH_LIMIT, _PITCH_LIMIT)
		rotation.y = _yaw
		if is_instance_valid(_head):
			_head.rotation.x = _pitch

	# Escape toggles mouse capture
	if event is InputEventKey and event.pressed and event.keycode == Key.KEY_ESCAPE:
		var mode := Input.get_mouse_mode()
		Input.set_mouse_mode(
			Input.MOUSE_MODE_VISIBLE if mode == Input.MOUSE_MODE_CAPTURED else Input.MOUSE_MODE_CAPTURED
		)

	# Left click recaptures if mouse is visible
	if event is InputEventMouseButton and event.button_index == MouseButton.MOUSE_BUTTON_LEFT and event.pressed:
		if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		# Left click recaptures if mouse is visible
	if event is InputEventMouseButton and event.button_index == MouseButton.MOUSE_BUTTON_LEFT and event.pressed:
		if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
			return  # don't start a grab on this click

	# Start/stop grab while captured
	if event is InputEventMouseButton and event.button_index == MouseButton.MOUSE_BUTTON_LEFT:
		if event.pressed:
			_try_start_grab()
		else:
			_stop_grab()

	# Optional: mouse wheel adjusts hold distance while grabbing
	if event is InputEventMouseButton and is_instance_valid(_grabbed):
		if event.button_index == MouseButton.MOUSE_BUTTON_WHEEL_UP:
			_grab_distance = clamp(_grab_distance - 0.3, grab_dist_limits.x, grab_dist_limits.y)
		elif event.button_index == MouseButton.MOUSE_BUTTON_WHEEL_DOWN:
			_grab_distance = clamp(_grab_distance + 0.3, grab_dist_limits.x, grab_dist_limits.y)

func _build_rig() -> void:
	# Collider (capsule)
	var collider := CollisionShape3D.new()
	collider.name = "Collider"
	var shape := CapsuleShape3D.new()
	shape.radius = 0.4
	shape.height = 1.4
	collider.shape = shape
	add_child(collider)

	# Simple visual (capsule mesh) - hidden by default in FPS
	var mesh := MeshInstance3D.new()
	mesh.name = "BodyMesh"
	var cap_mesh := CapsuleMesh.new()
	cap_mesh.radius = shape.radius
	cap_mesh.height = shape.height*2    # CapsuleMesh uses mid_height in Godot 4
	mesh.mesh = cap_mesh
	mesh.visible = show_mesh
	# Keep origin at feet-ish for convenience
	mesh.position = Vector3(0.0, shape.height * 0.5, 0.0)
	add_child(mesh)

	# Head pivot (for pitch) + camera
	_head = Node3D.new()
	_head.name = "Head"
	var camera_height := shape.radius + shape.height * 0.5
	_head.position = Vector3(0.0, camera_height - 0.1, 0.0)
	add_child(_head)

	_camera = Camera3D.new()
	_camera.name = "Camera"
	_camera.current = true
	_head.add_child(_camera)

	_ui_layer = CanvasLayer.new()
	_ui_layer.name = "HUD"
	add_child(_ui_layer)

	_crosshair = ColorRect.new()
	_crosshair.color = crosshair_color
	_crosshair.size = Vector2(crosshair_size, crosshair_size)
	_crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Anchor to center
	_crosshair.anchor_left = 0.5
	_crosshair.anchor_top = 0.5
	_crosshair.anchor_right = 0.5
	_crosshair.anchor_bottom = 0.5
	_crosshair.position = -_crosshair.size * 0.5
	_ui_layer.add_child(_crosshair)

	# === Grab line (thin cylinder we scale/rotate between start and target) ===
	_grab_line_mesh = CylinderMesh.new()
	_grab_line_mesh.top_radius = grab_line_radius
	_grab_line_mesh.bottom_radius = grab_line_radius
	_grab_line_mesh.height = 1.0

	_grab_line = MeshInstance3D.new()
	_grab_line.mesh = _grab_line_mesh

	_grab_line_mat = StandardMaterial3D.new()
	_grab_line_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_grab_line_mat.albedo_color = grab_line_color
	_grab_line_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_grab_line.material_override = _grab_line_mat

	_grab_line.visible = false
	add_child(_grab_line)

func _ensure_input_map() -> void:
	# Adds sensible defaults if actions are missing
	var map := {
		"move_forward": [Key.KEY_W, Key.KEY_UP],
		"move_back":    [Key.KEY_S, Key.KEY_DOWN],
		"move_left":    [Key.KEY_A, Key.KEY_LEFT],
		"move_right":   [Key.KEY_D, Key.KEY_RIGHT],
		"jump":         [Key.KEY_SPACE],
		"sprint":       [Key.KEY_SHIFT]
	}
	for action in map.keys():
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		for k in map[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = k
			if not InputMap.action_has_event(action, ev):
				InputMap.action_add_event(action, ev)
	
	if not InputMap.has_action("grab"):
		InputMap.add_action("grab")
	var mbe := InputEventMouseButton.new()
	mbe.button_index = MouseButton.MOUSE_BUTTON_LEFT
	if not InputMap.action_has_event("grab", mbe):
		InputMap.action_add_event("grab", mbe)
		
		
func _try_start_grab() -> void:
	if not is_instance_valid(_camera):
		return
	# Ray from camera center
	var vp_size := get_viewport().get_visible_rect().size
	var screen_center := vp_size * 0.5
	var from := _camera.project_ray_origin(screen_center)
	var dir := _camera.project_ray_normal(screen_center)
	var to := from + dir * grab_ray_length

	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [get_rid()]  # ignore the character
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return

	var rb := hit.collider as RigidBody3D
	if rb == null:
		return

	_grabbed = rb
	_grab_local = rb.to_local(hit.position)
	_grab_distance = clamp(from.distance_to(hit.position), grab_dist_limits.x, grab_dist_limits.y)
	_grabbed.sleeping = false
	# NEW: store the world-space start (for the line)
	_drag_start_world = hit.position
	_grab_line.visible = true  # will be positioned in _update_grab()

func _stop_grab() -> void:
	_grabbed = null
	if is_instance_valid(_grab_line):
		_grab_line.visible = false

func _update_grab(delta: float) -> void:
	if not is_instance_valid(_grabbed):
		_grabbed = null
		return
	# Keep the target point along the camera’s center ray at the stored distance
	var vp_size := get_viewport().get_visible_rect().size
	var screen_center := vp_size * 0.5
	var from := _camera.project_ray_origin(screen_center)
	var dir := _camera.project_ray_normal(screen_center).normalized()
	var desired := from + dir * _grab_distance

	# Current world position of the grabbed point on the body
	var world_pt := _grabbed.to_global(_grab_local)
	var com := _grabbed.global_transform.origin
	var r := world_pt - com

	# Velocity at that point: v_point = v_com + ω × r
	var v_point := _grabbed.linear_velocity + _grabbed.angular_velocity.cross(r)

	# PD spring force toward desired point
	var error := desired - world_pt
	var force := error * grab_kp + (-v_point) * grab_kd

	# Clamp for stability
	var f_len := force.length()
	if f_len > grab_max_force:
		force = force * (grab_max_force / max(f_len, 0.0001))

	# Apply at the point (central + matching torque so it feels “held” at the hit)
	_grabbed.apply_central_force(force)
	_grabbed.apply_torque(r.cross(force))
	_grabged_sleep_guard()
		# === Update grab line ===
	if not is_instance_valid(_grab_line):
		return

	var start := _drag_start_world
	var end := desired
	var dir3 := end - start
	var dist := dir3.length()

	if dist < 0.002:
		_grab_line.visible = false
	else:
		_grab_line.visible = true
		_grab_line_mesh.height = dist

		# Place at midpoint
		var mid := start + dir3 * 0.5
		_grab_line.global_transform.origin = mid

		# Build a basis with Y aligned to the line direction
		var y := dir3.normalized()
		var x := y.cross(Vector3.FORWARD)
		if x.length() < 0.01:
			x = y.cross(Vector3.RIGHT)
		x = x.normalized()
		var z := x.cross(y)

		_grab_line.global_transform.basis = Basis(x, y, z)
func _grabged_sleep_guard() -> void:
	# Tiny poke if it tries to fall asleep while grabbed
	if _grabbed.sleeping:
		_grabbed.sleeping = false
