local enemy = ...
local map = enemy:get_map()

local life = 4
local damage = 1
local frost_damage = 4
local state -- States: "stopped", "iceball", "egg", "going_hero", "hidden", "hiding", "unhiding", "jumping", "prepare_jump", "finish_jump".
local speed = 15
local detection_distance = 100
local jump_duration = 1000 -- Time in milliseconds.
local max_height = 24 -- Height for the jump, in pixels.
local jumping_speed = 30 -- Speed of the movement during the jump.
local needs_put_egg = false -- Do not put eggs by default.

function enemy:on_created()
  self:set_life(life)
  self:set_damage(damage)
  self:set_size(16, 16)
  self:set_origin(8, 13)
  self:set_pushed_back_when_hurt(false)
  self:set_push_hero_on_sword(true)
  self:set_obstacle_behavior("flying") -- Allow to traverse bad grounds (and fall on them).
  local sprite = self:create_sprite("enemies/" .. self:get_breed())
  state = "hidden"
  function sprite:on_animation_finished(animation)
    if animation == "hide" then
      state = "hidden"
      sprite:set_animation("hidden")
      enemy:restart() -- Restart enemy after hiding.
    elseif animation == "unhide" then
      enemy:start_going_hero()
    elseif animation == "prepare_jump" then
      enemy:jump()
    elseif animation == "finish_jump" then
      state = "stopped"
      sprite:set_animation("stopped")
      sol.timer.start(enemy, 200, function()
        enemy:start_going_hero()
      end)
    end
  end
end

function enemy:on_restarted()
  -- Destroy shadow sprite, if any.
  local shadow = self:get_sprite("shadow")
  if shadow then self:remove_sprite(shadow) end
  -- Reset the starting animation if necessary (the engine sets the "walking" animation).
  if state == "hidden" then
    self:get_sprite():set_animation("hidden")
  else
    self:start_going_hero()
  end
  -- Check for bad grounds.
  self:start_checking_ground()
  -- Start looking for hero.
  self:start_checking()
end

-- Start checking for hero.
function enemy:start_checking()
  local hero = self:get_map():get_hero()
  -- Start loop for checking.
  sol.timer.start(self, 30, function()
    --print(state)
    local is_close = (self:get_distance(hero) <= detection_distance)
    if is_close then
      -- Unhide and follow hero if hero is close.
      if state == "hidden" then
        self:unhide()
      end
    elseif (not is_close) then
      -- Hide and stop if hero is not close.
      if state == "going_hero" then
        self:hide()
      end
    end
    return true
  end)
end

-- Go to hero.
function enemy:start_going_hero()
  state = "going_hero"
  self:get_sprite():set_animation("walking")
  local m = sol.movement.create("target")
  m:set_speed(speed)
  m:set_target(self:get_map():get_hero())
  m:start(self)
  -- Put egg if necessary. Otherwise, shoot ice ball.
  if needs_put_egg then
    sol.timer.start(self, 500, function() self:create_egg() end)
  else
    sol.timer.start(self, 2000, function()
      self:throw_iceball()
    end)
  end
  -- Prepare jump.
  sol.timer.start(self, 3000, function()
    self:prepare_jump()
  end)
end

-- Hide.
function enemy:hide()
  state = "hiding"
  self:stop_movement()
  self:get_sprite():set_animation("hide")
end
-- Unhide.
function enemy:unhide()
  state = "unhiding"
  self:get_sprite():set_animation("unhide")
end
-- Prepare jump.
function enemy:prepare_jump()
  state = "prepare_jump"
  self:stop_movement()
  self:get_sprite():set_animation("prepare_jump")
end
-- Finish jump.
function enemy:finish_jump()
  state = "finish_jump"
  self:stop_movement()
  self:get_sprite():set_animation("finish_jump")
  self:set_can_attack(true) -- Allow to attack the hero again.
end

-- Jump.
function enemy:jump()
  -- Set jumping state, animation and sound.
  state = "jumping"
  local sprite = self:get_sprite()
  sprite:set_animation("jump")
  sol.audio.play_sound("jump")
  self:set_invincible() -- Set invincible.
  self:set_can_attack(false) -- Do not attack hero during jump.
  -- Start shift on sprite.
  local function f(t) -- Shifting function.
    return math.floor(4 * max_height * (t / jump_duration - (t / jump_duration) ^ 2))
  end
  local t = 0
  local refreshing_time = 10
  sol.timer.start(self, refreshing_time, function() -- Update shift each 10 milliseconds.
    sprite:set_xy(0, -f(t))
    t = t + refreshing_time
    if t > jump_duration then return false
      else return true
    end
  end)
  -- Add a shadow sprite.
  local shadow = self:create_sprite("shadows/shadow_big_dynamic", "shadow")
  local new_frame_delay = math.floor(jump_duration/shadow:get_num_frames())
  shadow:set_frame_delay(new_frame_delay)
  -- Add movement towards near the hero during the jump. The jump does not target the hero.
  -- The angle is partially random to avoid too many enemies overlapping.
  local m = sol.movement.create("straight")
  local angle = self:get_angle(self:get_map():get_hero())
  math.randomseed(os.time()) -- Initialize random seed.
  local d = 2*math.random() - 1 -- Random real number in [-1,1].
  angle = angle + d*math.pi/4 -- Alter jumping angle, randomly.
  m:set_speed(jumping_speed)
  m:set_angle(angle)
  m:start(self)
  -- Finish the jump.
  sol.timer.start(self, jump_duration, function()
    self:remove_sprite(shadow) -- Remove shadow sprite.
    sol.timer.start(self, 1, function() -- TODO: remove this after #868 is fixed.
      self:set_default_attack_consequences() -- Stop invincibility after jump.
      self:finish_jump()
    end)
  end)
end

-- Add an "splash" sprite when dying.
function enemy:on_dying()
  local slime_sprite_id = self:get_sprite():get_animation_set() -- Get sprite variant of slime.
  local splash = self:create_sprite(slime_sprite_id)
  splash:set_animation("pieces")
  splash:set_xy(0,-14)
end

-- Check for bad ground (water, hole and lava) and also for empty ground.
function enemy:check_on_ground()
  local map = self:get_map()
  local px, py, layer = self:get_position()
  local x, y, layer = self:get_ground_position()
  local ground = self:get_ground_below()
  if ground == "empty" and layer > 0 then
    -- Fall to lower layer and check ground again.
     self:set_position(px, py, layer-1)
     self:check_on_ground() -- Check again new ground.
  elseif ground == "hole" then
    -- Create falling animation centered correctly on the 8x8 grid.
    x = math.floor(x/8)*8 + 4; if map:get_ground(x, y, layer) ~= "hole" then x = x + 4 end
    y = math.floor(y/8)*8 + 4; if map:get_ground(x, y, layer) ~= "hole" then y = y + 4 end
    local fall_on_hole = map:create_custom_entity({x = x, y = y, layer = layer, direction = 0})
    local sprite = fall_on_hole:create_sprite("ground_effects/fall_on_hole_effect")
    sprite:set_animation("fall_on_hole")
    self:remove()
    function sprite:on_animation_finished() fall_on_hole:remove() end
    sol.audio.play_sound("falling_on_hole")
  elseif ground == "deep_water" then
    -- Sink in water.
    local water_splash = map:create_custom_entity({x = x, y = y, layer = layer, direction = 0})
    local sprite = water_splash:create_sprite("ground_effects/water_splash_effect")
    sprite:set_animation("water_splash")
    self:remove()
    function sprite:on_animation_finished() water_splash:remove() end
    sol.audio.play_sound("splash")
  elseif ground == "lava" then
    -- Sink in lava.
    local lava_splash = map:create_custom_entity({x = x, y = y, layer = layer, direction = 0})
    local sprite = lava_splash:create_sprite("ground_effects/lava_splash_effect")
    sprite:set_animation("lava_splash")
    self:remove()
    function sprite:on_animation_finished() lava_splash:remove() end
    sol.audio.play_sound("splash")
  end
end

-- Start a timer to check ground once per second (useful if the ground moves or changes type!!!).
function enemy:start_checking_ground()
  sol.timer.start(self, 300, function()
    if state == "jumping" then return true end -- Do not check the ground while jumping.
    self:check_on_ground()
    return true
  end)
end

-- Shoot iceballs.
function enemy:throw_iceball()
  state = "iceball"
  self:stop_movement()
  sol.audio.play_sound("fire_ball")
  local sprite = self:get_sprite()
  sprite:set_animation("jump")
  sol.timer.start(self, 150, function() sprite:set_animation("stopped") end)
  local x, y, layer = self:get_position()
  local prop = {x = x, y = y, layer = layer, direction = 0, breed = "iceball"}
  local speed = 60 -- Speed for the fireballs
  local function create_iceball(angle)
    local a = angle
    local iceball = map:create_enemy(prop)
    iceball:set_frost_damage(frost_damage)
    iceball:start_movement(a, speed)
  end
  local a = self:get_angle(map:get_hero())
  create_iceball(a)
  create_iceball(a + math.pi / 8)
  create_iceball(a - math.pi / 8)
  sol.timer.start(self, 500, function()
    sol.audio.play_sound("fire_ball")
    sprite:set_animation("jump")
    sol.timer.start(self, 150, function() sprite:set_animation("walking") end)
    create_iceball(a + math.pi / 16)
    create_iceball(a - math.pi / 16)
    create_iceball(a + 3 * math.pi / 16)
    create_iceball(a - 3 * math.pi / 16)
  end)
end

-- Create egg.
function enemy:create_egg()
  state = "egg"
  needs_put_egg = false
  self:stop_movement()
  local sprite = self:get_sprite()
  sprite:set_animation("jump")
  sol.timer.start(self, 250, function() sprite:set_animation("stopped") end)
  local x, y, layer = self:get_position()
  local prop = {x = x, y = y, layer = layer, direction = 0, breed = "slime_egg"}
  local egg = map:create_enemy(prop)
  egg:set_slime_model("slime_green")
  egg:fall() -- Falling animation.
  egg:set_can_procreate(false) -- Do not allow more procreation from the new slime.
  return egg
end

-- Enable/disable putting egg.
function enemy:set_egg_enabled(bool) needs_put_egg = bool end
function enemy:get_egg_enabled() return needs_put_egg end
