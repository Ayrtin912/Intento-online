# network_manager.gd
# AutoLoad singleton para manejar la conexión multiplayer
extends Node

# Señales para comunicar eventos de red
signal player_connected(peer_id: int)
signal player_disconnected(peer_id: int)
signal connection_failed()
signal connection_succeeded()
signal server_created()

const DEFAULT_PORT = 7000
const MAX_PLAYERS = 4

# Información del jugador local
var player_name := "Player"
var players_info := {}  # {peer_id: {name: String}}

func _ready() -> void:
	# Conectar señales del multiplayer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

# ===== HOST: Crear servidor =====
func create_server(port: int = DEFAULT_PORT) -> void:
	var peer = ENetMultiplayerPeer.new()
	var error = peer.create_server(port, MAX_PLAYERS)
	
	if error != OK:
		push_error("No se pudo crear el servidor: " + str(error))
		connection_failed.emit()
		return
	
	multiplayer.multiplayer_peer = peer
	
	# El host también es un jugador
	players_info[1] = {"name": player_name}
	
	print("✅ Servidor creado en puerto ", port)
	server_created.emit()

# ===== CLIENT: Unirse a servidor =====
func join_server(ip: String, port: int = DEFAULT_PORT) -> void:
	var peer = ENetMultiplayerPeer.new()
	var error = peer.create_client(ip, port)
	
	if error != OK:
		push_error("No se pudo conectar al servidor: " + str(error))
		connection_failed.emit()
		return
	
	multiplayer.multiplayer_peer = peer
	print("🔄 Intentando conectar a ", ip, ":", port)

# ===== CALLBACKS DE RED =====

# Se llama en TODOS los peers cuando alguien nuevo se conecta
func _on_peer_connected(id: int) -> void:
	print("👤 Peer conectado: ", id)
	player_connected.emit(id)

# Se llama en TODOS los peers cuando alguien se desconecta
func _on_peer_disconnected(id: int) -> void:
	print("👋 Peer desconectado: ", id)
	if players_info.has(id):
		players_info.erase(id)
	player_disconnected.emit(id)

# Se llama SOLO en el cliente cuando se conecta exitosamente al host
func _on_connected_to_server() -> void:
	print("✅ Conectado al servidor!")
	var my_id = multiplayer.get_unique_id()
	players_info[my_id] = {"name": player_name}
	
	# Registrar nuestro nombre en el servidor
	register_player.rpc_id(1, player_name)
	connection_succeeded.emit()

# Se llama SOLO en el cliente si falla la conexión
func _on_connection_failed() -> void:
	print("❌ Falló la conexión")
	multiplayer.multiplayer_peer = null
	connection_failed.emit()

# Se llama SOLO en el cliente si el servidor se cierra
func _on_server_disconnected() -> void:
	print("⚠️ Servidor desconectado")
	multiplayer.multiplayer_peer = null
	players_info.clear()

# ===== RPCs =====

# El cliente llama esto para registrar su nombre en el host
@rpc("any_peer", "reliable")
func register_player(p_name: String) -> void:
	var sender_id = multiplayer.get_remote_sender_id()
	players_info[sender_id] = {"name": p_name}
	print("📝 Registrado jugador: ", p_name, " (ID: ", sender_id, ")")
	
	# El host envía la lista completa de jugadores al nuevo peer
	if multiplayer.is_server():
		update_players_list.rpc_id(sender_id, players_info)

# El host envía la lista de jugadores a un peer específico
@rpc("authority", "reliable")
func update_players_list(p_players_info: Dictionary) -> void:
	players_info = p_players_info
	print("📋 Lista de jugadores actualizada: ", players_info)

# Obtener el peer ID local
func get_my_id() -> int:
	return multiplayer.get_unique_id()

# Verificar si somos el host
func is_host() -> bool:
	return multiplayer.is_server()
