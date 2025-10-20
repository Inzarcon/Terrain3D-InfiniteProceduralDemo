extends Node

@export_group("Region Settings")
@export var region_size := 1024 ## Terrain3D Region size in heightmap pixels/vertices. Must be power of 2 and max 2048.
@export var vertex_spacing := 10.0 ## Terrain3D vertex_spacing.
var region_distance := region_size * vertex_spacing ## Distance between Regions in units/meters.
@export var region_limit := 4 ## How many Regions to generate/load in each direction around the current Origin.
@export var region_shift_limit := 2 ## How many Regions the Player can move from Origin before triggering Origin Shift.

@export_group("Heightmap Generation")
@export var noise := FastNoiseLite.new() ## FastNoiseLite instance for heightmap generation.
@export var heightmap_offset := 0  ## Heightmap Y offset.
@export var heightmap_scale := 2000 ## Heightmap Y scale.

@export_group("Data Storage")
## Whether to drop inactive Regions from RAM Cache. If false, all once loaded Regions are kept in 
## RAM, making reloading previously visited Regions much faster. However, this can quickly occupy 
## gigabytes of memory (depending on the Region parameters and Player speed, as well as the 
## cache_full_regions parameter).
@export var unload_cache := true
## Whether to cache the full Terrain3DRegion instances. If false, only the generated heightmaps are
## cached. Compromise between speed and RAM usage. Has no significant effect when unload_cache is 
## enabled.
@export var cache_full_regions := false
## Whether Region heightmaps should be exported to and imported from disk. This can be as fast as
## loading heightmaps from the runtime Cache with cache_full_regions disabled, depending on the
## speed of the storage drive. However, enabling cache_full_regions is still by far the fastest.
## NOTE: Don't forget to clear the data when changing terrain generation parameters, or set a
## different directory!
@export var save_to_disk := true
## Directory for heightmap export/import. Exporting also creates the directory if it does not exist.
@export var save_location := "res://demo/data/"

# Current Locations
var relative_origin := Vector2i(0, 0) ## Which virtual Region location is the current real origin.
var player_region := Vector2i(0, 0) ## Real Region location the Player is in.

# Terrain3D Shortcuts
var terrain: Terrain3D
var data: Terrain3DData

# Threading, Caching and Saving
var mutex := Mutex.new()
var tasks
var group_id
var cached_regions := {} ## Region instances with their virtual locations as keys.
var cached_heightmaps := {} ## Like cached_regions, but for heightmaps when cache_full_regions is false.
var shift_lock := false ## Don't shift if there is already an Origin Shift getting processed.

# Stats about latest Origin Shift
var shift_start_ms: int ## For benchmarking time an Origin Shift takes.
var cached := 0 ## How many Regions were loaded from RAM cache.
var loaded := 0 ## How many Regions were loaded from disk. (NOTE: Disabled in this version.)
var generated := 0 ## How many Regions were newly generated from noise.

## Vector subtracted from player.global_position to teleport Player in sync with Origin Shift.
var player_origin_shift: Vector3

func _ready() -> void:
	$UI.player = $Player

	if has_node("RunThisSceneLabel3D"):
		$RunThisSceneLabel3D.queue_free()

	await create_terrain()
	$UI.terrain = terrain
	data = terrain.data
	
	# Allow very large draw distances using vertex_spacing.
	terrain.vertex_spacing = vertex_spacing
	terrain.mesh_lods = 10
	terrain.mesh_size = 64

	region_origin_shift(Vector2i(0, 0)) # Trigger creating initial Terrain around true Origin.

## Loads a region/heightmap from cache, depending on cache_full_regions.
func load_region_from_cache(location: Vector2i, virtual_location: Vector2i) -> void:
	if cache_full_regions:
		var region = cached_regions.get(virtual_location)
		if region == null:
			push_error(
				"Loaded region from cache for virtual location " 
				+ str(virtual_location) + " is null. Ignoring.")
		region.location = location
		data.add_region(region, false)
	else:
		var heightmap = cached_heightmaps.get(virtual_location)
		create_region(location, heightmap)

## Checks if a location is within the given Region distance border away from true Origin.
func is_within_borders(location: Vector2i, border: int = 4) -> bool:
	return abs(location.x) <= border and abs(location.y) <= border

## Checks every frame if Player Region changed and triggers Origin Shift if they moved far enough.
func _process(_delta: float) -> void:
	if shift_lock:
		return
	
	var cur_region := data.get_region_location($Player.global_position)
	if cur_region == player_region:
		return
	player_region = cur_region
	
	if not is_within_borders(cur_region, region_shift_limit):
		region_origin_shift(cur_region)
		
## Shifts the loaded Regions and Player position so that the current Region is the new (0, 0).
## Regions that are shifted beyond region_limit are removed. (I.e. the Regions at the opposite end.)
## If any of the Regions within region_limit do not exist yet, they are newly generated.
func region_origin_shift(location: Vector2i) -> void:
	shift_lock = true
	shift_start_ms = Time.get_ticks_msec()
	relative_origin += location
	# Store Player Shift, but do not apply yet. -> Synced with map update in _update_regions(). 
	player_origin_shift = Vector3(location.x * region_distance, 0.0, location.y * region_distance)
	update_regions()

## Handles what needs to be changed for Origin Shift and creates tasks for WorkerThreadPool to run.
## The WorkerThreadPool then generates/loads all Regions. Finally, the changes to the Region maps
## are applied and the Player is teleported.
## Also updates the debug stats about how many Regions were generated/loaded.
func update_regions() -> void:
	generated = 0
	loaded = 0
	cached = 0
	tasks = []
	
	var cache = cached_regions if cache_full_regions else cached_heightmaps
	
	var dropped_regions = {}
	if unload_cache:
		for virtual_location in cache.keys():
			dropped_regions[virtual_location] = null # Emulate HashSet
	
	for x in range(-region_limit, region_limit): 
		for y in range(-region_limit, region_limit):
			var location = Vector2i(x, y)
			var virtual_location = location + relative_origin
			if cached_regions.has(virtual_location) or cached_heightmaps.has(virtual_location):
				tasks.append([location, virtual_location, "from_cache"])
				cached += 1
				dropped_regions.erase(virtual_location)
			elif save_to_disk and saved_exists(virtual_location):
				tasks.append([location, virtual_location, "from_disk"])
				loaded += 1
				$UI.loaded_count += 1
				dropped_regions.erase(virtual_location)
			else:
				tasks.append([location, virtual_location, "generate"])
				generated += 1
				$UI.loaded_count += 1
	
	if unload_cache:
		for virtual_location in dropped_regions:
			cache.erase(virtual_location)
			$UI.loaded_count -= 1
	_run_tasks()

## Updates a single Region during an Origin Shift. This is a single task run by a WorkerThread.
func _update_region(task_index: int) -> void:
	var task = tasks.get(task_index)
	var location = task[0]
	var virtual_location = task[1]
	var type = task[2]
	
	if type == "from_cache":
		load_region_from_cache(location, virtual_location) # Read-Only -> No Mutex is faster.
		print("Loaded Region ", str(virtual_location), " from Cache.")
		return
		
	var heightmap: Image
	var msg: String
	if type == "from_disk":
		heightmap = ResourceLoader.load(virtual_to_filename(virtual_location))
		msg = "Loaded Region " + str(virtual_location) + " from disk."
	elif type == "generate":
		heightmap = generate_heightmap(virtual_location)
		msg = "Generated Region " + str(virtual_location) + "."
		if save_to_disk:
			if not DirAccess.dir_exists_absolute(save_location):
				DirAccess.make_dir_absolute(save_location)
			ResourceSaver.save(heightmap, virtual_to_filename(virtual_location))
		
	var region := create_region(location, heightmap)

	# TODO: Consider thread-safe storage which doesn't require Mutex.
	mutex.lock()
	if cache_full_regions:
		cached_regions[virtual_location] = region
	else:
		cached_heightmaps[virtual_location] = heightmap
	mutex.unlock()

	print(msg)

## Creates, adds and returns a new region for the given location and heightmap.
func create_region(location: Vector2i, heightmap: Image) -> Terrain3DRegion:
	# NOTE: Might be what causes no difference in RAM usage when storing only heightmaps
	#       -> Loaded region not updated?
	var region := Terrain3DRegion.new()
	region.location = location
	region.set_map(Terrain3DRegion.TYPE_HEIGHT, heightmap)
	data.add_region(region, false)
	return region

## Generate and return heightmap for the given virtual_location.
## NOTE: Inefficient compared to C++, but good enough for this demo.
func generate_heightmap(virtual_location: Vector2i) -> Image:
	var noise_offset_x := virtual_location.x * region_distance
	var noise_offset_y := virtual_location.y * region_distance
	
	var img: Image = Image.create_empty(region_size, region_size, false, Image.FORMAT_RF)
	for x in region_size:
		for y in region_size:
			# NOTE: DO NOT store intermediate results as separate vars. Looping is already expensive
			#       in GDScript, so creating intermediate vars for each pixel would make that even 
			#       worse.
			img.set_pixel(x, y, Color(
				(noise.get_noise_2d(
					x * vertex_spacing + noise_offset_x, 
					y * vertex_spacing + noise_offset_y)
					+ heightmap_offset) 
					* heightmap_scale, 
				0, # Green (Not used)
				0, # Blue (Not used)
				1)) # Alpha
	return img

## Run all Region generation/loading tasks in the WorkerThreadPool.
func _run_tasks() -> void:
	group_id = WorkerThreadPool.add_group_task(_update_region, tasks.size())
	WorkerThreadPool.add_task(_update_regions_wait)

## Wrapper for _update_regions() to wait until all Regions are ready.
## NOTE: There is probably a better way of doing this directly, but I don't have a lot of experience
##       with threading in Godot yet.
func _update_regions_wait() -> void:
	WorkerThreadPool.wait_for_group_task_completion(group_id)
	call_deferred("_update_regions")

## Applies Region map updates after Origin Shift is done, then teleport the Player. Also updates
## Debug display values.
func _update_regions() -> void:
	data.update_maps(Terrain3DRegion.TYPE_HEIGHT)
	$Player.global_position -= player_origin_shift
	var shift_text = ("\nLast origin shift took " + str((Time.get_ticks_msec() - shift_start_ms)) + "ms\n"
		+ "Loaded from RAM Cache: " + str(cached) + "\n"
		+ "Loaded from Disk: " + str(loaded) + "\n"
		+ "Newly Generated: " + str(generated) + "\n")
	$UI.shift_text = shift_text
	shift_lock = false
	print(shift_text)

## Translate virtual location to Region file name.
## NOTE: Not used since saving to disk is disabled in this version.
func virtual_to_filename(virtual_location: Vector2i) -> String:
	return save_location + str(virtual_location.x) + "_" +  str(virtual_location.y) + ".res"

## Check if the Region file for the given virtual location exists.
## NOTE: Not used since saving to disk is disabled in this version.
func saved_exists(virtual_location: Vector2i) -> bool:
	return ResourceLoader.exists(virtual_to_filename(virtual_location))

## Mostly the same as original with minor changes and moving out the heightmap generation part.
func create_terrain() -> Terrain3D:
	var rock_gr := Gradient.new()
	rock_gr.set_color(0, Color.from_hsv(30./360., .1, .3))
	rock_gr.set_color(1, Color.from_hsv(30./360., .1, .4))
	var rock_ta = await create_texture_asset("Rock", rock_gr, region_size)
	rock_ta.uv_scale = 0.03
	rock_ta.detiling_rotation = 0.1

	var grass_gr := Gradient.new()
	grass_gr.set_color(0, Color.from_hsv(100./360., .35, .3))
	grass_gr.set_color(1, Color.from_hsv(120./360., .4, .37))
	var grass_ta = await create_texture_asset("Grass", grass_gr, region_size)
	grass_ta.uv_scale = 0.03
	grass_ta.detiling_rotation = 0.1
	
	# NOTE: I don't yet understand what the point of the color is since it doesn't seem to change
	#       anything, but maybe it's just not relevant for this use-case.
	var mesh_asset = create_mesh_asset("NoiseMA", Color.from_hsv(0, 0, 0))

	# Create the Terrain.
	terrain = Terrain3D.new()
	terrain.name = "Terrain3D"
	terrain.debug_level = Terrain3D.ERROR
	# NOTE: Causes deprecation warning in Godot 4.5.1, might be something Terrain3D-internal.
	# TODO: Investigate.
	add_child(terrain, true)
	
	terrain.material.world_background = Terrain3DMaterial.NONE
	terrain.material.auto_shader = true
	terrain.material.set_shader_param("auto_slope", 3)
	terrain.material.set_shader_param("blend_sharpness", 0)
	terrain.material.set_shader_param("auto_height_reduction", 0.1)
	terrain.set_material(terrain.get_material())

	terrain.assets = Terrain3DAssets.new()
	terrain.assets.set_texture(0, rock_ta)
	terrain.assets.set_texture(1, grass_ta)
	terrain.assets.set_mesh_asset(0, mesh_asset)

	terrain.region_size = region_size as Terrain3D.RegionSize

	return terrain

## Same as original.
func create_texture_asset(asset_name: String, gradient: Gradient, texture_size: int = 512) -> Terrain3DTextureAsset:
	# Create noise map
	var fnl_tex := FastNoiseLite.new()
	fnl_tex.frequency = 0.004

	# Create albedo noise texture
	var alb_noise_tex := NoiseTexture2D.new()
	alb_noise_tex.width = texture_size
	alb_noise_tex.height = texture_size
	alb_noise_tex.seamless = true
	alb_noise_tex.noise = fnl_tex
	alb_noise_tex.color_ramp = gradient
	await alb_noise_tex.changed
	var alb_noise_img: Image = alb_noise_tex.get_image()

	# Create albedo + height texture
	for x in alb_noise_img.get_width():
		for y in alb_noise_img.get_height():
			var clr: Color = alb_noise_img.get_pixel(x, y)
			clr.a = clr.v # Noise as height
			alb_noise_img.set_pixel(x, y, clr)
	alb_noise_img.generate_mipmaps()
	var albedo := ImageTexture.create_from_image(alb_noise_img)

	# Create normal + rough texture
	var nrm_noise_tex := NoiseTexture2D.new()
	nrm_noise_tex.width = texture_size
	nrm_noise_tex.height = texture_size
	nrm_noise_tex.as_normal_map = true
	nrm_noise_tex.seamless = true
	nrm_noise_tex.noise = fnl_tex
	await nrm_noise_tex.changed
	var nrm_noise_img = nrm_noise_tex.get_image()
	for x in nrm_noise_img.get_width():
		for y in nrm_noise_img.get_height():
			var normal_rgh: Color = nrm_noise_img.get_pixel(x, y)
			normal_rgh.a = 0.8 # Roughness
			nrm_noise_img.set_pixel(x, y, normal_rgh)
	nrm_noise_img.generate_mipmaps()
	var normal := ImageTexture.create_from_image(nrm_noise_img)

	var ta := Terrain3DTextureAsset.new()
	ta.name = asset_name
	ta.albedo_texture = albedo
	ta.normal_texture = normal
	return ta

## Same as original.
func create_mesh_asset(asset_name: String, color: Color) -> Terrain3DMeshAsset:
	var ma := Terrain3DMeshAsset.new()
	ma.name = asset_name
	ma.generated_type = Terrain3DMeshAsset.TYPE_TEXTURE_CARD
	ma.material_override.albedo_color = color
	return ma
