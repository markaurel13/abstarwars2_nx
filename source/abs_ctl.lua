-- abs_ctl.lua -- the Switch controller bridge, inside Angry Birds Space's Lua.
--
-- abs_lua.c loads this once per Lua universe (it defines the global table
-- __abs) and then, once per game update, calls
--     __abs.frame(cmd, pan, zoom, flags, memlimit)
-- from inside the game's own Lua (a math.* call of the game's). It reads the
-- game's globals -- the same ones its touch code reads -- and returns what the
-- port's controls need as one line of tokens:
--     game mode sw sh ready bx by lx ly pull aiming special tx ty sig req
--     clock mm vx vy vw vh carousel n, then n items:
--     x y w h ax ay kind shape prio id grp vis
-- (positions are fractions of the game's screen, -1 when absent; sig names
-- the screen or popup on top; req = what the port should do, comma-separated:
-- play:topic:youtube-id (a video in the popup), vstop (the popup is done with
-- it), closed (the popup closed), page:LINK (the port's own page, if the
-- game's popup could not be made), '-' for nothing; clock = the game's own
-- clock (Lua `time`); mm = the main menu's flags (1 it is on screen, 2 its
-- left tab is open, 4 its right one); vx..vh = where the popup plays the
-- video; carousel = 1 on the planet carousel, 2 while it turns; for items:
-- ax, ay = where to tap, kind 0 button / 2 the planet in the middle of the
-- carousel (its box: its name sign), shape 0 box / 1 round, prio = how good a
-- first focus it is, id = the same item across updates, grp = the main
-- menu's tab it is in (2 left, 4 right, +1 the tab's own button), vis = 0 when
-- it is off the screen or its page). The controller passes the focused item's
-- id, which is brought into view (the next page of levels). The script also
-- carries out the camera, pause, paging and carousel requests, and (flags)
-- makes every purchase free, opens links in a popup of the game's own kind
-- about their topic, shows the Froot Loops Bloopers episode, and raises the
-- texture budget.
-- Every access to the game is guarded: a missing global or a changed
-- function makes this report less, never break the game. MIT.

local A = {}
__abs = A

do
  local g_list = {}
  for k, v in pairs(_G) do
    if k ~= '_G' and k ~= '_VERSION' and k ~= 'string' and k ~= 'table' and k ~= 'math' and k ~= 'coroutine' and k ~= 'package' and k ~= 'os' and k ~= 'io' and k ~= 'debug' then
      g_list[#g_list + 1] = k .. ':' .. type(v)
    end
  end
  table.sort(g_list)
  print('[LUA_GLOBALS] ' .. table.concat(g_list, ' '))
end

local type, pcall, tostring, tonumber, pairs, ipairs = type, pcall, tostring, tonumber, pairs, ipairs
local sfind, slower, sfmt, ssub = string.find, string.lower, string.format, string.sub
local concat = table.concat

-- slingshot.lua's rubber band: full stretch, in physics units
MAX_LENGTH = 5.4

MODE_MENU, MODE_AIM, MODE_FLIGHT, MODE_WAIT, MODE_PAUSED, MODE_ENDED = 1, 2, 3, 4, 5, 6
AIMED_POWERS = {LASER = true, GRENADE = true, GRAVITY_DISRUPTOR = true} -- aimed where tapped
CMD_SLING, CMD_CASTLE, CMD_PAUSE, CMD_RESTART, CMD_EAGLE, CMD_PAGE_NEXT, CMD_PAGE_PREV,
      CMD_SPIN_LEFT, CMD_SPIN_RIGHT, CMD_POWERUPS, CMD_EPISODE_LIGHT, CMD_EPISODE_DARK = 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12
FLAG_BUTTONS, FLAG_FREE, FLAG_INFO, FLAG_ONLINE, FLAG_KELLOGGS = 1, 2, 4, 8, 16
KIND_BUTTON, KIND_SIDE, KIND_CENTRE, KIND_LINK = 0, 1, 2, 3

local function num(v)
  if type(v) == 'number' then return v end
  return nil
end

local function call(f, a, b)
  if type(f) ~= 'function' then return nil end
  local ok, r = pcall(f, a, b)
  if ok then return r end
  return nil
end

local captured_env

local function link_gamelua()
  if captured_env then return end
  local g = rawget(_G, 'gamelua')
  if type(g) == 'table' then
    captured_env = g
  else
    for i = 2, 7 do
      local ok, f = pcall(getfenv, i)
      if ok and type(f) == 'table' and (f.menuManager or f.g_inMainMenu or f.levelName) then
        captured_env = f
        print("[lua] found game environment in call stack at level " .. i .. "!")
        local s = "[GAMELUA_GLOBALS] "
        for k, v in pairs(captured_env) do 
          s = s .. tostring(k) .. ":" .. type(v) .. " " 
          if #s > 500 then
            print(s)
            s = "[GAMELUA_GLOBALS] "
          end
        end
        if #s > 20 then print(s) end

        if type(captured_env.menuManager) == 'table' then
          local sm = "[MENUMANAGER_KEYS] "
          for k, v in pairs(captured_env.menuManager) do
            sm = sm .. tostring(k) .. ":" .. type(v) .. " "
            if #sm > 500 then print(sm); sm = "[MENUMANAGER_KEYS] " end
          end
          if #sm > 20 then print(sm) end
        end

        if type(captured_env.MenuManager) == 'table' then
          local sm = "[CAPITAL_MENUMANAGER_KEYS] "
          for k, v in pairs(captured_env.MenuManager) do
            sm = sm .. tostring(k) .. ":" .. type(v) .. " "
            if #sm > 500 then print(sm); sm = "[CAPITAL_MENUMANAGER_KEYS] " end
          end
          if #sm > 20 then print(sm) end
        end
        break
      end
    end
  end

  if not captured_env and frame_no == 100 then
    local s = "[LUA_GLOBALS_100] "
    for k, v in pairs(_G) do s = s .. tostring(k) .. ":" .. type(v) .. " " end
    print(s)
  end

  if captured_env then
    local env = captured_env
    setmetatable(_G, {
      __index = env,
      __newindex = function(t, k, v)
        if type(rawget(_G, 'gamelua')) == 'table' then
          rawget(_G, 'gamelua')[k] = v
        else
          env[k] = v
        end
        rawset(t, k, v)
      end
    })
  end
end

local function screen_w()
  local w = num(screenWidth) or (type(gamelua) == 'table' and num(gamelua.screenWidth))
  if w and w > 0 then return w end
  return 1280
end

local function screen_h()
  local h = num(screenHeight) or (type(gamelua) == 'table' and num(gamelua.screenHeight))
  if h and h > 0 then return h end
  return 720
end

local function p2s(x, y)
  local fn = physicsToScreenTransform or (type(gamelua) == 'table' and gamelua.physicsToScreenTransform)
  if type(fn) ~= 'function' then return nil end
  local ok, sx, sy = pcall(fn, x, y)
  if ok and type(sx) == 'number' and type(sy) == 'number' then return sx, sy end
  return nil
end

local frame_no = 0
local focus_id = 0 -- the controller's focused item
local popup_open

-- ------------------------------------------------------------ the UI tree
-- MenuManager.delegateClicks sends every touch to _baseFrame:onPointerEvent
-- (ev, cursor.x, cursor.y). Its children are the current page (the root),
-- menuParticlesFrame and, on top, notificationsFrame, where popups go.
-- ui.Frame.onPointerEvent hands a child (x - self.x, y - self.y), topmost
-- child first, skipping children that are not visible and active, and stops
-- at the first that answers.
local function menu_manager()
  local env = captured_env
  local system = type(env) == 'table' and env.GameSystem or nil
  if type(system) ~= 'table' and type(GameSystem) == 'table' then system = GameSystem end
  if type(system) == 'table' and type(system.menuManager) == 'table' then return system.menuManager end
  if type(env) == 'table' and type(env.menuManager) == 'table' then return env.menuManager end
  if type(menuManager) == 'table' then return menuManager end
  local g = type(gamelua) == 'function' and gamelua() or type(gamelua) == 'table' and gamelua or nil
  if type(g) == 'table' and type(g.menuManager) == 'table' then return g.menuManager end
  if type(MenuManager) == 'table' then return MenuManager end
  if type(g_menuManager) == 'table' then return g_menuManager end
  if type(GameSystem) == 'table' and type(GameSystem.menuManager) == 'table' then return GameSystem.menuManager end
  return nil
end

local function base_frame()
  local env = captured_env
  local g = type(gamelua) == 'function' and gamelua() or type(gamelua) == 'table' and gamelua or nil
  local r = nil
  if type(rootFrame) == 'table' then r = rootFrame
  elseif type(env) == 'table' and type(env.rootFrame) == 'table' then r = env.rootFrame
  elseif type(env) == 'table' and type(env.baseFrame) == 'table' then r = env.baseFrame
  elseif type(g) == 'table' and type(g.rootFrame) == 'table' then r = g.rootFrame
  elseif type(g_rootFrame) == 'table' then r = g_rootFrame
  elseif type(baseFrame) == 'table' then r = baseFrame
  elseif type(g) == 'table' and type(g.baseFrame) == 'table' then r = g.baseFrame
  elseif type(g_baseFrame) == 'table' then r = g_baseFrame
  else
    local mm = menu_manager()
    if mm then
      if type(mm._baseFrame) == 'table' then r = mm._baseFrame
      elseif type(mm.rootFrame) == 'table' then r = mm.rootFrame
      elseif type(mm.getRoot) == 'function' then
        local ok, res = pcall(mm.getRoot, mm)
        if ok and type(res) == 'table' then r = res end
      end
      if r == nil and type(mm.currentRoot) == 'table' then r = mm.currentRoot end
    end
  end
  return r
end

local function base_handler()
  local U = (type(ui) == 'table' and ui) or (type(gamelua) == 'table' and gamelua.ui)
  if type(U) == 'table' and type(U.Frame) == 'table' then return U.Frame.onPointerEvent end
  return nil
end

local function live(f)
  return type(f) == 'table' and f.visible ~= false and f.active ~= false
end

local function method_of(f, name)
  if type(f) ~= 'table' then return nil end
  local v = rawget(f, name)
  if type(v) == 'function' then return v end
  local m = getmetatable(f)
  for _ = 1, 12 do
    if type(m) ~= 'table' then return nil end
    v = rawget(m, name)
    if type(v) == 'function' then return v end
    local index = rawget(m, '__index')
    if type(index) == 'table' then
      v = rawget(index, name)
      if type(v) == 'function' then return v end
    end
    m = getmetatable(m)
  end
  return nil
end

-- a frame that answers pointer events itself (a button of some kind)
local function handles(f, base)
  if method_of(f, 'onClick') or method_of(f, 'onRelease') then return true end
  local h = method_of(f, 'onPointerEvent')
  return type(h) == 'function' and h ~= base
end

-- A container that takes every touch (Prompt, ConfirmPrompt... answer
-- 'BLOCK' to anything they do not use) hides what is under it. It is asked
-- with an event no handler acts on, far off the screen; the answer is kept
-- for a second.
local probes = setmetatable({}, {__mode = 'k'})
local function modal(f, base)
  if f.enabled == false or (num(f.alpha) and f.alpha <= 0.05) then return false end
  if not handles(f, base) then return false end
  local c = probes[f]
  if c and frame_no - c.t < 60 then return c.r end
  local ok, r = pcall(method_of(f, 'onPointerEvent'), f, 'ABS_PROBE', -100000, -100000)
  r = (ok and r) and true or false
  probes[f] = {t = frame_no, r = r}
  return r
end

local function names_of(f)
  return slower(tostring(f.returnValue or '') .. ' ' .. tostring(f.name or '') .. ' ' ..
                tostring(f.enabledImage or f.image or ''))
end

-- how good a first focus a button is (Prompt's check is 'close_button' with
-- the image BTN_CHECK; ConfirmPrompt's no is BTN_X)
PRIO = {
  {'btn_check', 9}, {'check', 9}, {'proceed', 8}, {'play', 8}, {'next', 8}, {'continue', 8},
  {'resume', 8}, {'confirm', 8}, {'accept', 8}, {'_ok', 8}, {'watch', 8}, {'yes', 7}, {'restart', 5},
  {'btn_x', 1}, {'back', 1}, {'shop', 1}, {'facebook', 0},
}
local function prio_of(f)
  local s = names_of(f)
  for _, p in ipairs(PRIO) do
    if sfind(s, p[1], 1, true) then return p[2] end
  end
  return 3
end

-- The frame's box in its parent's coordinates, as its own hit test sees it.
-- ScalableButton.hitTest multiplies its scale by every ancestor's (ps here,
-- the ancestors' scaleX together) and hitAreaScale; ImageButton uses its own
-- scale. Each reading is tried against the frame's hitTest / checkCollision
-- and the first whose centre hits is kept.
local function box_with(f, sx, sy)
  local w, h = num(f.w) or 0, num(f.h) or 0
  if w <= 0 or h <= 0 then return nil end
  local px, py = num(f.px) or 0, num(f.py) or 0
  local x, y = num(f.x) or 0, num(f.y) or 0
  local x0, y0
  if sx >= 0 then x0 = x - px * sx else sx = -sx; x0 = x - (w - px) * sx end
  if sy >= 0 then y0 = y - py * sy else sy = -sy; y0 = y - (h - py) * sy end
  return x0, y0, w * sx, h * sy
end

local function hits(f, x, y)
  local t = f.hitTest or f.checkCollision
  if type(t) ~= 'function' then return false, false end
  local ok, r = pcall(t, f, x, y)
  return ok and r and true or false, true
end

local function box(f, ps, pys)
  local sx, sy = num(f.scaleX) or 1, num(f.scaleY) or 1
  local ha = num(f.hitAreaScale) or 1
  local ws = num(worldScale) or 1
  local tries = {
    {sx * ps * ha, sy * pys * ha},
    {sx * ha, sy * ha},
    {sx * ws, sy * ws},
  }
  local first
  for _, t in ipairs(tries) do
    local x, y, w, h = box_with(f, t[1], t[2])
    if x then
      first = first or {x, y, w, h}
      local hit, testable = hits(f, x + w * 0.5, y + h * 0.5)
      if hit then return x, y, w, h end
      if not testable then break end
    end
  end
  if first then return first[1], first[2], first[3], first[4] end
  return nil
end

items, nitems, big, focused_light_locked, focused_dark_locked, focused_light_id, focused_dark_id = nil, nil, nil, nil, nil, nil, nil
MAXB = 48
ui_debug_done = false
ui_debug_attempts = 0

local function debug_ui_tree(f, depth, limit, base)
  if type(f) ~= 'table' or depth > 3 or limit.n <= 0 then return end
  limit.n = limit.n - 1
  local ch = f.children
  local h = method_of(f, 'onPointerEvent')
  print(sfmt('[ui-debug] d=%d name=%s w=%s h=%s children=%d click=%s release=%s pointer=%s base=%s', depth,
            tostring(f.name), tostring(f.w), tostring(f.h), type(ch) == 'table' and #ch or 0,
            method_of(f, 'onClick') and 'yes' or 'no', method_of(f, 'onRelease') and 'yes' or 'no',
            h and 'yes' or 'no', h == base and 'yes' or 'no'))
  if type(ch) == 'table' then
    for i = #ch, 1, -1 do
      debug_ui_tree(ch[i], depth + 1, limit, base)
    end
  end
end

-- stable ids for the frames seen (weak: a frame that goes, goes); the planet
-- in the middle is 1
ids, next_id = setmetatable({}, {__mode = 'k'}), 10
ls_world_ids = {}
local function id_of(f)
  local i = ids[f]
  if not i and levelName == 'LevelSelection' then
    if type(f.name) == 'string' and f.name ~= '' then
      i = ls_world_ids[f.name]
      if not i then
        i = next_id
        next_id = next_id + 1
        ls_world_ids[f.name] = i
      end
      ids[f] = i
      return i
    end
  end
  if not i then
    i = next_id
    next_id = next_id + 1
    ids[f] = i
  end
  return i
end

-- what the last scan saw of each item, by id: its frame, the scrolling frame
-- it is in, its box (for bringing the focused item into view)
seen, seen_next = {}, {}

-- an item: x y w h ax ay kind shape prio id grp vis (fractions of the screen)
local function add_item(x, y, w, h, ax, ay, kind, shape, prio, id, grp, vis)
  if nitems >= MAXB then return end
  local sw, sh = screen_w(), screen_h()
  if frame_no % 60 == 0 then print(sfmt("[add_item] x=%.1f y=%.1f w=%.1f h=%.1f kind=%d", x, y, w, h, kind)) end
  nitems = nitems + 1
  items[nitems] = sfmt('%.4f %.4f %.4f %.4f %.4f %.4f %d %d %d %d %d %d', x / sw, y / sh, w / sw, h / sh,
                       ax / sw, ay / sh, kind, shape, prio, id, grp or 0, vis or 1)
end

local function inside(clip, x, y)
  if x < 0 or y < 0 or x > screen_w() or y > screen_h() then return false end
  if type(clip) ~= 'table' then return true end
  local l, t = num(clip.x) or 0, num(clip.y) or 0
  local r, b = l + (num(clip.w) or 1e9), t + (num(clip.h) or 1e9)
  return x >= l and x <= r and y >= t and y <= b
end

sig_frame = nil -- the topmost frame that takes every touch, this scan

-- Is f an instance of class c (its metatable chain)?
local function is_a(f, c)
  if type(c) ~= 'table' then return false end
  local m = getmetatable(f)
  for _ = 1, 12 do
    if m == nil then return false end
    if m == c then return true end
    m = getmetatable(m)
  end
  return false
end

-- Frames that cover the whole screen with their own picture and take every
-- touch without saying so: the comic pages (ComicPage draws a black
-- background, has no size and treats a touch anywhere as fast-forward; its
-- green check only comes at the end). Under one, nothing is reachable.
local function covers(f)
  if type(menu) == 'table' and is_a(f, rawget(menu, 'ComicPage')) then return true end
  return f._readyToClose ~= nil and f._levelName ~= nil and f._showTimer ~= nil
end

-- The main menu's two tabs (MainMenu: optionsSlider with its button
-- optionsButton, rightSlider with rightSliderButton): an item's group, 2 or 4
-- for inside the left or right tab, +1 for the tab's own button
GROUPS = {optionsSlider = 2, optionsButton = 3, rightSlider = 4, rightSliderButton = 5}

-- Level selection's pages (levelName 'LevelSelection'): each is one of the
-- level's cameras (originalCameras; camera.lua shows two at a time, pair
-- currentCamera, cameraAnimationSlider 0 for the first and 1 for the
-- second). A level button is the frame of its level object (named after
-- it), so its page is the camera nearest that object -- not where it is on
-- the screen, which a page turning, a camera still easing in or a page
-- zoomed out further than the next (Omelettification's third) blurs.
local function camera_settled()
  local sl = num(cameraAnimationSlider) or 0
  return math.abs(num(sweepSpeed) or 0) < 1 and (sl <= 0.001 or sl >= 0.999)
end
-- Cameras at one place are one page (Fry Me to the Moon has two there, Froot
-- Loops Bloopers seven): each camera's page is the first camera at its place.
ls_cams, ls_pages = nil, {}
local function ls_page_list()
  local cams = originalCameras
  if cams == ls_cams and #ls_pages == #cams then return ls_pages end
  ls_cams, ls_pages = cams, {}
  for i, c in ipairs(cams) do
    local page = i
    if type(c) == 'table' and num(c.px) and num(c.py) then
      local near = (num(screenWidth) or 1024) / math.max(num(c.sx) or 0.4, 0.05) * 0.2
      for j = 1, i - 1 do
        local o = cams[j]
        if type(o) == 'table' and num(o.px) and num(o.py) and math.abs(o.px - c.px) < near and math.abs(o.py - c.py) < near then
          page = ls_pages[j]
          break
        end
      end
    end
    ls_pages[i] = page
  end
  return ls_pages
end
ls_now = nil -- the page shown or being turned to, this scan (nil: not paged)
local function ls_page_now()
  if levelName ~= 'LevelSelection' or type(originalCameras) ~= 'table' or #originalCameras < 2 then return nil end
  local cur = num(currentCamera)
  if not cur or cur < 0 then return nil end
  -- at rest, where the slider is (its target can be left over); turning,
  -- where it is going
  local t = num(cameraAnimationSlider) or 0
  if not camera_settled() then t = num(cameraAnimationSliderTarget) or t end
  return ls_page_list()[cur + 1 + (t >= 0.5 and 1 or 0)]
end
local function ls_page_of(f)
  local w = type(objects) == 'table' and type(objects.world) == 'table' and type(f.name) == 'string' and objects.world[f.name]
  if type(w) ~= 'table' or not num(w.x) or not num(w.y) then return nil end
  local ptw = num(physicsToWorld) or 20
  local x, y = w.x * ptw, w.y * ptw
  local best, bd
  for i, c in ipairs(originalCameras) do
    if type(c) == 'table' and num(c.px) and num(c.py) then
      local dx, dy = c.px - x, c.py - y
      local d = dx * dx + dy * dy
      if not bd or d < bd then best, bd = i, d end
    end
  end
  return best and ls_page_list()[best]
end

-- A level button with nothing on the screen: a comic not reached yet is
-- there, disabled, but comics have no locked picture (originalImageLocked,
-- the definition's spriteLocked) and LevelButton draws nothing for it
-- (Omelettification's second page: the comic after level 21).
local function undrawn(f)
  if f.disabled ~= true or f.originalImageLocked ~= nil or type(f.physicsObject) ~= 'table' then return false end
  local LB = type(menu) == 'table' and rawget(menu, 'LevelButton')
  return type(LB) == 'table' and f.setupDrawBatches == rawget(LB, 'setupDrawBatches')
end

local function is_locked_side_btn(f)
  local name = type(f.name) == 'string' and f.name or ''
  if name == 'lightSideButton' or name == 'darkSideButton' then
    local ch = f.children
    if type(ch) == 'table' then
      for i=1, #ch do
        local c = ch[i]
        local cname = type(c.name) == 'string' and c.name or ''
        if cname == 'lightSideLockIcon' or cname == 'darkSideLockIcon' then
           if c.visible ~= false and not (num(c.alpha) and c.alpha <= 0.05) then
              return true
           end
        end
      end
    end
  end
  return false
end

-- Collect the buttons under f, topmost first; ox, oy = where f's coordinate
-- space starts on screen, ps/pys = the scale of f's ancestors, sf = the
-- scrolling frame f is in. Returns whether f (or a frame in it) takes every
-- touch: then what is under it is hidden and not collected. Items outside
-- the screen or their scrolling frame's clip (the next page of levels) are
-- kept, marked not visible, so the focus can go to them.
collect = function(f, ox, oy, ps, pys, depth, clip, base, sf, grp)
  if depth > 16 or not live(f) then return false end
  grp = GROUPS[f.name] or grp
  local fx, fy = num(f.x) or 0, num(f.y) or 0
  local cx, cy, cclip, csf = ox + fx, oy + fy, clip, sf
  if type(f.scroll) == 'table' then
    -- ScrollFrame: its children see (x * scale + scroll * scale) - self.x
    local sx, sy = num(f.scaleX) or 1, num(f.scaleY) or 1
    if sx == 0 then sx = 1 end
    if sy == 0 then sy = 1 end
    cx = ox + fx / sx - (num(f.scroll.x) or 0)
    cy = oy + fy / sy - (num(f.scroll.y) or 0)
    if type(f.clip) == 'table' then cclip = f.clip end
    csf = f
  end
  local before = nitems
  local blocks = false
  local ch = f.children
  if type(ch) == 'table' then
    local cps, cpys = ps * (num(f.scaleX) or 1), pys * (num(f.scaleY) or 1)
    local cgrp = grp and (grp % 2 == 1 and grp - 1 or grp) -- a tab button's children are the tab's
    for i = #ch, 1, -1 do
      if collect(ch[i], cx, cy, cps, cpys, depth + 1, cclip, base, csf, cgrp) then
        blocks = true
        break
      end
    end
  end
  if handles(f, base) then
    if type(f.name) == 'string' and f.name ~= 'bg' and f.name ~= 'background' and not string.find(f.name, 'Button') and not string.find(f.name, 'shop') then
      -- print(sfmt('[btn-debug] handles f.name=%s', f.name))
    end
    local x, y, w, h = box(f, ps, pys)
    if x then
      x, y = ox + x, oy + y
      if w * h >= big then blocks = true end
      -- The shop scroll frame is big but we still want its tab buttons
      local nm = type(f.name) == 'string' and f.name or ''
      if nm == 'scrollFrame_characterMenuShop' then blocks = false end
      -- Some shop tab buttons are marked 'disabled' but are still tappable
      local force_enabled = (nm == 'carboniteButton' or nm == 'giftButton' or
                             nm == 'currencyShopButton' or
                             sfind(nm, 'offerButton', 1, true))
      if nitems == before and w * h < big and (f.enabled ~= false or force_enabled) and
         not (num(f.alpha) and f.alpha <= 0.05) and
         not undrawn(f) and not sfind(nm, 'BLOCK_MENU_EPISODE_BUTTON', 1, true) then
        local is_small_side = (nm == 'lightSideButton' or nm == 'darkSideButton') and w <= 100
        -- Flying ships in the main menu are banners of exactly ~198.8×51.8; skip them specifically
        local in_mm_screen = (type(captured_env) == 'table' and captured_env.levelName == 'MainMenu')
        local is_mm_ship = in_mm_screen and (w > 175 and w < 225 and h > 40 and h < 65)
        if not is_small_side and not is_mm_ship then
          local round = (w / h > 0.8 and w / h < 1.25) and 1 or 0
          local vis = inside(clip, x + w * 0.5, y + h * 0.5) and 1 or 0
          -- a level button: on the screen when its page is
          local page = ls_now and ls_page_of(f)
          if page then vis = page == ls_now and 1 or 0 end
          local id = id_of(f)
          if type(f.name) == 'string' then
            if f.name == 'lightSideButton' and w > 100 then
              focused_light_locked = is_locked_side_btn(f)
              focused_light_id = id
            elseif f.name == 'darkSideButton' and w > 100 then
              focused_dark_locked = is_locked_side_btn(f)
              focused_dark_id = id
            end
            if string.find(string.lower(f.name), "side") then
              print("[btn-debug] SIDE FRAME: " .. f.name .. " w=" .. tostring(w))
            end
          end
          seen_next[id] = {f = f, sf = sf, x0 = x, y0 = y, x1 = x + w, y1 = y + h, grp = grp, page = page}
          add_item(x, y, w, h, x + w * 0.5, y + h * 0.5, KIND_BUTTON, round, prio_of(f), id, grp, vis)
        end
      else
        if type(f.name) == 'string' and f.name ~= 'bg' then
          local cond = ""
          if w * h >= big then cond = cond .. " big" end
          if f.enabled == false then cond = cond .. " disabled" end
          if num(f.alpha) and f.alpha <= 0.05 then cond = cond .. " alpha" end
          if undrawn(f) then cond = cond .. " undrawn" end
          -- print('[btn-debug] skipped ' .. f.name .. ' due to:' .. cond .. ' x=' .. x .. ' y=' .. y)
        end
      end
    end
  end
  if not blocks and depth <= 3 and (covers(f) or modal(f, base)) then
    blocks = true
  end
  if blocks and not sig_frame then sig_frame = f end
  return blocks
end

-- Level selection is a scene of its own (levelName 'LevelSelection', the
-- episode's LevelSelection.lua): its pages are cameras, and the level buttons
-- are frames that follow the camera. The controller turns a page itself,
-- the way the port's stick moves a level's camera: the pair of cameras
-- (changeCameras(i): cameras i + 1 and i + 2) set to the page it is on and
-- the next, then cameraAnimationSlider eased from one to the other over
-- PAGE_SECS with isSwipingCamera held and a sweepSpeed too small to move it
-- or be braked (doItAllCamera follows the slider exactly only while there
-- is a sweep; at 0 the view trails it on a slow spring), so the view never
-- leaves the stretch between the two pages -- the game's own turn (updatePCCameraPanningToDirection, the PC's
-- arrow keys: a sweep that brakes by the frame's time) overshot its page
-- and swung back, and in Omelettification went out past the first page and
-- jumped back to it. At the first or the last page it stays. `right` is on
-- the screen: the mirror world's pages run the other way.
g_abs_last_side = 'bird'
last_flip = -100
cmd_focus = nil -- the focus when ZL/ZR last turned a page: left behind
page_turn = nil -- the turn under way (page_turn_update)
ls_pan_dir = nil   -- swipe direction being animated
ls_pan_frames = 0  -- how many frames the swipe has been in progress
ls_pan_sig = nil     -- sum of item x0 last frame (camera-motion detector)
ls_pan_still = 0     -- consecutive frames with no item movement
last_flip_item = nil  -- id of item that triggered the last swipe (ping-pong guard)
PAGE_SECS = 0.75
local PAGE_SWEEP = 1e-4
-- reqs/request must be declared before flip_page so flip_page can call request()
-- (Lua 5.1: locals are only in scope for functions declared after them)
local reqs = {}
local function request(r) reqs[#reqs + 1] = r end
local function flip_page(right, item_id)
  if levelName ~= 'LevelSelection' then return false end
  if not item_id then _G._reveal_target = nil end
  local settled = camera_settled()
  local frames_since = frame_no - last_flip
  -- Rate limit: one swipe per 90 frames (~1.5s).
  if page_turn or frames_since < 90 then
    print(sfmt('[flip_page] BLOCKED right=%s frames_since=%d', tostring(right), frames_since))
    return true
  end
  -- Ping-pong guard: if the SAME item triggers swipes in BOTH directions, it's
  -- sitting on the border between pages. Block and redirect focus away from it.
  if item_id and item_id == last_flip_item then
    print(sfmt('[flip_page] PING-PONG guard: item %d is oscillating, skipping', item_id))
    -- Force focus to a different item far from this one
    local sw2 = screen_w()
    local ic = seen[item_id]
    local item_cx = ic and (ic.x0 + ic.x1) * 0.5 or sw2 * 0.5
    local best_id, best_d
    for vid, vit in pairs(seen) do
      if vid ~= item_id then
        local vcx = (vit.x0 + vit.x1) * 0.5
        -- Prefer items on the opposite side of screen from the oscillating one
        local target_x = item_cx > sw2 * 0.5 and sw2 * 0.25 or sw2 * 0.75
        local d = math.abs(vcx - target_x)
        if not best_d or d < best_d then best_id, best_d = vid, d end
      end
    end
    if best_id then
      focus_id = best_id
      last_flip_item = nil  -- allow fresh swipe from new item
    end
    return true
  end
  local cams, cur = originalCameras, num(currentCamera)
  print(sfmt('[flip_page] TRY right=%s cur=%s settled=%s', tostring(right), tostring(cur), tostring(settled)))
  local mirror = type(mirrorWorldHandler) == 'table' and mirrorWorldHandler.mirror and true or false
  local onward = (right and true or false) ~= mirror
  local step = onward and 1 or -1
  local at, nt
  if type(cams) == 'table' and #cams >= 2 and cur and cur >= 0 then
    at = cur + 1 + ((num(cameraAnimationSlider) or 0) >= 0.5 and 1 or 0)
    local pages = ls_page_list()
    nt = at + step
    while nt >= 1 and nt <= #cams and pages[nt] == pages[at] do nt = nt + step end
    if nt < 1 or nt > #cams then
      print(sfmt('[flip_page] AT BOUNDARY at=%s nt=%s ncams=%d', tostring(at), tostring(nt), #cams))
      return true
    end
  end
  if not nt then
    last_flip = frame_no
    last_flip_item = item_id  -- remember which item triggered this
    ls_pan_dir = right
    ls_pan_frames = 0
    ls_pan_sig = nil
    ls_pan_still = 0
    local req_str = right and 'swipe_right' or 'swipe_left'
    request(req_str)
    print(sfmt('[flip_page] SWIPE %s item=%s', req_str, tostring(item_id)))
    return true
  end
  -- the pair ending on it, its other camera on this page
  local i = onward and nt - 2 or nt - 1
  if cur ~= i and (not pcall(changeCameras, i) or num(currentCamera) ~= i) then return true end
  local from, to = onward and 0 or 1, onward and 1 or 0
  local sweep = onward and -PAGE_SWEEP or PAGE_SWEEP -- the slider runs against the sweep
  last_flip = frame_no
  cameraAnimationSlider = from
  cameraAnimationSliderTarget = to
  sweepSpeed = sweep
  isSwipingCamera = true
  if type(doItAllCamera) == 'function' then cameraFunction = doItAllCamera end
  local x0, x1 = num(cams[at] and cams[at].px), num(cams[nt] and cams[nt].px)
  page_turn = {cam = i, from = from, to = to, sweep = sweep, t0 = num(time), n = 0, last = from, src = at, dest = nt,
               lo = x0 and x1 and math.min(x0, x1), hi = x0 and x1 and math.max(x0, x1), worst = 0}
  -- the level's stars stir, as for the game's own turn
  if type(objects) == 'table' and type(objects.levelStars) == 'table' and type(applyImpulse) == 'function' then
    for k, v in pairs(objects.levelStars) do
      if type(v) == 'table' and num(v.x) then pcall(applyImpulse, k, step * 2 * math.random(), 0, v.x, v.y) end
    end
  end
  return true
end

-- The focused item (its id from the controller), brought into view when it
-- is off the screen or its page: a paged scroller (ScrollFrame) goes to the
-- page that shows it, as its own next() / previous() do; a free one
-- (ScrollFrameFree: the Solar System's strip of planets) is given the
-- speed that carries it there, as a flick would (its update adds
-- velocity[axis] * dt and keeps 0.8 of it each update); level selection
-- turns its page.
local function reveal(id)
  local it = seen[id]
  -- not the item ZL/ZR has just paged away from (the controller brings the
  -- focus onto the new page)
  if not it or id == cmd_focus then return end
  local sw = screen_w()
  -- LevelSelection uses camera paging, not scroll frames
  if levelName == 'LevelSelection' then
    -- While the camera is actively panning to a new page, do nothing —
    -- the item will naturally come into view when the pan finishes.
    if ls_pan_dir ~= nil then return end
    local cx = (it.x0 + it.x1) * 0.5
    local sw2 = screen_w()
    local off_right = cx > sw2
    local off_left  = cx < 0
    local settled = camera_settled()
    -- Log every time the focused item is off-screen (limit to avoid spam)
    if (off_right or off_left) and frame_no % 6 == 0 then
      print(sfmt('[reveal] id=%d cx=%.0f sw=%.0f off_right=%s off_left=%s settled=%s page_turn=%s',
        id, cx, sw2, tostring(off_right), tostring(off_left), tostring(settled), tostring(page_turn ~= nil)))
    end
    if off_right or off_left then
      -- Call flip_page regardless of settled state — flip_page has its own
      -- rate limiter (frames_since guard). The camera in LevelSelection after
      -- a partial swipe may never report settled=true, so we can't wait for it.
      if not page_turn then
        print(sfmt('[reveal] CALLING flip_page right=%s id=%d cx=%.0f settled=%s', tostring(off_right), id, cx, tostring(settled)))
        _G._reveal_target = id
        if off_right then flip_page(true, id) else flip_page(false, id) end
      end
    else
      if _G._reveal_target == id then _G._reveal_target = nil end
    end
    return
  end
  local f = it.sf
  if type(f) ~= 'table' then
    local cx = (it.x0 + it.x1) * 0.5
    if cx > sw then flip_page(true) elseif cx < 0 then flip_page(false) end
    return
  end
  local l, r = 0, sw
  if type(f.clip) == 'table' then
    l = num(f.clip.x) or 0
    r = l + (num(f.clip.w) or sw)
  end
  local margin = (it.x1 - it.x0) * 0.25
  local d = 0
  if it.x0 < l + margin then d = it.x0 - (l + margin) end
  if it.x1 > r - margin then d = it.x1 - (r - margin) end
  if d == 0 then return end
  local scroll = f.scroll
  local target = (num(scroll.x) or 0) + d
  if type(f.anchors) == 'table' and #f.anchors > 0 then
    local best, bd
    for i, a in ipairs(f.anchors) do
      local ax = num(a.x)
      if ax then
        local off = ax - (num(scroll.x) or 0)
        if it.x0 - off >= l and it.x1 - off <= r then
          local dist = math.abs(ax - target)
          if not bd or dist < bd then best, bd = i, dist end
        end
      end
    end
    if best and f.target_anchor ~= best then
      f.target_anchor = best
      if type(f.velocity) ~= 'table' then f.velocity = 8 end
    end
  elseif type(f.velocity) == 'table' and (f.axis == nil or f.axis == 'x') then
    local lo, hi = num(f.scroll_min), num(f.scroll_max)
    if lo and target < lo then target = lo end
    if hi and target > hi then target = hi end
    local v = num(f.velocity.x) or 0
    if f.dragging ~= true and math.abs(v) < 20 then
      f.velocity.x = (target - (num(scroll.x) or 0)) * 12
    end
  end
end


-- --------------------------------------------------------- the planets
-- The episode selection page is a SpriteScene: a carousel of planets (and
-- their tiny planets), drawn in 3D and picked by the scene itself:
-- SpriteScene.onPointerEvent calls _scene:pickEntity(cursor) -> the names of
-- the entities under the point (a test against each one's rectangle). Where
-- the planet in the middle is on screen is found the same way: by asking the
-- scene at a grid of points, a few rows per update, then its edges exactly.
-- f is g or inside it
local function within(f, g)
  for _ = 1, 24 do
    if f == g then return true end
    if type(f) ~= 'table' then return false end
    f = f._parent
  end
  return false
end

local function find_episode_page(f, depth)
  if depth > 10 or not live(f) then return nil end
  if type(f._entityEpisodeMapping) == 'table' or type(f._positionMapping) == 'table' or
     f._currentAnchor ~= nil or f.name == 'EpisodeSelection' or f.name == 'episodeSelection' or
     f.name == 'EpicSelection' or f.name == 'epicSelection' then
    return f
  end
  local ch = f.children
  if type(ch) == 'table' then
    for i = #ch, 1, -1 do
      local p = find_episode_page(ch[i], depth + 1)
      if p then return p end
    end
  end
  return nil
end

local GX, GY, ROWS_PER_UPDATE = 40, 24, 4
local scan = {page = nil, row = 0, boxes = {}, list = nil}

local function scene_of(page)
  local sf = call(page.getChild, page, 'sceneFrame')
  local sc = type(sf) == 'table' and sf._scene
  if sc and sc.pickEntity then return sc end
  return nil
end

local function picks(sc, x, y, id)
  local ok, l = pcall(sc.pickEntity, sc, {x = x, y = y})
  if ok and type(l) == 'table' then
    for _, v in ipairs(l) do if v == id then return true end end
  end
  return false
end

-- an edge between a point that picks the entity and one that does not
local function edge(sc, id, a, b, y, x, horiz)
  for _ = 1, 6 do
    local m = (a + b) * 0.5
    local hit = horiz and picks(sc, m, y, id) or (not horiz and picks(sc, x, m, id))
    if hit then a = m else b = m end
  end
  return (a + b) * 0.5
end

-- The name sign of a planet: the scene file (the page's own,
-- scenes/EpisodeSelection.lua) makes each planet one entity of parts -- its
-- picture, its sign (a localized sprite 94 units under the middle), its score
-- box, a pig on top, each part's position in its own scale. The parts'
-- rectangles, laid out, are fitted to the entity's rectangle on screen; the
-- sign's follows.
local scene_def
local function part_rects(p, U, S, ox, oy, depth)
  if type(p) ~= 'table' or depth > 6 then return end
  if type(p.composite) == 'table' then
    for _, c in ipairs(p.composite) do part_rects(c, U, S, ox, oy, depth + 1) end
  end
  if p.trueDef or p.falseDef then part_rects(p.trueDef or p.falseDef, U, S, ox, oy, depth + 1) end
  if type(p.frames) == 'table' and type(p.frames[1]) == 'table' then
    part_rects(p.frames[1].def, U, S, ox, oy, depth + 1)
  end
  local name, sign = p.sprite, false
  if not name and p.metaType == 'localized' and type(p.metaData) == 'table' and p.metaData.key == 'sprite' then
    name = p.metaData.value
    local ok, l = false, nil
    if type(res) == 'table' then ok, l = pcall(res.getString, 'TEXTS_BASIC', name) end
    if ok and type(l) == 'string' and l ~= '' then name = l end
    sign = true
  end
  if type(name) ~= 'string' or type(res) ~= 'table' then return end
  local ok, w, h = pcall(res.getSpriteBounds, name)
  local ok2, px, py = pcall(res.getSpritePivot, name)
  if not (ok and num(w) and num(h) and w > 0 and h > 0) then return end
  if not (ok2 and num(px) and num(py)) then px, py = w / 2, h / 2 end
  local sc = num(p.scale) or 1
  local pos = type(p.pos) == 'table' and p.pos or {}
  local x = ox + (num(pos.x) or 0) * sc - px * sc
  local y = oy + (num(pos.y) or 0) * sc - py * sc
  local r = {x, y, x + w * sc, y + h * sc}
  U[1], U[2] = math.min(U[1], r[1]), math.min(U[2], r[2])
  U[3], U[4] = math.max(U[3], r[3]), math.max(U[4], r[4])
  if sign and not S[1] then S[1], S[2], S[3], S[4] = r[1], r[2], r[3], r[4] end
end

local function sign_box(id, b)
  if scene_def == nil then
    local ok, t = false, nil
    if type(native) == 'table' and type(native.loadLuaTable) == 'function' then
      ok, t = pcall(native.loadLuaTable, 'scenes/EpisodeSelection.lua', true)
    end
    scene_def = ok and type(t) == 'table' and t or false
  end
  local ent = scene_def and type(scene_def.entities) == 'table' and scene_def.entities[id]
  local def = type(ent) == 'table' and ent.def
  local U, S = {1e9, 1e9, -1e9, -1e9}, {}
  if type(def) == 'table' then part_rects(def, U, S, 0, 0, 0) end
  local bw, bh = b.x1 - b.x0, b.y1 - b.y0
  if S[1] and U[3] > U[1] and U[4] > U[2] then
    local uw, uh = U[3] - U[1], U[4] - U[2]
    local k = (bw + bh) / (uw + uh)
    if math.abs(k * uw - bw) < bw * 0.25 and math.abs(k * uh - bh) < bh * 0.25 then
      local ox = (b.x0 + b.x1) * 0.5 - k * (U[1] + U[3]) * 0.5
      local oy = (b.y0 + b.y1) * 0.5 - k * (U[2] + U[4]) * 0.5
      return ox + k * S[1], oy + k * S[2], k * (S[3] - S[1]), k * (S[4] - S[2])
    end
  end
  -- the layout did not fit: where the signs usually are
  return b.x0 + bw * 0.12, b.y0 + bh * 0.6, bw * 0.76, bh * 0.2
end

-- the carousel position in the middle (EpisodeSelection's own wrap)
local function wrap_pos(p, count)
  if not p or not count or count <= 0 then return p end
  return (p - 1) % count + 1
end

local function scan_rows(page)
  local sc = scene_of(page)
  if not sc then return end
  if scan.page ~= page then
    scan.page, scan.row, scan.boxes, scan.list = page, 0, {}, nil
  end
  local sw, sh = screen_w(), screen_h()
  local y0, y1 = sh * 0.10, sh * 0.98
  local pt = {x = 0, y = 0}
  local boxes = scan.boxes
  local posmap = type(page._positionMapping) == 'table' and page._positionMapping or {}
  local eps = type(page._entityEpisodeMapping) == 'table' and page._entityEpisodeMapping or {}
  local links = type(page._entityLinkMapping) == 'table' and page._entityLinkMapping or {}
  -- the carousel goes round: the page wraps its positions into
  -- 1.._buttonCount, the anchor does not
  local anchor = num(page._currentAnchor)
  local count = num(page._buttonCount)
  local cpos = anchor and wrap_pos(math.ceil(anchor - 0.5), count)
  local cnext, cprev = cpos and wrap_pos(cpos + 1, count), cpos and wrap_pos(cpos - 1, count)
  for _ = 1, ROWS_PER_UPDATE do
    local j = scan.row
    pt.y = y0 + (y1 - y0) * (j + 0.5) / GY
    for i = 0, GX - 1 do
      pt.x = sw * (i + 0.5) / GX
      local ok, l = pcall(sc.pickEntity, sc, pt)
      if ok and type(l) == 'table' then
        -- what a tap here opens: EpisodeSelection goes through the entities
        -- under it, those of the middle position and its two neighbours; the
        -- last episode wins, a link ends the search
        local win
        for _, id in ipairs(l) do
          local b = boxes[id]
          if not b then
            b = {x0 = pt.x, x1 = pt.x, y0 = pt.y, y1 = pt.y, n = 0, sx = 0, sy = 0, wn = 0, wx = 0, wy = 0}
            boxes[id] = b
          end
          if pt.x < b.x0 then b.x0 = pt.x end
          if pt.x > b.x1 then b.x1 = pt.x end
          if pt.y < b.y0 then b.y0 = pt.y end
          if pt.y > b.y1 then b.y1 = pt.y end
          b.n = b.n + 1
          b.sx = b.sx + pt.x
          b.sy = b.sy + pt.y
        end
        for _, id in ipairs(l) do
          local ps = posmap[id]
          if ps and (ps == cpos or ps == cnext or ps == cprev) then
            if eps[id] then
              win = id
            elseif links[id] then
              win = id
              break
            end
          end
        end
        local b = win and boxes[win]
        if b then
          b.wn = b.wn + 1
          b.wx = b.wx + pt.x
          b.wy = b.wy + pt.y
        end
      end
    end
    scan.row = j + 1
    if scan.row >= GY then
      -- a whole pass: it becomes what is reported
      local cw, chh = sw / GX, (y1 - y0) / GY
      -- the planet in the middle: the episode at the middle position that
      -- turns the carousel (not a sign beside it that opens an episode of
      -- its own, as Froot Loops Bloopers does by Brass Hogs)
      local centre, centre_n = nil, 0
      for id, b in pairs(boxes) do
        local e = eps[id]
        if e and not (type(e) == 'table' and e.ignoreAnchor) and
           ((cpos and posmap[id] == cpos) or (not cpos and b.n > centre_n)) then
          centre, centre_n = id, b.n
        end
      end
      local function edges(id, b)
        local cy, cx = (b.y0 + b.y1) * 0.5, (b.x0 + b.x1) * 0.5
        return {
          x0 = edge(sc, id, b.x0, b.x0 - cw, cy, nil, true),
          x1 = edge(sc, id, b.x1, b.x1 + cw, cy, nil, true),
          y0 = edge(sc, id, b.y0, b.y0 - chh, nil, cx, false),
          y1 = edge(sc, id, b.y1, b.y1 + chh, nil, cx, false),
        }
      end
      -- only the planet in the middle is reported (the ones beside it turn
      -- the carousel: left/right; the tiny planets are for the cursor), and
      -- an episode's sign beside it
      local list = {}
      local b = centre and boxes[centre]
      if b then
        -- its exact edges, then its sign
        local sx, sy, sw2, sh2 = sign_box(centre, edges(centre, b))
        list[1] = {sx, sy, sw2, sh2, b.sx / b.n, b.sy / b.n, KIND_CENTRE, 9, 1}
      end
      for id, bb in pairs(boxes) do
        local e = eps[id]
        if type(e) == 'table' and e.ignoreAnchor and cpos and posmap[id] == cpos and bb.wn > 0 then
          -- tapped where a tap opens it
          local r = edges(id, bb)
          list[#list + 1] = {r.x0, r.y0, r.x1 - r.x0, r.y1 - r.y0, bb.wx / bb.wn, bb.wy / bb.wn, KIND_BUTTON, 2,
                             id_of('entity:' .. tostring(id))}
        end
      end
      scan.list = list
      scan.turning = anchor and math.abs(anchor - math.floor(anchor + 0.5)) > 0.02
      scan.row, scan.boxes = 0, {}
      break
    end
  end
end

-- 0 no carousel, 1 settled, 2 turning
local function planets(page)
  scan_rows(page)
  local l = scan.list
  if type(l) ~= 'table' then return 0 end
  local anchor = num(page._currentAnchor)
  local turning = anchor and math.abs(anchor - math.floor(anchor + 0.5)) > 0.02
  for _, it in ipairs(l) do
    -- while it turns, only the planet (its ring hidden): the rest has moved
    if it[7] == KIND_CENTRE or not turning then
      add_item(it[1], it[2], it[3], it[4], it[5], it[6], it[7], 0, it[8], it[9], 0, 1)
    end
  end
  return turning and 2 or 1
end

-- A turn of the carousel, quicker than the game's (its onKeyEvent: 0.5 s,
-- eased out) and made on its own animator, as it makes it: a press at rest
-- goes to the next planet past the one nearest, in secs (C: 0.34 s). A
-- stick held (C sends the presses sooner and sooner, each with its time) runs
-- on: while the carousel moves, each press goes one planet past the last one
-- asked for (never more than two ahead of where it is), and starts at the
-- speed it has -- a cubic from that speed to rest, the game's own ease-out
-- from rest -- so the planets glide rather than stop at each.
local spin_last -- the turn made last: {fn, s, from, to, secs}
local function spin(page, dir, secs)
  if not page then return end
  secs = secs or 0.34
  local an = call(page.getChild, page, 'animator')
  local a = num(page._currentAnchor)
  local fa = type(ui) == 'table' and ui.FrameAnimator
  if type(an) == 'table' and type(an.setAnimation) == 'function' and a and type(fa) == 'table' then
    local step = dir == 'RIGHT' and 1 or -1
    -- where it goes now and how fast (anchor per second)
    local v, to = 0, nil
    local t, len, tg = num(an._t), num(an._length), type(an._targets) == 'table' and an._targets._currentAnchor
    if t and len and len > 0 and t >= 0 and t < 1 and type(tg) == 'table' and num(tg.v1) and num(tg.v2) then
      local d1
      if spin_last and an._interpolator == spin_last.fn then
        local sl = spin_last.s
        d1 = sl + 2 * (3 - 2 * sl) * t + 3 * (sl - 2) * t * t
      elseif an._interpolator == fa.cubicEaseOut then
        d1 = 3 * (1 - t) * (1 - t)
      end
      if d1 then
        v = (tg.v2 - tg.v1) * d1 / len
        to = tg.v2
      end
    end
    local target
    if to and v * step > 0.05 then
      target = to + step
      if (target - a) * step > 2 then target = to end
    else
      v = 0
      target = step > 0 and math.floor(a) + 1 or math.ceil(a) - 1
      if math.abs(a - target) < 0.5 then target = target + step end
    end
    local d = target - a
    local s = 3
    if v ~= 0 and d ~= 0 then s = math.max(0, math.min(3, v * secs / d)) end
    local fn
    if s >= 3 then
      fn = fa.cubicEaseOut
    else
      fn = function(x) return s * x + (3 - 2 * s) * x * x + (s - 2) * x * x * x end
    end
    if type(fn) == 'function' and pcall(an.setAnimation, an, {_currentAnchor = target}, secs, fn) then
      spin_last = {fn = fn, s = s}
      return
    end
  end
  if type(page.onKeyEvent) == 'function' then
    pcall(page.onKeyEvent, page, 'PRESS', dir)
  end
end

-- the main menu's flags: 1 it is the main menu, 2 its left tab is open, 4 its right one
local function main_menu_flags()
  local mm = menu_manager()
  local root = base_frame()
  if type(root) ~= 'table' or type(root.getChild) ~= 'function' then return 0 end
  local l = call(root.getChild, root, 'optionsSlider')
  if type(l) ~= 'table' then return 0 end
  local r = call(root.getChild, root, 'rightSlider')
  local function open(t) return type(t) == 'table' and (t.state == 'OPEN' or t.state == 'OPENING') end
  return 1 + (open(l) and 2 or 0) + (open(r) and 4 or 0)
end

local function buttons()
  items, nitems = {}, 0
  focused_light_locked = false
  focused_dark_locked = false
  focused_light_id = -1
  focused_dark_id = -1
  big = screen_w() * screen_h() * 0.7
  sig_frame = nil
  seen_next = {}
  local mm = menu_manager()
  local b = base_frame()

  -- removed debug prints for brevity

  local page = b and find_episode_page(b, 0)
  local okp, lp = pcall(ls_page_now)
  ls_now = okp and lp or nil
  if b then
    local ok, err = pcall(collect, b, 0, 0, 1, 1, 0, nil, base_handler(), nil, nil)
    if not ok and captured_env and frame_no % 60 == 0 then
      print(sfmt('[btn-debug] collect ERROR: %s', tostring(err)))
    end
  end
  -- the planets, when the episode page is what takes the touches: nothing
  -- blocks, or only the page or its scene (full screen, it takes every
  -- touch), not a popup on top
  local carousel = 0
  local sf = page and call(page.getChild, page, 'sceneFrame')
  if page and (sig_frame == nil or sig_frame == b or sig_frame == page or
               (type(sf) == 'table' and within(sig_frame, sf))) then
    local ok, r = pcall(planets, page)
    if ok then carousel = r end
  end
  -- ABSW2 fallback: manually inject KIND_CENTRE if on episode selection screen
  local ln = type(captured_env) == 'table' and captured_env.levelName
  if type(ln) == 'string' and (ln == 'EpisodeSelection' or sfind(ln, 'pisodeSel', 1, true) or
                               ln == 'WorldSelection' or sfind(ln, 'orldSel', 1, true)) then
    if focused_light_locked and focused_dark_locked then
      -- Fully locked planet: remove both side buttons and add center big padlock
      local new_items = {}
      local new_n = 0
      for i=1, nitems do
        local id = -1
        local count = 0
        for w in string.gmatch(items[i], "%S+") do
          count = count + 1
          if count == 10 then id = tonumber(w); break end
        end
        if id ~= focused_light_id and id ~= focused_dark_id then
          new_n = new_n + 1
          new_items[new_n] = items[i]
        end
      end
      items = new_items
      nitems = new_n
      
      local sw, sh = screen_w(), screen_h()
      local cx, cy = sw * 0.5, sh * 0.5
      -- add_item(x, y, w, h, ax, ay, kind, shape, prio, id, grp, vis)
      add_item(cx - 50, cy - 50, 100, 100, cx, cy, KIND_CENTRE, 9, 1, 9999, 0, 1)
    end
  end
  seen = seen_next
  if focused_dark_id and focused_dark_id ~= -1 then
    g_abs_last_side = 'bird'
  elseif focused_light_id and focused_light_id ~= -1 then
    g_abs_last_side = 'pork'
  end

  local sig = sig_frame and ssub(tostring(sig_frame), 8) or 'none'
  sig = sig:gsub('%s', '')
  local ln_sig = type(captured_env) == 'table' and type(captured_env.levelName) == 'string' and captured_env.levelName or 'none'
  
  local ep_sig = ""
  if type(captured_env) == 'table' then
      ep_sig = type(captured_env.levelFolder) == 'string' and captured_env.levelFolder or (type(captured_env.levelPath) == 'string' and captured_env.levelPath or "")
  end
  if ep_sig == "" then
      ep_sig = type(levelFolder) == 'string' and levelFolder or (type(levelPath) == 'string' and levelPath or "")
  end
  if ep_sig ~= "" then
      -- Extract the last two directories or just something unique
      -- e.g. "levels/episode1/birdside" -> "episode1_birdside"
      ep_sig = string.gsub(ep_sig, "/", "_")
      ep_sig = string.sub(ep_sig, -10) -- last 10 characters should be unique enough
  end

  sig = ssub(ln_sig, 1, 6) .. '_' .. ep_sig .. '_' .. sig
  sig = ssub(sig, 1, 23)
  if sig == '' then sig = 'none' end

  -- debug: print when in menu but no items found
  if captured_env and frame_no % 60 == 0 then
    if nitems == 0 then
      print(sfmt('[btn-debug] WARNING: 0 buttons after collect, sig=%s carousel=%d', sig, carousel))
    else
      print(sfmt('[btn-debug] collected %d items, sig=%s carousel=%d', nitems, sig, carousel))
      for i=1,nitems do
        print(sfmt('[btn-debug]   item[%d]: %s', i, items[i]))
      end
    end
  end

  return nitems, concat(items, ' ', 1, nitems), sig, page, carousel
end


-- a visible button whose returnValue / name / image mentions `word`
local function find_button(f, ox, oy, ps, pys, word, depth, base)
  if depth > 16 or not live(f) then return nil end
  if handles(f, base) and sfind(names_of(f), word, 1, true) then
    local x, y, w, h = box(f, ps, pys)
    if x then return ox + x + w * 0.5, oy + y + h * 0.5 end
  end
  local ch = f.children
  if type(ch) == 'table' then
    local fx, fy = num(f.x) or 0, num(f.y) or 0
    local cps, cpys = ps * (num(f.scaleX) or 1), pys * (num(f.scaleY) or 1)
    for i = #ch, 1, -1 do
      local x, y = find_button(ch[i], ox + fx, oy + fy, cps, cpys, word, depth + 1, base)
      if x then return x, y end
    end
  end
  return nil
end

-- The power-ups bar at a level's bottom left (GameHud.powerupSlider, a
-- ui.Slider): folded when a level starts -- the game would open it as it
-- was last left (SettingsWrapper:getIsPowerUpSliderOpen) -- and Y opens and
-- folds it, as its lightning button does.
local function powerup_bar()
  local mm = type(GameSystem) == 'table' and GameSystem.menuManager
  local root = base_frame()
  local hud = type(root) == 'table' and type(root.getChild) == 'function' and root:getChild('gameHud')
  local sl = type(hud) == 'table' and hud.powerupSlider
  if type(sl) == 'table' and type(sl.toggle) == 'function' then return sl end
end

local function fold_powerup_bar()
  local SW = SettingsWrapper
  if type(SW) ~= 'table' or type(SW.getIsPowerUpSliderOpen) ~= 'function' or rawget(SW, '_absBarFolded') then return end
  SW._absBarFolded = true
  SW.getIsPowerUpSliderOpen = function() return false end
end

-- The Space Eagle's score (GameHud): the game's scripts put a developers'
-- readout there -- the score, a line break, the eagle percentage -- unless
-- the global releaseBuild is true, and nothing sets it on Android (the
-- engine only reads it). The score font has no line spacing, so the two
-- lines are drawn over each other ("11670" on "77%"). The percentage alone
-- stays, as the release format has it.
local function eagle_line(hud)
  local t = type(hud) == 'table' and call(hud.getChild, hud, 'eagleHighscore')
  local s = type(t) == 'table' and call(t.getText, t)
  if type(s) == 'string' and sfind(s, '\n', 1, true) then pcall(t.setText, t, s:match('([^\n]*)$')) end
end
-- Once the eagle is used (GameHud.eagleScore, set by EID_MIGHTY_EAGLE_MODE_START
-- or at a level's start) the HUD shows the eagle's percentage in place of the
-- score (layoutEagleScore). The pause page hides the score but leaves the
-- eagle's parts, and going back to the level (returnToGame) shows the score
-- again over the percentage: paused, the eagle's parts go too; back in the
-- level, the eagle's layout again.
local EAGLE_PARTS = {'eagleHighscoreText', 'eagleHighscore', 'feather'}
local function hook_eagle_score()
  local H = type(menu) == 'table' and rawget(menu, 'GameHud')
  if type(H) ~= 'table' or rawget(H, '__abs_eagle') then return end
  H.__abs_eagle = true
  local function wrap(name, after)
    local orig = H[name]
    if type(orig) ~= 'function' then return end
    H[name] = function(self, ...)
      local r = orig(self, ...)
      pcall(after, self)
      return r
    end
  end
  wrap('updateScoreTexts', eagle_line)
  wrap('layoutEagleScore', eagle_line)
  wrap('showPauseMenu', function(self)
    if self.eagleScore ~= true then return end
    for _, n in ipairs(EAGLE_PARTS) do
      local c = call(self.getChild, self, n)
      if type(c) == 'table' then c.visible = false end
    end
  end)
  wrap('returnToGame', function(self)
    if self.eagleScore == true and type(self.layoutEagleScore) == 'function' then self:layoutEagleScore() end
  end)
end

-- The pause page (PausePage.draw) lays black over the level, its opacity
-- following the page as it slides in, to fully opaque. It is dimmed here
-- instead: the page's first drawRect (that cover) at PAUSE_DIM of it, so the
-- level shows through.
local PAUSE_DIM = 0.6
local function dim_pause_page()
  local P = type(menu) == 'table' and rawget(menu, 'PausePage')
  if type(P) ~= 'table' or rawget(P, '__abs_dim') or type(P.draw) ~= 'function' then return end
  P.__abs_dim = true
  local orig = P.draw
  P.draw = function(self, ...)
    local dr = drawRect
    if type(dr) ~= 'function' then return orig(self, ...) end
    local first = true
    drawRect = function(r, g, b, a, ...)
      if first then
        first = false
        if type(a) == 'number' then a = a * PAUSE_DIM end
      end
      return dr(r, g, b, a, ...)
    end
    local ok, e = pcall(orig, self, ...)
    drawRect = dr
    if not ok then error(e, 0) end
  end
end

local function tap_button(word)
  local b = base_frame()
  if not b then return nil end
  local ok, x, y = pcall(find_button, b, 0, 0, 1, 1, word, 0, base_handler())
  if ok and x then return x / screen_w(), y / screen_h() end
  return nil
end

-- the topmost scrolling page (level selection)
local function find_pager(f, depth)
  if depth > 16 or not live(f) then return nil end
  local ch = f.children
  if type(ch) == 'table' then
    for i = #ch, 1, -1 do
      local p = find_pager(ch[i], depth + 1)
      if p then return p end
    end
  end
  if type(f.scroll) == 'table' and type(f.next) == 'function' and type(f.previous) == 'function' then
    return f
  end
  return nil
end

-- --------------------------------------------------------------- camera
local function camera_data()
  local g = (type(gamelua) == 'table' and gamelua) or _G
  local objs = objects or g.objects
  if type(objs) ~= 'table' then return nil end
  local b, c = objs.birdCameraData, objs.castleCameraData
  if type(b) ~= 'table' or type(c) ~= 'table' then return nil end
  local dm = deviceModel or g.deviceModel or 'android'
  b, c = b[dm] or b['android'] or b['osx'] or b['windows'], c[dm] or c['android'] or c['osx'] or c['windows']
  if type(b) ~= 'table' or type(c) ~= 'table' then return nil end
  return b, c
end

-- The right stick moves the camera the way a finger does (DefaultMode's
-- handleInputLogic): cameraAnimationSlider runs from the slingshot's camera
-- (0) to the target's (1), a drag moves it by the drag's pixels over the
-- distance between them, clears the camera's target (unless a bird is
-- flying) and holds isSwipingCamera so the view follows at once. Let go, a
-- finger's camera slides back to the nearer end; the stick's stays where it
-- was put (isSwipingCamera held each update) until the game takes the camera
-- (a bird to follow) or a bird is picked up. Zoom: currentZoomedScale,
local cam_panning = false
local last_cam_log = 0

local function camera(px, py, z)
  local g = (type(gamelua) == 'table' and gamelua) or _G
  local gc = gameCamera or g.gameCamera
  
  if type(gc) == 'table' and not g.dumped_gc then
    g.dumped_gc = true
    for k, v in pairs(gc) do
      print("[camera_dump] " .. tostring(k) .. " = " .. type(v))
    end
  end

  if type(gc) ~= 'table' then return end

  -- If any camera movement is requested, detach from the bird
  if px ~= 0 or py ~= 0 or math.abs(z) > 0.2 then
    local tgt = gc.cameraTargetObjects
    if type(tgt) == 'table' then
      -- Safely empty the array without replacing the C++ bound table object
      while #tgt > 0 do table.remove(tgt) end
    end
  end

  if px ~= 0 or py ~= 0 then
    local sl = num(gc.cameraAnimationSlider) or 0
    sl = sl + px * 0.012
    sl = math.max(0, math.min(1, sl))
    
    gc.cameraAnimationSlider = sl
    if gc.cameraAnimationSliderTarget ~= nil then
      gc.cameraAnimationSliderTarget = sl
    end
    gc.velocity = 0
    
    if type(g.doItAllCamera) == 'function' then
      gc.currentCameraFunction = g.doItAllCamera
    end
  end

  -- Deadzone for zoom to prevent accidental zooming when panning
  if math.abs(z) > 0.2 then
    if type(gc.setZoomScale) == 'function' then
      local cz = num(gc.currentZoomedScale) or 1.0
      
      -- z < 0 is UP on the joystick. We want UP to zoom IN (acercar), so factor < 1.0.
      -- z > 0 is DOWN on the joystick. We want DOWN to zoom OUT (alejar), so factor > 1.0.
      local factor = 1.0 + z * 0.015
      local new_cz = cz * factor
      
      -- Clamp the zoom scale safely between reasonable bounds
      new_cz = math.max(0.01, math.min(10.0, new_cz))
      
      -- Remove screen coordinate overrides, let the engine zoom around current center
      pcall(gc.setZoomScale, gc, new_cz)
    end
  end
end


-- ------------------------------------------------------ free purchases
-- The store is long gone and the port is offline, so every purchase is
-- granted the way the store's answer would grant it. In Angry Birds Star
-- Wars II, characters and bundles cost Bird Coins or IAP. SettingsWrapper
-- tracks coin balances, unlocked episodes, and unlocked unlimited
-- characters. iap.lua handles coin purchases via native_buyItem and
-- addCoins. Here we grant 999999 coins, unlock unlimited characters and
-- episodes, and fulfill every IAP immediately as FREE.
local pending_buys = {}

local function free_purchases()
  -- Star Wars II SettingsWrapper hooks
  if type(SettingsWrapper) == 'table' and not SettingsWrapper.__abs_hooked then
    SettingsWrapper.__abs_hooked = true

    local orig_getAmount = SettingsWrapper.getAmount
    SettingsWrapper.getAmount = function(self, id)
      if id == 'coins' then
        local v = orig_getAmount and orig_getAmount(self, id)
        return math.max(v or 0, 999999)
      end
      if type(id) == 'string' and sfind(id, '_unlimited') then
        return 1
      end
      local v = orig_getAmount and orig_getAmount(self, id)
      return math.max(v or 0, 99)
    end

    if type(SettingsWrapper.isEpisodePurchased) == 'function' then
      SettingsWrapper.isEpisodePurchased = function() return true end
    end
    if type(SettingsWrapper.getPurchase) == 'function' then
      SettingsWrapper.getPurchase = function() return true end
    end
    if type(SettingsWrapper.isPayingCustomer) == 'function' then
      SettingsWrapper.isPayingCustomer = function() return true end
    end
    if type(SettingsWrapper.isAdsRemoved) == 'function' then
      SettingsWrapper.isAdsRemoved = function() return true end
    end
    if type(SettingsWrapper.isDarkSideOpen) == 'function' then
      SettingsWrapper.isDarkSideOpen = function() return true end
    end
    if type(SettingsWrapper.isOppositeSideCharactersEnabled) == 'function' then
      SettingsWrapper.isOppositeSideCharactersEnabled = function() return true end
    end
  end

  -- Star Wars II iap table hooks
  if type(iap) == 'table' and not iap.__abs_hooked then
    iap.__abs_hooked = true
    iap.native_isInitialized = function() return true end
    iap.native_isIapAllowed = function() return true end

    local catalog = {
      { id = 'coins_1', price = 'FREE', clientData = { coins = 1000 } },
      { id = 'coins_2', price = 'FREE', clientData = { coins = 2500 } },
      { id = 'coins_3', price = 'FREE', clientData = { coins = 6000 } },
      { id = 'coins_4', price = 'FREE', clientData = { coins = 15000 } },
      { id = 'coins_5', price = 'FREE', clientData = { coins = 40000 } },
      { id = 'coins_6', price = 'FREE', clientData = { coins = 100000 } },
    }
    iap.native_catalog = function() return catalog end

    iap.native_buyItem = function(id)
      pending_buys[#pending_buys + 1] = id
    end
    if type(iap.buyProduct) == 'function' then
      iap.buyProduct = function(id)
        pending_buys[#pending_buys + 1] = id
      end
    end
    if type(iap.getPrice) == 'function' then
      iap.getPrice = function() return 'FREE' end
    end
  end

  -- Hook global purchaseCoins
  if type(purchaseCoins) == 'function' and not purchaseCoins.__abs_hooked then
    local orig_purchaseCoins = purchaseCoins
    purchaseCoins = function(id)
      pending_buys[#pending_buys + 1] = id
    end
    purchaseCoins.__abs_hooked = true
  end

  -- Ensure coins balance is topped up via iap.addCoins
  if type(iap) == 'table' and type(iap.addCoins) == 'function' then
    local cur = 0
    if type(SettingsWrapper) == 'table' and type(SettingsWrapper.getAmount) == 'function' then
      pcall(function() cur = SettingsWrapper:getAmount('coins') or 0 end)
    end
    if cur < 999999 then
      pcall(iap.addCoins, 999999 - cur)
    end
  end

  -- Unlock episodes & game purchases
  if type(g_gamePurchasesTable) == 'table' and type(g_gamePurchasesTable.root) == 'table' and not g_gamePurchasesTable.__abs_free then
    g_gamePurchasesTable.__abs_free = true
    setmetatable(g_gamePurchasesTable.root, {
      __index = function(t, k) return true end
    })
  end
  if type(g_episodePurchasesTable) == 'table' and type(g_episodePurchasesTable.root) == 'table' and not g_episodePurchasesTable.__abs_free then
    g_episodePurchasesTable.__abs_free = true
    setmetatable(g_episodePurchasesTable.root, {
      __index = function(t, k) return true end
    })
  end

  -- Settings flags
  if type(settings) == 'table' and type(settings.root) == 'table' then
    settings.root.adsRemoved = true
    settings.root.isPayingCustomer = true
    settings.root.androidPremium = true
    settings.root.oppositeSideCharactersEnabledForDarkSide = true
    settings.root.oppositeSideCharactersEnabledForLightSide = true
  end

  -- Unlock all characters with unlimited uses
  if type(Characters) == 'table' and type(Characters.list) == 'table' and type(SettingsWrapper) == 'table' and not Characters.__abs_unlocked then
    Characters.__abs_unlocked = true
    for charName, _ in pairs(Characters.list) do
      if type(charName) == 'string' then
        if type(SettingsWrapper.addAmount) == 'function' then
          pcall(SettingsWrapper.addAmount, SettingsWrapper, charName .. '_unlimited', 1)
          pcall(SettingsWrapper.addAmount, SettingsWrapper, charName, 99)
        end
        if type(SettingsWrapper.setPurchase) == 'function' then
          pcall(SettingsWrapper.setPurchase, SettingsWrapper, charName .. '_unlimited')
        end
      end
    end
  end
end

local function grant_pending()
  if #pending_buys == 0 then return end
  local list = pending_buys
  pending_buys = {}
  local CP = type(native) == 'table' and native.CloudPayment
  for _, id in ipairs(list) do
    if type(iap) == 'table' and type(iap.lua_onLocalPurchaseSucceeded) == 'function' then
      pcall(iap.lua_onLocalPurchaseSucceeded, id)
    end
    if type(iap) == 'table' and type(iap.addCoins) == 'function' then
      pcall(iap.addCoins, 50000)
    end
    if CP and type(CP.onProductPurchased) == 'function' then
      pcall(CP.onProductPurchased, id)
    end
    if type(eventManager) == 'table' and type(eventManager.notify) == 'function' then
      local eid = (type(events) == 'table' and events.EID_IAP_PURCHASE_COMPLETED) or 'EID_IAP_PURCHASE_COMPLETED'
      pcall(eventManager.notify, eventManager, { id = eid, productId = id })
      pcall(eventManager.notify, eventManager, { id = (events and events.EID_POP_FRAME) or 'EID_POP_FRAME' })
      pcall(eventManager.notify, eventManager, { id = (events and events.EID_PURCHASE_CALLBACK_RECEIVED) or 'EID_PURCHASE_CALLBACK_RECEIVED' })
      pcall(eventManager.notify, eventManager, { id = (events and events.EID_REFRESH_COIN_AMOUNT) or 'EID_REFRESH_COIN_AMOUNT', change = 'ADD' })
    end
  end
end

-- ------------------------------------------------------------ the links
-- The tiny planets on the episode screen, the Solar System episode's
-- planets, the Pluto popup's "Learn more", the main menu's Toons and a few
-- others call url.prompt(id): "leave the game?", then a web page (NASA's, the
-- Rocket Science Show's episodes...). There is no browser here and the pages
-- are gone, so instead a popup of the game's own kind opens -- the New
-- Horizons popup's pieces (the missions panel with its title tab, the green
-- button, the X) -- with the topic's picture from the game, a few lines about
-- it (the port's own words) and a "Watch video" button: the video the link
-- went to, streamed from YouTube when the console is online (abs_video.c), or
-- videos/<topic>.mp4 from the SD card. The video plays inside the popup: the
-- script reports the rectangle, abs_video.c draws into it, and the states
-- come back (A.frame's vstate) for the spinner and the messages.
-- reqs and request are declared earlier (before flip_page) so they are in scope there too.
local VIDEOS = {}
local ONLINE = false
local VSTATE = 0
local vrect = nil -- the popup's video rectangle, screen pixels

function A.set_videos(list)
  VIDEOS = {}
  for w in string.gmatch(tostring(list or ''), '[%w_]+') do VIDEOS[w] = true end
end

-- id = url.lua's name: {video/topic name, tab title, headline, picture,
-- the picture's sprite group, text, YouTube id of the video it went to}
local T = {}
local function topic(id, name, title, sub, icon, group, text, yt)
  T[id] = {id = id, name = name, title = title, sub = sub, icon = icon, group = group, text = text, yt = yt}
end
local EP, RP, EG, SS = 'EPISODESELECTION2', 'REDPLANET_INGAME', 'EGGSTEROID_INGAME', 'SOLAR_SYSTEM_THEME'
local OFFLINE = ' There is no web browser on the Switch to open it in.'

topic('NASA_URL', 'nasa', 'Space Station', 'Angry Birds in orbit', 'NEW_EPSEL_MISC_NASA_ISS', EP,
  'In 2012 astronaut Don Pettit fired a plush Red at a balloon pig aboard the Space Station, to show ' ..
  'how things fly without gravity.', 'PW8et34Uxt8')
topic('ISS_URL', 'iss', 'Space Station', 'A lab in orbit', 'ISS', SS,
  'Built in orbit from 1998, the Space Station circles the Earth 16 times a day. People have lived ' ..
  'aboard it since 2000.', 'UCe-CiIdqTs')
topic('CURIOSITY_URL', 'curiosity', 'Curiosity', 'A rover the size of a car', 'BLOCKS_ROVER_AEROSHIELD_1', RP,
  'NASA\'s Curiosity rover landed on Mars in August 2012, lowered by a rocket-powered sky crane. It is ' ..
  'still exploring today.', 'zxV7-5Utai0')
topic('PHOENIX_URL', 'phoenix', 'Phoenix', 'Ice under the Martian soil', 'BLOCKS_ROVER_PHOENIX_1', EG,
  'Phoenix landed near the north pole of Mars in 2008 and dug up water ice hidden just under the soil.')
topic('VIKING_URL', 'viking', 'Viking', 'The first pictures from Mars', 'BLOCKS_ROVER_VIKING_1', EG,
  'In 1976 the two Viking landers sent back the first colour pictures from the surface of Mars.')
topic('PATHFINDER_URL', 'pathfinder', 'Pathfinder', 'The first wheels on Mars', 'BLOCKS_ROVER_PATHFINDER_1', EG,
  'In 1997 Pathfinder bounced down on airbags and let out Sojourner, the first rover on another planet.')
topic('SPIRIT_URL', 'spirit', 'Spirit', 'Built for 90 days', 'BLOCKS_ROVER_SPIRIT_1', EG,
  'Spirit landed on Mars in 2004 for a 90-day mission and kept exploring for six years.')
topic('OPPORTUNITY_URL', 'opportunity', 'Opportunity', 'A marathon on Mars', 'BLOCKS_ROVER_SPIRIT_1', EG,
  'Also built for 90 days, Opportunity drove on for 14 years and 45 km, longer than a marathon.')
topic('BUZZ_APOLLO_URL', 'buzz', 'Apollo 11', 'Buzz Aldrin on the Moon', 'NEW_EPSEL_MISC_NASA_APOLLO', EP,
  'In 1969 Buzz Aldrin became the second person to walk on the Moon. In 2014 he became the Mighty ' ..
  'Buzzard of Beak Impact.')
topic('EUROPA_URL', 'europamoon', 'Europa', 'An ocean under the ice', 'NEW_EPSEL_EUROPA', EP,
  'Jupiter\'s moon Europa may hide an ocean under its ice, with more water than all of Earth\'s.',
  'cjyQZsQG3WY')
topic('NEW_HORIZON_URL', 'newhorizons', 'New Horizons', 'The first close look at Pluto', 'NEW_HORIZONS', 'MENU',
  'After nine years in space, New Horizons flew past Pluto in July 2015 and sent back its first ' ..
  'close-up pictures.', 'k2cRBVgY-ns')
topic('DEEPIMPACT_URL', 'deepimpact', 'Deep Impact', 'A crash on purpose', nil, nil,
  'In 2005 Deep Impact crashed a probe into a comet on purpose, to see what lay under its crust.')
topic('DAWN_URL', 'dawn', 'Dawn', 'Two worlds in one trip', 'BLOCK_MINER_NASAGEAR3', EG,
  'On gentle ion engines, Dawn orbited the giant asteroid Vesta and then the dwarf planet Ceres.')
topic('OSIRISREX_URL', 'osirisrex', 'OSIRIS-REx', 'A handful of an asteroid', 'BLOCK_MINER_NASAGEAR5', EG,
  'OSIRIS-REx grabbed rocks from the asteroid Bennu in 2020 and brought them back to Earth in 2023.')
topic('ORION_URL', 'orion', 'Orion', 'Back to the Moon', 'BLOCK_MINER_NASAGEAR4', EG,
  'Orion is NASA\'s capsule for taking astronauts back to the Moon. It flew around it without a crew in ' ..
  '2022.')
topic('MERCURY_URL', 'mercury', 'Mercury', 'Closest to the Sun', 'MERCURY', SS,
  'The smallest planet, and the fastest: a year there lasts just 88 days.', 'CL15siZ2pv4')
topic('VENUS_URL', 'venus', 'Venus', 'The hottest planet', 'VENUS', SS,
  'Hot enough to melt lead under its thick clouds. It spins backwards, so the Sun rises in the west.',
  'fKq9BuS8crE')
topic('EARTH_URL', 'earth', 'Earth', 'Home', 'EARTH', SS,
  'The only world known to have life. Water covers about 71 percent of it.', 'Ue2l2Y0CbBs')
topic('MOON_URL', 'moon', 'The Moon', 'Twelve people walked here', 'MOON', SS,
  'Twelve people walked on the Moon between 1969 and 1972. With no wind, their footprints are still ' ..
  'there.', '4B9tHF-bj14')
topic('MARS_URL', 'mars', 'Mars', 'The red planet', 'MARS', SS,
  'Rusty dust makes it red. It has Olympus Mons, the tallest volcano in the solar system.', 'WS1Wou3CG9c')
topic('ASTEROID_URL', 'asteroid_belt', 'Asteroid Belt', 'Leftovers of the planets', 'BLOCK_MINER_ASTEROID_ROCK3', 'BEAKIMPACT_INGAME',
  'Millions of rocks circle the Sun between Mars and Jupiter. Together they weigh less than our Moon.',
  'opqzhGapRuM')
topic('JUPITER_URL', 'jupiter', 'Jupiter', 'The biggest planet', 'JUPITER', SS,
  'All the other planets would fit inside it. Its Great Red Spot is a storm bigger than Earth.',
  'zCmOjtxVTI8')
topic('SOLARSYSTEM_EUROPA_URL', 'europa', 'Europa', 'An ocean under the ice', 'EUROPA', SS,
  'Jupiter\'s icy moon may hide a salty ocean with more water than all of Earth\'s.', 'cjyQZsQG3WY')
topic('SATURN_URL', 'saturn', 'Saturn', 'The ringed planet', 'SATURN', SS,
  'Its rings are made of ice and rock. Saturn is so light for its size that it would float in water.',
  '8FEx4xEDGl0')
topic('URANUS_URL', 'uranus', 'Uranus', 'A planet on its side', 'URANUS', SS,
  'Tipped on its side, it gives each pole 42 years of daylight and then 42 years of night.', 'HPpb9PwSq1U')
topic('NEPTUNE_URL', 'neptune', 'Neptune', 'Found with mathematics', 'NEPTUNE', SS,
  'The farthest planet, found by calculation in 1846. Its winds blow at over 2,000 km an hour.',
  'f42LHE98_6E')
topic('PLUTO_URL', 'pluto', 'Pluto', 'A dwarf planet with a heart', 'PLUTO', SS,
  'A dwarf planet since 2006, with mountains of ice and a giant heart-shaped glacier.', 'auELpHRpYy0')
topic('COMETS_URL', 'comet', 'Comets', 'Dirty snowballs', 'HALLEYS_COMET', SS,
  'Balls of ice and dust. Near the Sun they grow glowing tails millions of km long.', 'XEvUYerv6SI')
topic('MOVIE_URL', 'spacetrailer', 'Trailer', 'Angry Birds Space', 'BTN_VIDEO', 'BUTTONS',
  'The pigs have stolen the eggs again, and this time they took them into space.', 'Zc-XlVLHJDo')
topic('TOONS_URL', 'toons', 'Toons', 'Angry Birds Toons', nil, nil,
  'Short cartoons of the birds and the pigs, from 2013. Each time, an episode picked at random.')
topic('FACEBOOK_URL', 'facebook', 'Facebook', 'Angry Birds on Facebook', 'NEW_EPSEL_SOCIAL_FB', EP,
  'This tiny planet opened Angry Birds\' Facebook page.' .. OFFLINE)
topic('TWITTER_URL', 'twitterfollow', 'Twitter', 'Angry Birds on Twitter', 'NEW_EPSEL_SOCIAL_TWITTER', EP,
  'This tiny planet followed Angry Birds on Twitter.' .. OFFLINE)
topic('AB_FRIENDS_URL', 'friends', 'Friends', 'Angry Birds Friends', 'NEW_EPSEL_MISC_FRIENDS', EP,
  'Angry Birds with weekly tournaments against your friends, on the same levels.', 'xa8cambPkPw')
topic('STARWARS2_URL', 'starwars2', 'Star Wars II', 'Angry Birds Star Wars II', 'NEW_EPSEL_MISC_STARWARS', EP,
  'The 2013 sequel, where for the first time you could also play as the pigs.', 'xAr2oEdegKs')
topic('KELLOGGSPROMO_URL', 'kelloggspromo', 'Froot Loops', 'Froot Loops Bloopers', 'BIRD_SPACE_MIGHTY_SAM', nil,
  'Toucan Sam joined the birds in space for Kellogg\'s, with five levels of his own.', 'SA1yFtr0xi8')

-- Angry Birds Toons, season 1 (the playlist
-- PLTR8zrKWyBqhUo1tSSJVXJG6OH_y_FAuL without its three compilations):
-- {YouTube id, episode, title}; the Toons popup picks one each time it opens
local TOONS = {
  {'qsATpni7B9s', 1, 'Chuck Time'},
  {'a0tSVDjQbz0', 2, 'Where\'s My Crown?'},
  {'4ES2y7bxENE', 3, 'Full Metal Chuck'},
  {'j32-UnN6m5E', 4, 'Another Birthday'},
  {'86EkHcJsXhU', 5, 'Egg Sounds'},
  {'P3Ca0X-TO1U', 6, 'Pig Talent'},
  {'UjnyCsweHOE', 7, 'Gordon Bleugh!'},
  {'G2ApsOSMX2s', 8, 'True Blue?'},
  {'3Hssx5jy-f4', 9, 'Do As I Say!'},
  {'sRih4d0Um9U', 10, 'Off Duty'},
  {'lI-u0pJ-XEM', 11, 'Slingshot 101'},
  {'tv9UIy0RCus', 12, 'Thunder-Chuck'},
  {'wGKi7YITv84', 13, 'Gardening with Terence'},
  {'FQ0ZvlLi3Aw', 14, 'Dopeys On A Rope'},
  {'hlm9JW6hzu4', 15, 'Trojan Egg'},
  {'W61OP5HPSU4', 16, 'Double Take'},
  {'PqS4Ckf01XI', 17, 'Crash Test Piggies'},
  {'BjiWP6GdaZs', 18, 'Slappy-Go-Lucky'},
  {'7D6W6Dzsinw', 19, 'Sneezy Does it'},
  {'LWW9kyDhSGY', 20, 'Run Chuck Run'},
  {'VR6G2-BXk50', 21, 'Hypno Pigs'},
  {'I5XjMXFuAEg', 22, 'Eggs\' Day Out'},
  {'s60XUkdNoNc', 23, 'Gatecrasher'},
  {'PjfvbA3yaB4', 24, 'Hog Roast'},
  {'8M1fDbBTeuc', 25, 'The Bird that Cried Pig'},
  {'OMtsPjcvOyA', 26, 'Hamshank Redemption'},
  {'1n1_ocOUx4M', 27, 'Green Pig Soup'},
  {'8Yy_xnQTS9k', 28, 'Catch Of the Day'},
  {'Cc4_lDIhhK4', 29, 'Nighty Night Terence'},
  {'aTYAwNeP7hw', 30, 'Piggywig'},
  {'dTUrgFaXR2o', 31, 'Pig Plot Potion'},
  {'gbbShQTfU-I', 32, 'Tooth Royal'},
  {'O95AUbsOPQs', 33, 'Night of the Living Pork'},
  {'IPQmfvcvOWI', 34, 'King of the Castle'},
  {'_0xV99AhWWU', 35, 'Love is in the Air'},
  {'RtrP62DYpEY', 36, 'Fired Up'},
  {'sHbstdJ9goc', 37, 'Clash of Corns'},
  {'ZHyazVpn0DA', 38, 'A Pig\'s Best Friend'},
  {'Ea3k76ncg2s', 39, 'Slumber Mill'},
  {'web9BrIhRMQ', 40, 'Jingle Yells'},
  {'tHjjbHkFqVw', 41, 'El Porkador!'},
  {'gMg5KHmBhzQ', 42, 'Hiccups'},
  {'K7xjAoBl-iE', 43, 'The Butterfly Effect'},
  {'k2TLF_RNAq8', 44, 'Hambo'},
  {'FJw4gfKxah8', 45, 'Bird Flu'},
  {'e5kQAMPbM-A', 46, 'Piggies From the Deep'},
  {'qTOAtWKwUuI', 47, 'Oh Gnome!'},
  {'b1NjziX6Kq0', 48, 'Shrub It In'},
  {'zzx0HcuuWTk', 49, 'The Truce'},
  {'aT9mjfds2G8', 50, 'Operation Opera'},
  {'yF9bcYlAra0', 51, 'Chucked Out'},
  {'pJeOcwYtf3U', 52, 'Bomb\'s Awake'}
}
local seeded = false
local function pick_toon(t)
  if not seeded then
    seeded = true
    math.randomseed(math.floor((num(time) or 0) * 1000) + frame_no)
  end
  local e = TOONS[math.random(#TOONS)]
  t.yt = e[1]
  t.sub = sfmt('Episode %d: %s', e[2], e[3])
end
T.STARWARS2_URL_PREMIUM = T.STARWARS2_URL

local function generic(id)
  return {id = id, name = slower(tostring(id):gsub('_URL$', '')), title = 'Link', sub = 'A web page',
          text = 'This opened a web page.' .. OFFLINE}
end

local function can_play(t)
  return VIDEOS[t.name] or (ONLINE and t.yt ~= nil)
end

-- the popup, a class of the game's (lua.Class over ui.Frame), made the first
-- time it is needed
local Popup
local function sprite_ok(name)
  if type(res) ~= 'table' or type(res.getSpriteBounds) ~= 'function' then return false end
  local ok, w, h = pcall(res.getSpriteBounds, name)
  return ok and num(w) and num(h) and w > 0 and h > 0
end

local function show(f, on)
  if type(f) == 'table' then f.visible = on end
end

local STATUS = {
  [1] = 'Connecting to YouTube...', [2] = 'Loading the video...',
  [61] = 'The console is not connected to the internet.',
  [62] = 'YouTube did not give the video.',
  [63] = 'The video stopped downloading. Check the internet connection.',
  [64] = 'This video cannot be played here.',
}

local function popup_class()
  if Popup then return Popup end
  if type(lua) ~= 'table' or type(lua.Class) ~= 'table' or type(ui) ~= 'table' or
     type(ui.Frame) ~= 'table' or type(ui.Text) ~= 'table' or type(ui.ScalableButton) ~= 'table' then
    return nil
  end
  local P = lua.Class.create(ui.Frame)
  function P:init(t)
    ui.Frame.init(self, 'absInfoPopup')
    self.topic = t
    self.appear = 0
    if t.group and t.group ~= 'MENU' and t.group ~= 'BUTTONS' then
      self:requireGroup('MISSIONS', 'MENU', 'BUTTONS', t.group)
    else
      self:requireGroup('MISSIONS', 'MENU', 'BUTTONS')
    end
  end
  -- the pieces are made once the groups are loaded (Frame.onEntry)
  function P:onEntry()
    ui.Frame.onEntry(self)
    local t = self.topic
    local bg = ui.Image:new('background')
    bg:setImage('MISSIONS_UI_MAIN_BG')
    self:addChild(bg)
    self:addChild(ui.Text:new('title', t.title))
    self:addChild(ui.Text:new('subtitle', t.sub))
    if t.icon and sprite_ok(t.icon) then
      -- the topic's picture from the game, on the glow the game's branded popups use
      if sprite_ok('MINER_BRANDED_POPUP_GLOW') then
        local glow = ui.Image:new('glow')
        glow:setImage('MINER_BRANDED_POPUP_GLOW')
        self:addChild(glow)
      end
      local icon = ui.Image:new('icon')
      icon:setImage(t.icon)
      self:addChild(icon)
    end
    self:addChild(ui.Text:new('body', t.text, nil, nil, 'HCENTER', 'VCENTER'))
    if can_play(t) then
      local b = ui.ScalableButton:new('watchVideo')
      b:setImage('MINER_UNLOCK_POPUP_BUTTON')
      b.returnValue = 'WATCH_VIDEO'
      self:addChild(b)
      b:addChild(ui.Text:new('watchText', 'Watch video'))
    elseif t.yt then
      self:addChild(ui.Text:new('hint', 'Connect the console to the internet to watch the video here', nil,
                                getFontSmall))
    end
    -- the video's place: the game's spinner and a line while it loads
    if type(ui.Spinner) == 'table' then
      local sp = ui.Spinner:new('spinner', math.pi * 2)
      sp:setImage('IN_APP_LOADING')
      sp.visible = false
      self:addChild(sp)
    end
    local st = ui.Text:new('status', ' ', nil, nil, 'HCENTER', 'VCENTER')
    st.visible = false
    self:addChild(st)
    local keys = ui.Text:new('keys', 'A pause    B stop    Left stick: 10 s back / on', nil, getFontSmall)
    keys.visible = false
    self:addChild(keys)
    local x = ui.ScalableButton:new('backButton')
    x:setImage('BTN_X')
    x.returnValue = 'GO_BACK'
    x.clickSound = 'ButtonBack'
    self:addChild(x)
    if type(disableGameUpdate) == 'function' then disableGameUpdate() end
    self:layout()
  end
  -- as PlutoVotePopup.layout: the background's half sizes at world scale
  function P:layout()
    ui.Frame.layout(self)
    local bg = self:getChild('background')
    if not bg or not num(bg.w) or not num(bg.h) then return end
    -- a little smaller with its few lines, the full panel for the video
    local ws = ReferenceScaler.getWorldScale(false) * (self.vmode and 1 or 0.86)
    local hh, hw = bg.h / 2 * ws, bg.w / 2 * ws
    self.hh, self.hw = hh, hw
    self.x, self.y = screenWidth / 2, screenHeight / 2
    self.hanchor, self.vanchor = 'HCENTER', 'VCENTER'
    self:setScale(ws)
    local c = self:getChild('title')
    c.x, c.y = 0, -hh * 0.885
    c = self:getChild('subtitle')
    c.x, c.y = 0, -hh * 0.66
    local icon = self:getChild('icon')
    local top = -hh * 0.55 -- under the headline
    if icon and num(icon.w) and num(icon.h) and icon.w > 0 and icon.h > 0 then
      local k = math.min(bg.h * 0.3 / icon.h, bg.w * 0.55 / icon.w, 1.5)
      icon:setScale(k)
      icon.x, icon.y = 0, top + icon.h * k * ws * 0.5 + hh * 0.04
      local glow = self:getChild('glow')
      if glow and num(glow.h) and glow.h > 0 then
        glow:setScale(icon.h * k * 1.7 / glow.h)
        glow.x, glow.y = icon.x, icon.y
      end
      top = icon.y + icon.h * k * ws * 0.5
    end
    c = self:getChild('body')
    c:setMaxWidth(bg.w * 0.84)
    local bottom = hh * (self:getChild('watchVideo') and 0.84 or self:getChild('hint') and 0.78 or 0.9)
    c.x, c.y = 0, (top + bottom) * 0.5
    c = self:getChild('watchVideo')
    if c then
      c.x, c.y = hw * 0.7, hh
      c:setScale(0.8)
      local tx = c:getChild('watchText')
      if tx then tx:setScale(1.25) end
    end
    c = self:getChild('hint')
    if c then
      c:setMaxWidth(bg.w * 0.95)
      c.x, c.y = 0, hh * 0.86
    end
    -- the video: 16:9 across the panel, under the headline
    local vw = hw * 1.76
    local vh = vw * 9 / 16
    local vy = -hh * 0.56
    self.vbox = {-vw / 2, vy, vw, vh}
    c = self:getChild('spinner')
    if c then c.x, c.y = 0, vy + vh * 0.45 end
    c = self:getChild('status')
    if c then
      c:setMaxWidth(bg.w * 0.8)
      c.x, c.y = 0, vy + vh * 0.72
    end
    c = self:getChild('keys')
    if c then
      c:setMaxWidth(bg.w * 0.9)
      c.x, c.y = 0, (vy + vh + hh) * 0.5
    end
    c = self:getChild('backButton')
    c.x, c.y = hw * 0.95, -hh * 0.85
  end
  -- the video mode: the picture, the text and the button give their place
  function P:video(on)
    self.vmode = on
    self.vseen = false
    for _, n in ipairs({'icon', 'glow', 'body', 'watchVideo', 'hint'}) do show(self:getChild(n), not on) end
    show(self:getChild('spinner'), on)
    show(self:getChild('status'), false)
    show(self:getChild('keys'), false)
    self:layout()
  end
  function P:update(dt, ...)
    self.appear = math.min((self.appear or 0) + (num(dt) or 0) * 2, 0.7)
    if self.vmode then
      local s = VSTATE
      if s ~= 0 then self.vseen = true end
      local st, sp = self:getChild('status'), self:getChild('spinner')
      if (s == 0 and self.vseen) or s == 5 then
        -- played to the end, or stopped: the page again
        self:video(false)
        request('vstop')
      else
        local msg = STATUS[s]
        show(sp, s <= 2)
        show(self:getChild('keys'), s == 3 or s == 4)
        if msg and st then
          if st.shown_msg ~= msg and type(st.setText) == 'function' then
            st:setText(msg)
            st.shown_msg = msg
          end
          show(st, true)
        else
          show(st, false)
        end
      end
    end
    return ui.Frame.update(self, dt, ...)
  end
  -- the game's popups darken what is behind them (ConfirmPrompt.draw)
  function P:draw(...)
    if type(drawRect) == 'function' then
      drawRect(0, 0, 0, self.appear or 0, 0, 0, screenWidth, screenHeight, false)
    end
    return ui.Frame.draw(self, ...)
  end
  function P:close()
    if self.vmode then request('vstop') end
    request('closed')
    self:removeSelf()
  end
  function P:back()
    if self.vmode then
      self:video(false)
      request('vstop')
    else
      self:close()
    end
  end
  function P:onPointerEvent(ev, x, y, ...)
    local r = ui.Frame.onPointerEvent(self, ev, x, y, ...)
    if r == 'GO_BACK' then
      self:back()
    elseif r == 'WATCH_VIDEO' and not self.vmode then
      local t = self.topic
      self:video(true)
      request('play:' .. t.name .. ':' .. ((not VIDEOS[t.name] and t.yt) or '-'))
    end
    return 'BLOCK', nil, self
  end
  function P:onKeyEvent(ev, key, ...)
    ui.Frame.onKeyEvent(self, ev, key, ...)
    if ev == 'PRESS' and (key == 'KEY_BACK' or key == 'ESCAPE') then self:back() end
    return 'BLOCK', nil, self
  end
  function P:onExit()
    if not call(isPausePageVisible) and type(enableGameUpdate) == 'function' then enableGameUpdate() end
    return ui.Frame.onExit(self)
  end
  Popup = P
  return P
end

local function open_popup(id)
  local P = popup_class()
  local mm = menu_manager()
  local nf = mm and call(mm.notificationsFrame, mm)
  if not P or type(nf) ~= 'table' then return false end
  local old = call(nf.getChild, nf, 'absInfoPopup')
  if type(old) == 'table' then pcall(old.removeSelf, old) end
  if id == 'TOONS_URL' and T.TOONS_URL then pick_toon(T.TOONS_URL) end
  local pop = P:new(T[id] or generic(id))
  local ok, e = pcall(nf.addChild, nf, pop)
  if not ok then
    -- half made: it goes again, and the port's page is shown instead
    if call(nf.getChild, nf, 'absInfoPopup') == pop then pcall(pop.removeSelf, pop) end
    error(e, 0)
  end
  return true
end

local function show_link(id)
  id = tostring(id)
  local ok, r = pcall(open_popup, id)
  if not (ok and r) then
    -- the game's popup could not be made: the port's own page
    request('page:' .. id)
    if not ok then A.last_error = tostring(r) end
  end
end

local function hook_links()
  if type(url) ~= 'table' or url.__abs_info then return end
  url.__abs_info = true
  url.prompt = show_link
  url.open = show_link
end

-- the popup's video rectangle on screen, while it is in video mode
local function popup_vrect()
  local mm = menu_manager()
  local nf = mm and call(mm.notificationsFrame, mm)
  local pop = type(nf) == 'table' and call(nf.getChild, nf, 'absInfoPopup')
  if type(pop) ~= 'table' or not pop.vmode or type(pop.vbox) ~= 'table' then return nil end
  local b = pop.vbox
  return (num(pop.x) or 0) + b[1], (num(pop.y) or 0) + b[2], b[3], b[4]
end

-- the texture budget: Assets.lua gives Android 60 MB (PCs 100); the console
-- has the room for all of it
local mem_set, mem_frame = 0, 0
local function memory(limit)
  if limit <= 0 then return end
  if mem_set ~= limit or frame_no - mem_frame > 600 then
    local RM = type(native) == 'table' and native.ResourceManager
    if RM and type(RM.setMemoryLimit) == 'function' and pcall(RM.setMemoryLimit, limit) then
      mem_set, mem_frame = limit, frame_no
    end
  end
end

-- a popup in notificationsFrame that takes the touches (over a level too)
popup_open = function()
  local mm = menu_manager()
  local nf = mm and call(mm.notificationsFrame, mm)
  if type(nf) ~= 'table' or type(nf.children) ~= 'table' then return false end
  local base = base_handler()
  for _, c in ipairs(nf.children) do
    if live(c) and (covers(c) or modal(c, base)) then return true end
  end
  return false
end

-- A level is being played only while its scene is the page on top: the
-- shop, opened from a level (the power-ups bar's button, the Space Eagle's
-- when there are none left: Shop.loginAndEnter), takes the level's place and
local function level_on_top()
  local in_mm = g_inMainMenu
  if in_mm == nil and type(gamelua) == 'table' then in_mm = gamelua.g_inMainMenu end
  local cbn = currentBirdName
  if cbn == nil and type(gamelua) == 'table' then cbn = gamelua.currentBirdName end
  local timer = g_levelTimer
  if timer == nil and type(gamelua) == 'table' then timer = gamelua.g_levelTimer end

  -- If g_inMainMenu is explicitly true, we are in the main menu: never treat as in-level
  if in_mm == true then return false end

  if in_mm == false and cbn ~= nil then return true end
  -- g_levelTimer is always a number in ABSW2 even on the main menu, so guard:
  -- only treat it as a level-active signal when g_inMainMenu is not true and timer > 0
  if in_mm ~= true and type(timer) == 'number' and timer > 0 then return true end

  local mm = menu_manager()
  local root = base_frame()
  if not root then return false end
  local hud = call(root.getChild, root, 'gameHud')
  -- gameHud exists in ABSW2 but may not be truly active in menus; only trust it when
  -- g_inMainMenu is not true
  if in_mm ~= true and hud and hud.visible ~= false then return true end
  return false
end

-- ---------------------------------------------------------------- frame
-- B in the main menu: MainMenu.onKeyEvent turns KEY_BACK (a popup on it
-- answering first) into "quit the game?". Here it closes the tab that is out
-- instead -- the one the focused button is in, or whichever is open -- the
-- way the tab's own button does (MainMenu's TOGGLE_OPTIONS and
-- TOGGLE_RIGHT_OPTIONS), and never asks to quit.
local function close_tabs(page)
  local it = focus_id and seen[focus_id]
  local g = it and it.grp or 0
  local function open(name)
    local t = call(page.getChild, page, name)
    return type(t) == 'table' and (t.state == 'OPEN' or t.state == 'OPENING') and t
  end
  local function close(slider, button, image, right)
    local t = open(slider)
    if not t then return false end
    pcall(t.toggle, t)
    local b = call(page.getChild, page, button)
    local im = type(b) == 'table' and call(b.getChild, b, image)
    if type(im) == 'table' and type(im.toggle) == 'function' then pcall(im.toggle, im) end
    if right then
      local n = call(page.getChild, page, 'ingameNative')
      if type(n) == 'table' then n.visible = not n.visible end
    end
    return true
  end
  local L = function() return close('optionsSlider', 'optionsButton', 'optionsImage', false) end
  local R = function() return close('rightSlider', 'rightSliderButton', 'rightSliderImage', true) end
  local done
  if g == 2 or g == 3 then done = L() elseif g == 4 or g == 5 then done = R() end
  if not done then
    local a, b = L(), R()
    done = a or b
  end
  if done then call(playAudio, 'ButtonBack') end
end

local function hook_main_menu()
  local MM = type(menu) == 'table' and rawget(menu, 'MainMenu')
  if type(MM) ~= 'table' or rawget(MM, '__abs_keys') or type(MM.onKeyEvent) ~= 'function' then return end
  local orig = MM.onKeyEvent
  MM.__abs_keys = true
  MM.onKeyEvent = function(self, ev, key, ...)
    if ev == 'PRESS' and (key == 'KEY_BACK' or key == 'ESCAPE') then
      local r = ui.Frame.onKeyEvent(self, ev, key, ...)
      if not r then pcall(close_tabs, self) end
      return r
    end
    return orig(self, ev, key, ...)
  end
end

-- Froot Loops Bloopers (Kellogg's, 2013): its episode is a sign by Brass
-- Hogs that EpisodeSelection shows when SettingsWrapper:isKelloggsAvailable(),
-- the saved answer of Rovio's cloud setting ab_space.kelloggs_available --
-- '1' only where the promotion ran (the US). Until it has an answer, the
-- page asks the cloud with a spinner. With the flag the answer is yes (and
-- the cloud is not asked); nothing is saved, so turning it off hides it again.
local function kellogg_yes() return true end
local kellogg_orig
local function kelloggs(on)
  local sw = SettingsWrapper
  if type(sw) ~= 'table' then return end
  local f = sw.isKelloggsAvailable
  if type(f) ~= 'function' then return end
  if on then
    if f ~= kellogg_yes then
      kellogg_orig = f
      sw.isKelloggsAvailable = kellogg_yes
    end
  elseif f == kellogg_yes and kellogg_orig then
    sw.isKelloggsAvailable = kellogg_orig
  end
end

-- what the flags ask for, kept up each update
-- A page turn under way (flip_page), each update: the slider along its
-- curve (eased out: it starts as fast as the game's sweep and comes to rest
-- on the page), by the game's clock (`time`), or by the updates without it.
-- A finger that takes the camera ends it. How far the view went outside the
-- two pages is watched until it rests there, and told in debug.log when it
-- is more than a little.
local page_watch
local function page_turn_update()
  local t = page_turn
  local w = page_watch
  if w then
    local x = type(screen) == 'table' and num(screen.x)
    if x and w.lo then w.worst = math.max(w.worst, w.lo - x, x - w.hi) end
    w.n = w.n + 1
    if w.n > 60 or levelName ~= 'LevelSelection' then
      page_watch = nil
      local span = w.hi and w.hi - w.lo or 0
      if span > 0 and w.worst > span * 0.08 then
        request(sfmt('note:page_%d_to_%d:_the_view_went_%d_past_the_pages_%d_apart', w.src, w.dest,
                     math.floor(w.worst + 0.5), math.floor(span + 0.5)))
      end
    end
  end
  -- While a swipe-based page turn is in progress, block reveal() and wait
  -- for camera_settled(). The swipe was already triggered by request('swipe_right/left').
  if ls_pan_dir ~= nil and levelName == 'LevelSelection' then
    ls_pan_frames = ls_pan_frames + 1
    -- camera_settled() is true BEFORE the camera starts gliding, so it can't
    -- be trusted. Instead: the swipe is over when the on-screen positions of
    -- all items have stopped changing for several consecutive frames.
    local sig = 0
    for _, vit in pairs(seen) do sig = sig + vit.x0 end
    if ls_pan_sig and math.abs(sig - ls_pan_sig) < 1 then
      ls_pan_still = ls_pan_still + 1
    else
      ls_pan_still = 0
    end
    ls_pan_sig = sig
    local pan_done = (ls_pan_frames > 20 and ls_pan_still >= 10) or ls_pan_frames > 180
    if ls_pan_frames % 20 == 0 then
      print(sfmt('[pan] waiting: frames=%d still=%d sig=%.0f', ls_pan_frames, ls_pan_still, sig))
    end
    if pan_done then
      print(sfmt('[pan] done: frames=%d still=%d', ls_pan_frames, ls_pan_still))
      last_flip = frame_no - 400  -- next flip_page is allowed right away
      last_flip_item = nil
      ls_pan_dir = nil
      ls_pan_frames = 0
      ls_pan_sig = nil
      ls_pan_still = 0
      -- Keep the focus if it is on-screen; otherwise move it to the on-screen
      -- item nearest to the screen center.
      local sw2 = screen_w()
      local cur = focus_id and seen[focus_id]
      local cur_cx = cur and (cur.x0 + cur.x1) * 0.5
      if not _G._reveal_target and not (cur_cx and cur_cx >= 0 and cur_cx <= sw2) then
        local best_id, best_d
        for vid, vit in pairs(seen) do
          local vcx = (vit.x0 + vit.x1) * 0.5
          local vcy = (vit.y0 + vit.y1) * 0.5
          if vcx >= 0 and vcx <= sw2 then
            local d = (vcx - sw2 * 0.5) * (vcx - sw2 * 0.5) + (vcy - 360) * (vcy - 360)
            if not best_d or d < best_d then best_id, best_d = vid, d end
          end
        end
        print(sfmt('[pan] focus off-screen (cx=%s) -> redirect best_id=%s', tostring(cur_cx), tostring(best_id)))
        if best_id then focus_id = best_id end
      else
        print(sfmt('[pan] focus kept id=%s cx=%.0f', tostring(focus_id), cur_cx))
      end
    end
  end
  if not t then return end
  local sl = num(cameraAnimationSlider)
  if levelName ~= 'LevelSelection' or num(currentCamera) ~= t.cam or not sl or math.abs(sl - t.last) > 1e-3 or
     math.abs((num(sweepSpeed) or 0) - t.sweep) > 1e-3 then
    page_turn = nil
    if levelName == 'LevelSelection' then request(sfmt('note:page_%d_to_%d:_taken_over', t.src, t.dest)) end
    return
  end
  t.n = t.n + 1
  local k
  local now = num(time)
  if now and t.t0 and now > t.t0 then k = (now - t.t0) / PAGE_SECS else k = t.n / (PAGE_SECS * 60) end
  if k >= 1 then
    cameraAnimationSlider = t.to
    cameraAnimationSliderTarget = t.to
    sweepSpeed = 0
    isSwipingCamera = false
    page_turn = nil
    page_watch = {lo = t.lo, hi = t.hi, worst = t.worst, n = 0, src = t.src, dest = t.dest}
    return
  end
  local x = type(screen) == 'table' and num(screen.x)
  if x and t.lo then t.worst = math.max(t.worst, t.lo - x, x - t.hi) end
  local e = 1 - (1 - k) * (1 - k)
  local v = t.from + (t.to - t.from) * e
  cameraAnimationSlider = v
  cameraAnimationSliderTarget = t.to
  sweepSpeed = t.sweep
  isSwipingCamera = true
  t.last = v
end

local function housekeeping(flags, memlimit)
  pcall(page_turn_update)
  if flags % 4 >= FLAG_FREE then pcall(free_purchases) end
  if flags % 8 >= FLAG_INFO then pcall(hook_links) end
  pcall(hook_main_menu)
  pcall(kelloggs, flags % 32 >= FLAG_KELLOGGS)
  pcall(grant_pending)
  pcall(fold_powerup_bar)
  pcall(hook_eagle_score)
  pcall(dim_pause_page)
  pcall(memory, memlimit or 0)
end

function A.frame(cmd, p, z, flags, memlimit, vstate, focus, py)
  link_gamelua()
  frame_no = frame_no + 1
  -- a command may carry a number (C: cmd + n * 256): a carousel turn's time in ms
  local cmd_arg = 0
  if type(cmd) == 'number' and cmd >= 256 then
    cmd_arg = math.floor(cmd / 256)
    cmd = cmd - cmd_arg * 256
  end



  if cmd == 4 or cmd == 5 then
    if _G._last_page_cmd == cmd and type(_G._page_cmd_timer) == 'number' and _G._page_cmd_timer > 0 then
      cmd = 0
      _G._page_cmd_timer = _G._page_cmd_timer - 1
    else
      _G._last_page_cmd = cmd
      _G._page_cmd_timer = 30
    end
  else
    _G._last_page_cmd = 0
    _G._page_cmd_timer = 0
  end
  flags = flags or 0
  focus_id = focus
  ONLINE = flags % 16 >= FLAG_ONLINE
  VSTATE = vstate or 0
  local mode, ready, bx, by, lx, ly, pullr, aiming, special = MODE_MENU, 0, -1, -1, -1, -1, 0, 0, 0
  local fbx, fby -- the flying bird, where its aimed power's cursor starts
  local tx, ty = -1, -1
  local sw, sh = screen_w(), screen_h()
  local game = 1

  housekeeping(flags, memlimit)

  local mm = menu_manager()
  local root = base_frame()
  local hud = root and call(root.getChild, root, 'gameHud')
  local hud_active = (hud ~= nil and hud.visible ~= false)

  local igp = isInGameplay or (type(gamelua) == 'table' and gamelua.isInGameplay)
  local in_gameplay = false
  if type(igp) == 'function' then
    local ok, r = pcall(igp)
    if ok and r == true then in_gameplay = true end
  end

  local igm = isInGameMode or (type(gamelua) == 'table' and gamelua.isInGameMode)
  local in_gamemode = false
  if type(igm) == 'function' then
    local ok, r = pcall(igm)
    if ok and r == true then in_gamemode = true end
  end

  local in_mm = g_inMainMenu or (type(gamelua) == 'table' and gamelua.g_inMainMenu)
  local objs = objects or (type(gamelua) == 'table' and gamelua.objects)
  local cbn = currentBirdName or (type(gamelua) == 'table' and gamelua.currentBirdName)
  local br = birdReady or (type(gamelua) == 'table' and gamelua.birdReady)
  local fb = flyingBird or (type(gamelua) == 'table' and gamelua.flyingBird)
  local lsp = levelStartPosition or (type(gamelua) == 'table' and gamelua.levelStartPosition)
  local cls = g_currentLevelString or (type(gamelua) == 'table' and gamelua.g_currentLevelString)
  local ln = levelName or (type(gamelua) == 'table' and gamelua.levelName) or cls

  local ingame = false
  -- g_inMainMenu is the most authoritative signal: if it's true, we are in the main menu.
  -- Don't let hud_active / in_gameplay / level_on_top() override it.
  if in_mm ~= true and ((hud_active == true) or (in_gameplay == true) or level_on_top()) then
    ingame = true
  end

  -- debug: show ingame-detection variables once per second
  if captured_env and frame_no % 60 == 0 then
    local timer_v = g_levelTimer or (type(gamelua) == 'table' and gamelua.g_levelTimer)
    local ln_v = levelName or (type(gamelua) == 'table' and gamelua.levelName) or '?'
    print(sfmt('[frame-debug] ingame=%s in_mm=%s hud_active=%s in_gameplay=%s lot=%s timer=%s ln=%s',
               tostring(ingame), tostring(in_mm), tostring(hud_active),
               tostring(in_gameplay), tostring(level_on_top()), tostring(timer_v), tostring(ln_v)))
  end

  if ingame then
    -- Detect episode/world selection screen: levelName matches a selection pattern,
    -- or no bird is present and find_episode_page finds the carousel.
    -- In this case treat the screen as a menu so ZL/ZR carousel spin and A/B work.
    local is_sel_screen = false
    if type(ln) == 'string' then
      is_sel_screen = (ln == 'EpisodeSelection' or ln == 'WorldSelection' or
                       ln == 'LevelSelection' or
                       ln == 'EpisodeSelectionScene' or ln == 'WorldSelectionScene' or
                       sfind(ln, 'pisodeSel', 1, true) or sfind(ln, 'orldSel', 1, true) or
                       sfind(ln, 'evelSel', 1, true) or
                       sfind(ln, 'pisodeScen', 1, true) or
                       sfind(ln, 'Comic', 1, true))
    end
    if not is_sel_screen and cbn == nil then
      -- No bird in slingshot: maybe a world/episode screen. Check for episode page.
      local b_sel = base_frame()
      if b_sel and find_episode_page(b_sel, 0) then
        is_sel_screen = true
      end
    end
    if is_sel_screen then
      ingame = false  -- treat as menu mode so ZL/ZR and focus ring work
    end
  end

  if ingame then
    local pause_child = (hud and call(hud.getChild, hud, 'pausePage'))
    local pause_vis = pause_child and pause_child.visible
    local ippv = isPausePageVisible or (type(gamelua) == 'table' and gamelua.isPausePageVisible) or
                 isPausePageShowing or (type(gamelua) == 'table' and gamelua.isPausePageShowing)
    if pause_vis or call(ippv) then
      mode = MODE_PAUSED
    elseif popup_open() then
      mode = MODE_MENU -- a popup over the level (a link's, a prompt): its buttons
    elseif levelCompleted == true or (type(gamelua) == 'table' and gamelua.levelCompleted == true) or
           call(isLevelEnded or (type(gamelua) == 'table' and gamelua.isLevelEnded)) then
      mode = MODE_ENDED
    else
      local world = (type(objs) == 'table' and objs.world) or world or (type(gamelua) == 'table' and gamelua.world)
      local uses = true
      local lm = (type(objs) == 'table' and objs.levelMode) or levelMode or (type(gamelua) == 'table' and gamelua.levelMode)
      if type(lm) == 'table' and type(lm.usesSlingshot) == 'function' then
        local ok, r = pcall(lm.usesSlingshot, lm)
        if ok then uses = r and true or false end
      end
      local ipi = ignorePlayerInput or (type(gamelua) == 'table' and gamelua.ignorePlayerInput)
      local have = uses and cbn ~= nil and not ipi and
                   type(world) == 'table' and world[cbn] ~= nil
                   
      raw_bx, raw_lx = nil, nil
      
      if type(lsp) == 'table' and num(lsp.x) then
        local x, y = p2s(lsp.x, lsp.y)
        local ex = p2s(lsp.x + MAX_LENGTH, lsp.y)
        if x and ex then
          raw_lx = x / sw
          lx, ly = raw_lx, y / sh
          pullr = math.abs(ex - x) / sw
        end
      end
      if have then
        local bird = world[cbn]
        if type(bird) == 'table' and num(bird.x) then
          local x, y = p2s(bird.x, bird.y)
          if x then 
            raw_bx = x / sw
            bx, by = raw_bx, y / sh 
          end
        end
      end
      
      -- Evaluate visibility BEFORE fallbacks destroy the coordinates
      check_x = (raw_bx ~= nil) and raw_bx or raw_lx
      slingshot_visible = false
      if check_x ~= nil and check_x >= -0.05 and check_x <= 1.05 then
        slingshot_visible = true
      end
      
      -- Determine if we are in intro/panning state based solely on visibility
      intro_st = (not slingshot_visible) and (mode == MODE_AIM or mode == MODE_WAIT)
      if intro_st then ready = 2 end
      
      -- FALLBACK: If bx < 0 (bird coordinates not resolved from world), but slingshot lx, ly is known:
      if bx < 0 and lx >= 0 then
        bx, by = lx, ly
      end
      if lx < 0 then
        lx, ly = 0.24, 0.58
        if bx < 0 then bx, by = lx, ly end
      end
      if pullr <= 0 then pullr = 0.15 end

      local sb = selectedBird or (type(gamelua) == 'table' and gamelua.selectedBird)
      local bsa = birdSpecialtyAvailable or (type(gamelua) == 'table' and gamelua.birdSpecialtyAvailable)
      aiming = (sb ~= nil) and 1 or 0


      special = (fb ~= nil and bsa == true) and 1 or 0

      local bt = blockTable or (type(gamelua) == 'table' and gamelua.blockTable)
      if special == 1 and type(fb) == 'table' and num(fb.x) and type(bt) == 'table' and
         type(bt.blocks) == 'table' then
        local d = bt.blocks[fb.definition]
        if type(d) == 'table' and AIMED_POWERS[d.specialty] then
          special = 2
          local x, y = p2s(fb.x, fb.y)
          if x then fbx, fby = x / sw, y / sh end
        end
      end

      if (br == true or (br == nil and fb == nil and not ipi)) and bx >= 0 and special == 0 then
        mode, ready = MODE_AIM, 1
      elseif fb ~= nil and type(fb) == 'table' then
        mode = MODE_FLIGHT
      else
        mode = MODE_WAIT
      end
      if mode ~= MODE_FLIGHT and aiming == 1 then mode = MODE_AIM end

      -- Level intro: if the slingshot is not visible (ready=2 set above), we log it
      do
        local ge = captured_env or {}
        local lname = tostring(ge.levelName)
        if intro_st ~= g_abs_intro_prev then
          g_abs_intro_prev = intro_st
          print(sfmt('[intro-debug] intro=%s bx=%.2f by=%.2f lvl=%s',
            tostring(intro_st), bx, by, lname))
        end
      end
      if mode == MODE_FLIGHT and fbx then bx, by = fbx, fby end
      pcall(camera, p or 0, py or 0, z or 0)
      if cmd == CMD_SLING or cmd == CMD_CASTLE then
        local pan_fn = updatePCCameraPanningToDirection or (type(gamelua) == 'table' and gamelua.updatePCCameraPanningToDirection)
        if type(pan_fn) == 'function' then
          call(pan_fn, cmd == CMD_CASTLE)
        else
          local gc = gameCamera or (type(gamelua) == 'table' and gamelua.gameCamera)
          if type(gc) == 'table' and type(gc.moveBetweenCameras) == 'function' then
            pcall(gc.moveBetweenCameras, gc, 0.0, cmd == CMD_CASTLE and 1.0 or 0.0)
          end
        end
      end
    end
    if cmd == 15 then
      -- slingshot stretch sound (same call the game makes for a finger pull)
      local pan = playAudioNative or (type(gamelua) == 'table' and gamelua.playAudioNative)
      if type(pan) == 'function' then pcall(pan, 'slingshot_stretched', 1, false, 5) end
    elseif cmd == CMD_PAUSE then
      local tpp = togglePausePage or (type(gamelua) == 'table' and gamelua.togglePausePage) or
                  togglePause or (type(gamelua) == 'table' and gamelua.togglePause)
      call(tpp)
    elseif cmd == CMD_RESTART then
      local r_fn = restartLevel or (type(gamelua) == 'table' and gamelua.restartLevel)
      if type(r_fn) == 'function' then
        call(r_fn)
      else
        local x, y = tap_button('restart')
        if x then tx, ty = x, y end
      end
    elseif cmd == CMD_POWERUPS then
      -- the power-ups bar: open or fold it, as its lightning button does
      local sl = powerup_bar()
      if sl and sl.enabled ~= false then pcall(sl.toggle, sl) end
    elseif cmd == CMD_EAGLE then
      -- the Space Eagle's button (MEButton, 'ME_CLICKED'), whatever its
      -- picture: Mighty Buzz in the Apollo levels, Toucan Sam in Froot Loops
      local x, y = tap_button('me_clicked')
      if not x then x, y = tap_button('eagle') end
      if x then tx, ty = x, y end
    elseif cmd == CMD_EPISODE_LIGHT then
      tx, ty = sw * 0.25, sh * 0.5
    elseif cmd == CMD_EPISODE_DARK then
      tx, ty = sw * 0.75, sh * 0.5
    end
  end

  local nb, list, sig, page, carousel = 0, '', 'none', nil, 0
  local want = flags % 2 >= FLAG_BUTTONS
  local mmf = 0
  if want and mode ~= MODE_AIM and mode ~= MODE_FLIGHT and mode ~= MODE_WAIT then
    nb, list, sig, page, carousel = buttons()
    if sig ~= _G._last_sig then
      _G._last_sig = sig
      _G._frames_since_sig = 0
    else
      _G._frames_since_sig = (_G._frames_since_sig or 0) + 1
    end
    if focus and focus > 1 and (_G._frames_since_sig > 10) then pcall(reveal, focus) end
    local ok, f = pcall(main_menu_flags)
    if ok then mmf = f end
    -- the pause page is what is on top: B does nothing there (+ resumes)
    if mode == MODE_PAUSED and not popup_open() then mmf = mmf + 8 end
    -- a level-selection page turning: the ring holds still until it rests
    if levelName == 'LevelSelection' and not camera_settled() then mmf = mmf + 16 end
  end

  if cmd == CMD_SPIN_LEFT or cmd == CMD_SPIN_RIGHT then
    if not page then
      local b = base_frame()
      page = b and find_episode_page(b, 0)
    end
    if page then
      spin(page, cmd == CMD_SPIN_LEFT and 'LEFT' or 'RIGHT', cmd_arg > 0 and cmd_arg / 1000 or nil)
    elseif type(ln) == 'string' and (ln == 'EpisodeSelection' or sfind(ln, 'pisodeSel', 1, true) or
                                     ln == 'WorldSelection' or sfind(ln, 'orldSel', 1, true)) then
      -- ABSW2 EpisodeSelection: no Lua carousel object -- do a horizontal swipe gesture
      -- The C runtime's abs_input_syn() injects: down, move, up
      -- We queue a swipe request via the request() mechanism
      -- Direction: LEFT swipe means moving left (previous world), ZL = prev
      local swipe_dx = cmd == CMD_SPIN_LEFT and -320 or 320
      local cx, cy = sw * 0.5, sh * 0.5
      -- Use __abs interface to directly call syn_move sequence if available,
      -- otherwise request a swipe via tx/ty mechanism
      local ok_swipe = false
      local sabs = type(__abs) == 'table' and __abs
      if sabs and type(sabs.syn) == 'function' then
        -- phase 0=down, 2=move, 1=up
        pcall(sabs.syn, 0, cx, cy)
        pcall(sabs.syn, 2, cx + swipe_dx * 0.5, cy)
        pcall(sabs.syn, 2, cx + swipe_dx, cy)
        pcall(sabs.syn, 1, cx + swipe_dx, cy)
        ok_swipe = true
        print(sfmt('[ep-debug] swipe via __abs.syn dir=%s dx=%d', cmd == CMD_SPIN_LEFT and 'LEFT' or 'RIGHT', swipe_dx))
      end
      if not ok_swipe then
        -- Fallback: use onKeyEvent if the base frame supports it
        local b2 = base_frame()
        if b2 and type(b2.onKeyEvent) == 'function' then
          pcall(b2.onKeyEvent, b2, 'PRESS', cmd == CMD_SPIN_LEFT and 'LEFT' or 'RIGHT')
          ok_swipe = true
          print('[ep-debug] swipe via onKeyEvent')
        end
      end
      if not ok_swipe then
        print('[ep-debug] swipe fallback: no method available')
      end
    end
  elseif cmd == CMD_PAGE_NEXT or cmd == CMD_PAGE_PREV then
    local b = base_frame()
    local pg = b and find_pager(b, 0)
    print(sfmt('[cmd-page] cmd=%d ln=%s pg=%s', cmd, tostring(levelName), tostring(pg ~= nil)))
    if not pg then flip_page(cmd == CMD_PAGE_NEXT) end
    cmd_focus = focus
    if pg then
      if cmd == CMD_PAGE_NEXT then pcall(pg.next, pg) else pcall(pg.previous, pg) end
    end
  end



  local r = '-'
  if #reqs > 0 then
    r = concat(reqs, ','):gsub('[^%w_:,%-]', '')
    if r == '' then r = '-' end
    print(sfmt('[reqs] sending: %s', r))
    reqs = {}
  end
  local vx, vy, vw, vh = -1, -1, -1, -1
  local okv, a, b2, c2, d2 = pcall(popup_vrect)
  if okv and a then vx, vy, vw, vh = a / sw, b2 / sh, c2 / sw, d2 / sh end

  local is_ep_sel_v = (page ~= nil or
               ln == 'EpisodeSelection' or ln == 'EpisodeSelectionScene' or
               ln == 'WorldSelection' or ln == 'WorldSelectionScene' or
               ln == 'LevelSelection' or
               (type(ln) == 'string' and sfind(ln, 'pisodeSel', 1, true)) or
               (type(ln) == 'string' and sfind(ln, 'orldSel', 1, true))) and 1 or 0
  -- cutscene/comic (levelName like Chapter_1_light_Comic_1): 3 = A taps the screen
  if type(ln) == 'string' and sfind(ln, 'Comic', 1, true) then is_ep_sel_v = 3 end
  if is_ep_sel_v == 1 and frame_no % 60 == 0 then
    print(sfmt('[ep-debug] is_ep_sel=1 ln=%s page=%s carousel=%d', tostring(ln), tostring(page), carousel))
  end
  return sfmt('%d %d %.1f %.1f %d %.4f %.4f %.4f %.4f %.4f %d %d %.4f %.4f %s %s %.3f %d %.4f %.4f %.4f %.4f %d %d %d %s',
              game, mode, sw, sh, ready, bx, by, lx, ly, pullr, aiming, special, tx, ty, sig, r,
              num(time) or -1, mmf, vx, vy, vw, vh, carousel, is_ep_sel_v, nb, list)
end

-- what the last scan saw, for debug.log ([debug] log_lua)
function A.dump()
  local nb, list, sig, _, carousel = buttons()
  return sfmt('sig %s carousel %d, %d items: %s', sig, carousel, levelName == 'EpisodeSelection' and 1 or 0, nb, list)
end

link_gamelua()
