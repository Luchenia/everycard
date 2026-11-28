class_name CardSubmission
extends RefCounted
## The seam between the card studio and the card server.
##
## What the player sends is only a name and a picture. The server (not built yet) asks an LLM
## for the effect, cost, family and rarity once, stores the card, and every player gets the
## same card. Until the server exists, `endpoint` is empty and a submission is written to
## user://card_submissions/<id>/ (picture.png + card.json) so nothing is lost.
##
## To switch to the real server later: set `endpoint` (e.g. from a config file) and fill
## `_post()` with an HTTPRequest call carrying `payload()` as JSON. The studio does not change.

signal finished(result: Dictionary)

const FORMAT := 1
const OUT_DIR := "user://card_submissions"

var endpoint := ""

## JSON the server will receive. The picture travels as base64 PNG at its native 64x51.
static func payload(card_name: String, picture: Image) -> Dictionary:
	return {
		"format": FORMAT,
		"name": card_name.strip_edges(),
		"picture_png_base64": Marshalls.raw_to_base64(picture.save_png_to_buffer()),
		"picture_size": [picture.get_width(), picture.get_height()],
		"client": "everycard-%s" % ProjectSettings.get_setting("application/config/version", "dev"),
	}

static func validate(card_name: String, picture: Image) -> Array[String]:
	var problems: Array[String] = []
	if card_name.strip_edges().is_empty():
		problems.append("name")
	if picture.is_invisible():
		problems.append("picture")
	return problems

func submit(card_name: String, picture: Image) -> void:
	var problems := validate(card_name, picture)
	if not problems.is_empty():
		finished.emit({"ok": false, "problems": problems})
		return
	if endpoint.is_empty():
		finished.emit(_save_local(card_name, picture))
	else:
		_post(payload(card_name, picture))

func _save_local(card_name: String, picture: Image) -> Dictionary:
	var id := "%d_%04d" % [int(Time.get_unix_time_from_system()), randi() % 10000]
	var dir := "%s/%s" % [OUT_DIR, id]
	DirAccess.make_dir_recursive_absolute(dir)
	var err := picture.save_png(dir + "/picture.png")
	var data := payload(card_name, picture)
	data.erase("picture_png_base64")   # the PNG sits next to it
	data["picture_file"] = "picture.png"
	data["saved_at"] = Time.get_datetime_string_from_system(true)
	var f := FileAccess.open(dir + "/card.json", FileAccess.WRITE)
	if f == null or err != OK:
		return {"ok": false, "problems": ["save"]}
	f.store_string(JSON.stringify(data, "  "))
	f.close()
	return {"ok": true, "local": true, "id": id, "path": ProjectSettings.globalize_path(dir)}

func _post(_body: Dictionary) -> void:
	# Real upload goes here once the server API is fixed. Fails honestly until then.
	finished.emit({"ok": false, "problems": ["server"]})
