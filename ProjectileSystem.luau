--!strict
--[[
	ProjectileSystem.luau
	Author: selennedev

	A custom ballistic projectile system built from scratch using CFrame mathematics,
	raycasting and physics simulation — without relying on Roblox's built-in physics
	engine for movement. This gives full deterministic control over each projectile.

	Architecture overview:
	  - Projectile "objects" are represented as plain Lua tables managed by a metatable
	    class (Projectile). This avoids Instance overhead and keeps simulation data
	    purely in memory until we actually need to move a visual Part.
	  - Each frame the Verlet integration step updates position and velocity, applies
	    drag, and checks for collisions via a segment raycast between the last and
	    current position — giving sub-frame collision accuracy even at high speeds.
	  - On hit, a ricochet angle is computed from the surface normal and the remaining
	    kinetic energy determines whether the projectile bounces or embeds.
	  - A simple object pool recycles Part instances so we never spam Instance.new
	    during gameplay.
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")

-- Constants 

local GRAVITY = Vector3.new(0, -196.2, 0)  -- studs/s², roughly 2× real gravity for snappy feel
local DRAG_COEFFICIENT = 0.012                        -- air resistance scalar applied per-frame
local MAX_BOUNCES = 4                            -- hard cap on ricochets before projectile dies
local POOL_SIZE = 40                           -- how many Part instances to pre-allocate
local TRAIL_LIFETIME = 0.08                         -- seconds each trail segment stays visible

-- Object Pool 
-- Re-using Parts avoids the cost of creating/destroying Instances every shot.
-- The pool hands out a Part and marks it "in use"; returning it resets visuals
-- and parks it far off-screen so it doesn't interfere with raycasts.

local Pool = {}
Pool.__index = Pool

function Pool.new(template, parent)
	local self   = setmetatable({}, Pool)
	self._free   = {}
	self._parent = parent

	for i = 1, POOL_SIZE do
		local p = template:Clone()
		p.Name      = "PooledProjectile_" .. i
		p.Anchored  = true
		p.CanCollide = false
		p.CastShadow = false
		p.Parent    = parent
		-- Park off-screen while idle
		p.CFrame    = CFrame.new(0, -5000, 0)
		table.insert(self._free, p)
	end

	return self
end

-- Acquire a Part from the pool; returns nil if exhausted (caller should handle)
function Pool:acquire()
	return table.remove(self._free)
end

-- Return a Part to the pool and reset its visual state
function Pool:release(part)
	part.CFrame  = CFrame.new(0, -5000, 0)
	part.Size    = Vector3.new(0.2, 0.2, 0.2)
	-- Clear any decals/colour changes applied during lifetime
	part.Color   = Color3.fromRGB(255, 200, 50)
	table.insert(self._free, part)
end

-- Projectile Class
--[[
	Each Projectile stores:
	  position    Vector3   – current world position
	  velocity    Vector3   – current velocity (studs/s)
	  bounces     number    – how many times it has ricocheted
	  part        Part|nil  – the visual instance from the pool
	  alive       boolean   – false → scheduled for removal this frame
	  onHit       function  – optional callback(hitPart, hitPosition, normal)

	Verlet integration is used instead of Euler because it better conserves
	energy, which means bounces look physically believable without tuning.
]]

local Projectile = {}
Projectile.__index = Projectile

function Projectile.new(origin, direction, speed, pool, onHit)
	local self = setmetatable({}, Projectile)

	self.position  = origin
	self.velocity  = direction.Unit * speed
	self.bounces   = 0
	self.alive     = true
	self.pool      = pool
	self.onHit     = onHit or function() end

	-- Grab a visual Part from the pool
	self.part = pool:acquire()
	if self.part then
		self.part.CFrame = CFrame.new(origin, origin + self.velocity)
		self.part.Size   = Vector3.new(0.2, 0.2, 0.6)   -- elongated capsule look
	end

	return self
end

-- Step the simulation forward by `dt` seconds.
-- Returns false when the projectile should be destroyed.
function Projectile:update(dt)
	if not self.alive then return false end
	
-- Verlet Integration 
-- v_new = v + (gravity - drag*v) * dt
-- drag is proportional to velocity to simulate quadratic air resistance
local dragForce      = self.velocity * DRAG_COEFFICIENT
local acceleration   = GRAVITY - dragForce
local prevPosition   = self.position
self.velocity        = self.velocity + acceleration * dt
self.position        = self.position + self.velocity * dt

-- Sub-frame Raycast 
-- Cast along the segment traveled this frame to catch fast projectiles
-- that might otherwise tunnel through thin geometry.
local moveDir    = self.position - prevPosition
local moveDist   = moveDir.Magnitude

	if moveDist > 0 then
		local raycastParams = RaycastParams.new()
		raycastParams.FilterDescendantsInstances = { self.part }
		raycastParams.FilterType = Enum.RaycastFilterType.Exclude

		local result = Workspace:Raycast(prevPosition, moveDir.Unit * (moveDist + 0.05), raycastParams)

		if result then
			return self:_handleImpact(result)
		end
	end
	
--  Visual Update 
	if self.part then
		-- Orient the Part so its long axis aligns with travel direction
		local lookAt = self.position + self.velocity.Unit * 0.01
		self.part.CFrame = CFrame.lookAt(self.position, lookAt)
		self:_spawnTrailSegment(prevPosition)
	end

	return true
end

-- Called on raycast hit; decides ricochet or embed based on angle + bounce count
function Projectile:_handleImpact(result)
	local normal   = result.Normal
	local hitPos   = result.Position

-- Invoke the caller's hit callback so they can apply damage, FX, etc.
	self.onHit(result.Instance, hitPos, normal)

-- Ricochet Decision 
-- The dot product of velocity direction and surface normal tells us the
-- angle of incidence. Shallow angles (close to 0) → likely to bounce.
-- Steep angles (close to -1) → embed.
local incidenceDot = self.velocity.Unit:Dot(normal)
local canBounce    = self.bounces < MAX_BOUNCES and incidenceDot > -0.65

	if canBounce then
		-- Reflect velocity across the surface normal (law of reflection)
		-- and attenuate to simulate energy loss on impact
		local reflected   = self.velocity - 2 * self.velocity:Dot(normal) * normal
		self.velocity     = reflected * 0.55    -- 45% kinetic energy lost per bounce
		self.position     = hitPos + normal * 0.1   -- nudge off surface to avoid re-hit
		self.bounces      = self.bounces + 1
		self:_spawnImpactSpark(hitPos, normal)
		return true   -- still alive
	else
		-- Embed — spawn a final impact effect and die
		self:_spawnImpactSpark(hitPos, normal)
		self.alive = false
		return false
	end
end

-- Spawn a small fading Part at the given position to represent the trail
function Projectile:_spawnTrailSegment(pos)
	if not self.part then return end

	-- Re-use a simple Part for the trail dot; Debris cleans it up automatically
	local dot        = Instance.new("Part")
	dot.Anchored     = true
	dot.CanCollide   = false
	dot.CastShadow   = false
	dot.Size         = Vector3.new(0.12, 0.12, 0.12)
	dot.Shape        = Enum.PartType.Ball
	dot.Color        = Color3.fromRGB(255, 230, 100)
	dot.Material     = Enum.Material.Neon
	dot.Transparency = 0.3
	dot.CFrame       = CFrame.new(pos)
	dot.Parent       = Workspace

	Debris:AddItem(dot, TRAIL_LIFETIME)
end

-- Spawn a burst of small Parts radiating from the impact point along the normal
function Projectile:_spawnImpactSpark(pos, normal)
	local sparkCount = 6
	for i = 1, sparkCount do
		-- Spread sparks in a cone around the reflected normal
		local randOffset = Vector3.new(
			math.random() * 2 - 1,
			math.random() * 2 - 1,
			math.random() * 2 - 1
		).Unit * 0.4

		local sparkDir = (normal + randOffset).Unit

		local spark        = Instance.new("Part")
		spark.Anchored     = false
		spark.CanCollide   = false
		spark.CastShadow   = false
		spark.Size         = Vector3.new(0.07, 0.07, 0.07)
		spark.Shape        = Enum.PartType.Ball
		spark.Color        = Color3.fromRGB(255, 100, 30)
		spark.Material     = Enum.Material.Neon
		spark.CFrame       = CFrame.new(pos + normal * 0.1)
		spark.Velocity     = sparkDir * math.random(8, 20)
		spark.Parent       = Workspace

		Debris:AddItem(spark, 0.35)
	end
end

-- Cleanup — release the visual Part back to the pool
function Projectile:destroy()
	if self.part then
		self.pool:release(self.part)
		self.part = nil
	end
	self.alive = false
end

-- ProjectileSystem
--[[
	The top-level manager that owns the pool and the active projectile list.
	External code calls :fire(origin, direction, speed, onHit) to shoot.
	A single RunService.Heartbeat connection drives all active projectiles.
]]

local ProjectileSystem = {}
ProjectileSystem.__index = ProjectileSystem

function ProjectileSystem.new(parent)
	local self = setmetatable({}, ProjectileSystem)

	-- Build the template Part used by the pool
	local template        = Instance.new("Part")
	template.Anchored     = true
	template.CanCollide   = false
	template.CastShadow   = false
	template.Material     = Enum.Material.Neon
	template.Color        = Color3.fromRGB(255, 200, 50)
	template.Size         = Vector3.new(0.2, 0.2, 0.6)

	self._pool       = Pool.new(template, parent)
	self._active     = {}   -- array of live Projectile objects
	self._connection = nil

	template:Destroy()  -- template no longer needed; pool owns its clones

	self:_startLoop()
	return self
end

-- Fire a new projectile
-- @param origin    Vector3   world position to spawn at
-- @param direction Vector3   unit direction (will be normalized internally)
-- @param speed     number    initial speed in studs/s
-- @param onHit     function  optional; called as onHit(instance, position, normal)
function ProjectileSystem:fire(origin, direction, speed, onHit)
	local proj = Projectile.new(origin, direction, speed, self._pool, onHit)
	table.insert(self._active, proj)
end

-- Internal heartbeat loop — updates all active projectiles and prunes dead ones
function ProjectileSystem:_startLoop()
	self._connection = RunService.Heartbeat:Connect(function(dt)
		-- Iterate backwards so we can safely remove while iterating
		for i = #self._active, 1, -1 do
			local proj   = self._active[i]
			local alive  = proj:update(dt)

			if not alive then
				proj:destroy()
				table.remove(self._active, i)
			end
		end
	end)
end

-- Stop the system and clean up all active projectiles
function ProjectileSystem:destroy()
	if self._connection then
		self._connection:Disconnect()
		self._connection = nil
	end
	for _, proj in ipairs(self._active) do
		proj:destroy()
	end
	self._active = {}
end

-- Demo Entry Point 
-- This block wires up a simple test: clicking the demo button fires a projectile
-- from a marked Part in the Workspace toward the mouse hit position.
-- In the actual game place the ScreenGui and "FireButton" already exist.

local function initDemo()
	local system = ProjectileSystem.new(Workspace)

-- Locate the launcher origin (a Part named "Launcher" in the Workspace)
local launcher = Workspace:FindFirstChild("Launcher")
	if not launcher then
		warn("ProjectileSystem demo: add a Part named 'Launcher' to Workspace.")
		return
	end

-- Connect to a RemoteEvent fired by a LocalScript on button click
local remote = game:GetService("ReplicatedStorage"):FindFirstChild("FireProjectile")
	if not remote then
		warn("ProjectileSystem demo: add a RemoteEvent named 'FireProjectile' to ReplicatedStorage.")
		return
	end

-- Server receives (player, targetPosition) and fires a projectile toward it
	remote.OnServerEvent:Connect(function(player, targetPos)
		local origin    = launcher.Position
		local direction = (targetPos - origin)

		system:fire(origin, direction, 180, function(hitInstance, hitPos, normal)
			-- Damage logic placeholder — replace with your own damage handler
			local humanoid = hitInstance.Parent and hitInstance.Parent:FindFirstChildOfClass("Humanoid")
			if humanoid then
				humanoid:TakeDamage(25)
			end

			-- Could also stamp a bullet-hole decal here using hitPos + normal * 0.01
		end)
	end)
end

initDemo()