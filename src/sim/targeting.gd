class_name Targeting
extends RefCounted
## Turns a shape name + origin (user) + aim + size into board cells (out-of-bounds dropped).

static func dir_to(origin: Vector2i, aim: Vector2i) -> Vector2i:
	var d := aim - origin
	if d == Vector2i.ZERO:
		return Vector2i.RIGHT
	if absi(d.x) >= absi(d.y):
		return Vector2i(signi(d.x), 0)
	return Vector2i(0, signi(d.y))

static func _ok(p: Vector2i) -> bool:
	return p.x >= 0 and p.y >= 0 and p.x < Grid.W and p.y < Grid.H

static func cells(shape: String, origin: Vector2i, aim: Vector2i, size: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	match shape:
		"self":
			out.append(origin)
		"cell":
			out.append(aim)
		"line":
			var d := dir_to(origin, aim)
			for i in range(1, max(size, 1) + 1):
				out.append(origin + d * i)
		"circle":
			for y in range(aim.y - size, aim.y + size + 1):
				for x in range(aim.x - size, aim.x + size + 1):
					out.append(Vector2i(x, y))
		"around":   # square of radius `size` around the user
			for y in range(origin.y - size, origin.y + size + 1):
				for x in range(origin.x - size, origin.x + size + 1):
					out.append(Vector2i(x, y))
		"square":   # size x size block with the aim at its top-left
			for y in range(aim.y, aim.y + max(size, 1)):
				for x in range(aim.x, aim.x + max(size, 1)):
					out.append(Vector2i(x, y))
		"cross":
			out.append(aim)
			for d in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
				for i in range(1, size + 1):
					out.append(aim + d * i)
		"cone":
			var d2 := dir_to(origin, aim)
			var perp := Vector2i(d2.y, d2.x)
			for depth in range(1, max(size, 1) + 1):
				for k in range(-(depth - 1), depth):
					out.append(origin + d2 * depth + perp * k)
		"all":
			for y in Grid.H:
				for x in Grid.W:
					out.append(Vector2i(x, y))
	return out.filter(_ok)
