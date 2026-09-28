extends CharacterBody3D
## Tiny test actor: counts physics ticks, reacts to the "jump" action and logs.

signal jumped(count: int)

@export var speed: float = 3.0
var ticks: int = 0
var jumps: int = 0


func _physics_process(_delta: float) -> void:
	ticks += 1
	if Input.is_action_just_pressed("jump"):
		jumps += 1
		jumped.emit(jumps)
		print("Player jumped #%d" % jumps)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_E:
		push_warning("E pressed in player")


func greet(name: String, times: int = 1) -> String:
	return ("hi %s " % name).repeat(times).strip_edges()
