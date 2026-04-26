extends MeshInstance3D


func _init():
    var c = Color("#b55945")
    print(c) # Should NOT be (0.710, 0.349, 0.271) — should be the linearized version
