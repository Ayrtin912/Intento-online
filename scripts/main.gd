# main.gd
# Script principal que maneja el lobby y spawning de jugadores/autos
extends Node3D
var adds
# Referencias a los nodos necesarios
@onready var multiplayer_spawner: MultiplayerSpawner = $MultiplayerSpawner
@onready var spawn_points: Node3D = $SpawnPoints  # Contenedor de spawn points

# Prefabs (scenes) que se van a instanciar
@export var player_scene: PackedScene
@export var auto_scene: PackedScene

# Diccionario para trackear instancias de jugadores
var players := {}  # {peer_id: Player node}
var auto_instance: RigidBody3D = null

func _ready() -> void:
	# Solo mostrar el lobby si no estamos en red todavía
	if not multiplayer.has_multiplayer_peer():
		_show_lobby()
	else:
		_start_game()
	
	# Conectar señales del NetworkManager
	NetworkManager.server_created.connect(_on_server_created)
	NetworkManager.connection_succeeded.connect(_on_connection_succeeded)
	NetworkManager.player_connected.connect(_on_player_connected)
	NetworkManager.player_disconnected.connect(_on_player_disconnected)

# ===== LOBBY UI =====
func _show_lobby() -> void:
	# Aquí podrías crear UI programáticamente o tener una escena separada
	# Por simplicidad, vamos a crear botones básicos
	var lobby = Control.new()
	lobby.name = "Lobby"
	lobby.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(lobby)
	
	var vbox = VBoxContainer.new()
	vbox.position = Vector2(50, 50)
	lobby.add_child(vbox)
	
	var label = Label.new()
	label.text = "Multiplayer Lobby"
	label.add_theme_font_size_override("font_size", 24)
	vbox.add_child(label)
	
	# Botón Host
	var host_btn = Button.new()
	host_btn.text = "Crear Servidor (Host)"
	host_btn.pressed.connect(_on_host_pressed)
	vbox.add_child(host_btn)
	
	# IP Input
	var ip_input = LineEdit.new()
	ip_input.placeholder_text = "IP (ej: 127.0.0.1)"
	ip_input.text = "127.0.0.1"
	ip_input.name = "IPInput"
	vbox.add_child(ip_input)
	
	# Botón Join
	var join_btn = Button.new()
	join_btn.text = "Unirse a Servidor"
	join_btn.pressed.connect(_on_join_pressed.bind(ip_input))
	vbox.add_child(join_btn)
	
	# Status label
	var status = Label.new()
	status.name = "StatusLabel"
	status.text = ""
	vbox.add_child(status)

func _on_host_pressed() -> void:
	_update_status("Creando servidor...")
	NetworkManager.create_server()

func _on_join_pressed(ip_input: LineEdit) -> void:
	var ip = ip_input.text
	if ip.is_empty():
		_update_status("❌ Ingresá una IP")
		return
	_update_status("Conectando a " + ip + "...")
	NetworkManager.join_server(ip)

func _update_status(text: String) -> void:
	var lobby = get_node_or_null("Lobby")
	if lobby:
		var status = lobby.get_node_or_null("VBoxContainer/StatusLabel")
		if status:
			status.text = text

# ===== CALLBACKS DE RED =====

func _on_server_created() -> void:
	_update_status("✅ Servidor creado!")
	await get_tree().create_timer(0.5).timeout
	_start_game()

func _on_connection_succeeded() -> void:
	_update_status("✅ Conectado!")
	await get_tree().create_timer(0.5).timeout
	_start_game()

func _on_player_connected(peer_id: int) -> void:
	print("🎮 Spawneando jugador para peer: ", peer_id)
	# El host spawnea jugadores para todos (incluyendo él mismo)
	if multiplayer.is_server():
		_spawn_player(peer_id)

func _on_player_disconnected(peer_id: int) -> void:
	print("🗑️ Removiendo jugador: ", peer_id)
	if players.has(peer_id):
		players[peer_id].queue_free()
		players.erase(peer_id)

# ===== SPAWN LOGIC =====

func _start_game() -> void:
	# Remover lobby UI
	var lobby = get_node_or_null("Lobby")
	if lobby:
		lobby.queue_free()
	
	# El HOST spawnea el auto (solo una instancia compartida)
	if multiplayer.is_server():
		_spawn_auto()
		
		# Spawnear jugadores para todos los que ya están conectados
		for peer_id in NetworkManager.players_info.keys():
			_spawn_player(peer_id)

func _spawn_auto() -> void:
	if auto_instance != null:
		return  # Ya existe
	
	auto_instance = auto_scene.instantiate()
	auto_instance.name = "Auto"
	
	# Posicionar el auto
	auto_instance.global_position = Vector3(0, 2, 5)
	
	# CRÍTICO: El auto es autoridad del servidor (peer_id = 1)
	# Esto significa que SOLO el host simula la física
	auto_instance.set_multiplayer_authority(1)
	
	add_child(auto_instance, true)  # true = spawn en red
	print("🚗 Auto spawneado")

func _spawn_player(peer_id: int) -> void:
	if players.has(peer_id):
		return  # Ya existe
	
	var player = player_scene.instantiate()
	player.name = "Player_" + str(peer_id)
	
	# Asignar autoridad: cada jugador controla su propio personaje
	player.set_multiplayer_authority(peer_id)
	
	# Posicionar en spawn point
	var spawn_pos = _get_spawn_position(peer_id)
	player.global_position = spawn_pos
	
	players[peer_id] = player
	add_child(player, true)  # true = spawn en red
	
	print("👤 Jugador spawneado: ", player.name, " en ", spawn_pos)

func _get_spawn_position(peer_id: int) -> Vector3:
	# Spawn points simples: distribuir en círculo
	var angle = (peer_id - 1) * (PI / 2.0)  # 90° entre cada uno
	var radius = 3.0
	return Vector3(cos(angle) * radius, 1.0, sin(angle) * radius)
