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
	  - Each frame, semi-implicit Euler integration updates position and velocity, applies
	    drag, and checks for collisions via a segment raycast between the last and
	    current position — giving sub-frame collision accuracy even at high speeds.
	  - On hit, a ricochet angle is computed from the surface normal and the remaining
	    kinetic energy determines whether the projectile bounces or embeds.
	  - A simple object pool recycles Part instances so we never spam Instance.new
	    during gameplay.
]]

local RunService  = game:GetService("RunService")
local Workspace   = game:GetService("Workspace")
local Debris      = game:GetService("Debris")

-- ─── Constants ────────────────────────────────────────────────────────────────

local GRAVITY          = Vector3.new(0, -196.2, 0)  -- studs/s², roughly 2× real gravity for snappy feel
local DRAG_COEFFICIENT = 0.012                       -- air resistance scalar applied per-frame
local MAX_BOUNCES      = 4                           -- hard cap on ricochets before projectile dies
local POOL_SIZE        = 40                          -- how many Part instances to pre-allocate
local TRAIL_LIFETIME   = 0.08                        -- seconds each trail segment stays visible
local MAX_LIFETIME     = 5                           -- seconds before a projectile is force-removed

-- ─── Object Pool ──────────────────────────────────────────────────────────────
-- Re-using Parts avoids the cost of creating/destroying Instances every shot.
-- The pool hands out a Part and marks it "in use"; returning it resets visuals
-- and parks it far off-screen so it doesn't interfere with raycasts.

local Pool = {}
Pool.__index = Pool

function Pool.new(template: Part, parent: Instance): typeof(setmetatable({} :: { _free: { Part }, _parent: Instance }, Pool))
	local self   = setmetatable({} :: { _free: { Part }, _parent: Instance }, Pool)
	self._free   = {}
	self._parent = parent

	for i = 1, POOL_SIZE do
		local p = template:Clone() :: Part
		p.Name       = "PooledProjectile_" .. i
		p.Anchored   = true
		p.CanCollide = false
		p.CastShadow = false
		p.Parent     = parent
		-- Park off-screen while idle so it doesn't appear in raycasts
		p.CFrame     = CFrame.new(0, -5000, 0)
		table.insert(self._free, p)
	end

	return self
end

-- Acquire a Part from the pool; returns nil when all slots are occupied
function Pool:acquire(): Part?
	return table.remove(self._free)
end

-- Return a Part to the pool and reset its visual state
function Pool:release(part: Part)
	part.CFrame = CFrame.new(0, -5000, 0)
	part.Size   = Vector3.new(0.2, 0.2, 0.2)
	part.Color  = Color3.fromRGB(255, 200, 50)
	table.insert(self._free, part)
end

-- ─── Projectile Class ─────────────────────────────────────────────────────────
--[[
	Each Projectile stores:
	  position  Vector3        – current world position
	  velocity  Vector3        – current velocity in studs/s
	  bounces   number         – how many times it has ricocheted
	  part      Part?          – visual instance borrowed from the pool
	  alive     boolean        – set to false to schedule removal this frame
	  onHit     function       – optional callback(hitPart, hitPosition, normal)
	  lifeTime  number         – accumulated time since spawn
	  maxLife   number         – lifetime cap before force-removal

	Semi-implicit Euler integration is used: velocity is updated before position.
	This is more energy-stable than standard Euler and keeps bounces feeling
	consistent without per-projectile tuning.
]]

type OnHitCallback = (hitInstance: Instance, hitPos: Vector3, normal: Vector3) -> ()

local Projectile = {}
Projectile.__index = Projectile

function Projectile.new(
	origin: Vector3,
	direction: Vector3,
	speed: number,
	pool: typeof(Pool),
	onHit: OnHitCallback?,
	ignoreList: { Instance }?
)
	local self = setmetatable({}, Projectile)

	self.position   = origin
	self.velocity   = direction.Unit * speed
	self.bounces    = 0
	self.alive      = true
	self.pool       = pool
	self.onHit      = onHit or function(_i: Instance, _p: Vector3, _n: Vector3) end
	self.lifeTime   = 0
	self.maxLife    = MAX_LIFETIME
	-- Store the ignore list so the raycast always excludes the shooter's character
	self._ignore    = ignoreList or {}

	self.part = pool:acquire()
	if self.part then
		self.part.CFrame = CFrame.new(origin, origin + self.velocity)
		self.part.Size   = Vector3.new(0.2, 0.2, 0.6)
	end

	return self
end

-- Advance simulation by `dt` seconds; returns false when the projectile should die
function Projectile:update(dt: number): boolean
	-- Clamp dt to avoid tunneling on extreme frame spikes
	dt = math.clamp(dt, 0, 0.033)

	self.lifeTime += dt
	if self.lifeTime > self.maxLife or not self.alive then
		return false
	end

	-- ── Semi-implicit Euler ──────────────────────────────────────────────────
	-- Velocity is integrated before position so kinetic energy decays properly.
	-- drag force is proportional to velocity (linear drag model).
	local drag         = self.velocity * DRAG_COEFFICIENT
	local acceleration = GRAVITY - drag
	local prevPosition = self.position

	self.velocity = self.velocity + acceleration * dt
	self.position = self.position + self.velocity * dt

	-- ── Sub-frame Segment Raycast ────────────────────────────────────────────
	-- Casting along the full segment traveled this frame catches fast projectiles
	-- that would otherwise skip through thin geometry between frames.
	local moveDir  = self.position - prevPosition
	local moveDist = moveDir.Magnitude

	if moveDist > 0 then
		local params = RaycastParams.new()
		-- Exclude both the visual projectile Part and the shooter's character
		local excludeList = { self.part }
		for _, inst in ipairs(self._ignore) do
			table.insert(excludeList, inst)
		end
		params.FilterDescendantsInstances = excludeList
		params.FilterType = Enum.RaycastFilterType.Exclude

		local result = Workspace:Raycast(prevPosition, moveDir.Unit * (moveDist + 0.05), params)
		if result then
			return self:_handleImpact(result)
		end
	end

	-- ── Visual Update ────────────────────────────────────────────────────────
	if self.part then
		-- Orient the elongated Part along the current travel direction
		local lookAt = self.position + self.velocity.Unit * 0.01
		self.part.CFrame = CFrame.lookAt(self.position, lookAt)
		self:_spawnTrailSegment(prevPosition)
	end

	return true
end

-- Determine whether to ricochet or embed based on impact angle and bounce count
function Projectile:_handleImpact(result: RaycastResult): boolean
	local normal = result.Normal
	local hitPos = result.Position

	self.onHit(result.Instance, hitPos, normal)

	-- ── Ricochet Decision ────────────────────────────────────────────────────
	-- Dot product of normalised velocity and surface normal gives impact angle:
	--   dot ≈  0  → grazing / shallow  → likely to ricochet
	--   dot ≈ -1  → head-on / steep    → likely to embed
	local speed = self.velocity.Magnitude
	if speed < 0.01 then
		return false
	end

	local incidenceDot = (self.velocity / speed):Dot(normal)
	local canBounce    = self.bounces < MAX_BOUNCES and incidenceDot > -0.65

	if canBounce then
		-- Reflect velocity across the surface normal; attenuate for energy loss
		local reflected = self.velocity - 2 * self.velocity:Dot(normal) * normal
		self.velocity   = reflected * 0.55        -- ~45% kinetic energy lost per bounce
		self.position   = hitPos + normal * 0.1   -- nudge off surface to prevent re-hit next frame
		self.bounces   += 1
		self:_spawnImpactSpark(hitPos, normal)
		return true
	else
		self:_spawnImpactSpark(hitPos, normal)
		self.alive = false
		return false
	end
end

-- Leave a small glowing dot along the flight path; Debris auto-cleans it
function Projectile:_spawnTrailSegment(pos: Vector3)
	if not self.part then return end

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

-- Burst of sparks radiating from the impact point in a cone along the normal
function Projectile:_spawnImpactSpark(pos: Vector3, normal: Vector3)
	for _ = 1, 6 do
		-- Random offset spreads sparks into a cone instead of a straight line
		local randOffset = Vector3.new(
			math.random() * 2 - 1,
			math.random() * 2 - 1,
			math.random() * 2 - 1
		).Unit * 0.4
		local sparkDir = (normal + randOffset).Unit

		local spark      = Instance.new("Part")
		spark.Anchored   = false
		spark.CanCollide = false
		spark.CastShadow = false
		spark.Size       = Vector3.new(0.07, 0.07, 0.07)
		spark.Shape      = Enum.PartType.Ball
		spark.Color      = Color3.fromRGB(255, 100, 30)
		spark.Material   = Enum.Material.Neon
		spark.CFrame     = CFrame.new(pos + normal * 0.1)
		-- AssemblyLinearVelocity sets initial physics velocity on an unanchored Part
		spark.AssemblyLinearVelocity = sparkDir * math.random(8, 20)
		spark.Parent     = Workspace

		Debris:AddItem(spark, 0.35)
	end
end

-- Release the pooled Part and mark the projectile as dead
function Projectile:destroy()
	if self.part then
		self.pool:release(self.part)
		self.part = nil
	end
	self.alive = false
end

-- ─── ProjectileSystem ─────────────────────────────────────────────────────────
--[[
	Top-level manager: owns the pool and the active projectile list.
	External code calls :fire() to shoot; a single Heartbeat drives everything.
]]

local ProjectileSystem = {}
ProjectileSystem.__index = ProjectileSystem

function ProjectileSystem.new(parent: Instance)
	local self = setmetatable({}, ProjectileSystem)

	-- Build the shared template; pool clones it POOL_SIZE times then we discard it
	local template        = Instance.new("Part")
	template.Anchored     = true
	template.CanCollide   = false
	template.CastShadow   = false
	template.Material     = Enum.Material.Neon
	template.Color        = Color3.fromRGB(255, 200, 50)
	template.Size         = Vector3.new(0.2, 0.2, 0.6)

	self._pool       = Pool.new(template, parent)
	self._active     = {} :: { typeof(Projectile) }
	self._connection = nil

	template:Destroy()
	self:_startLoop()
	return self
end

-- Shoot a projectile from `origin` toward `direction` at `speed` studs/s.
-- `onHit` is called server-side on every surface contact.
-- `ignoreList` should contain the shooter's character to avoid self-hit.
function ProjectileSystem:fire(
	origin: Vector3,
	direction: Vector3,
	speed: number,
	onHit: OnHitCallback?,
	ignoreList: { Instance }?
)
	local proj = Projectile.new(origin, direction, speed, self._pool, onHit, ignoreList)
	table.insert(self._active, proj)
end

-- Drive all active projectiles; iterate backwards for safe mid-loop removal
function ProjectileSystem:_startLoop()
	self._connection = RunService.Heartbeat:Connect(function(dt: number)
		for i = #self._active, 1, -1 do
			local proj  = self._active[i]
			local alive = proj:update(dt)
			if not alive then
				proj:destroy()
				table.remove(self._active, i)
			end
		end
	end)
end

-- Disconnect the loop and destroy all in-flight projectiles
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

-- ─── Demo Entry Point ─────────────────────────────────────────────────────────
-- Wires up a server-side listener for the "FireProjectile" RemoteEvent.
-- A LocalScript in StarterGui sends the mouse hit position on left-click.
-- Requires: a Part named "Launcher" in Workspace and a RemoteEvent named
-- "FireProjectile" in ReplicatedStorage.

local function initDemo()
	local system = ProjectileSystem.new(Workspace)

	local launcher = Workspace:FindFirstChild("Launcher")
	if not launcher then
		warn("[ProjectileSystem] Place a Part named 'Launcher' in Workspace.")
		return
	end

	local remote = game:GetService("ReplicatedStorage"):FindFirstChild("FireProjectile")
	if not remote then
		warn("[ProjectileSystem] Place a RemoteEvent named 'FireProjectile' in ReplicatedStorage.")
		return
	end

	(remote :: RemoteEvent).OnServerEvent:Connect(function(player: Player, targetPos: Vector3)
		local char      = player.Character
		local origin    = (launcher :: BasePart).Position
		local direction = targetPos - origin

		-- Pass the shooter's character into the ignore list to prevent self-damage
		system:fire(origin, direction, 180, function(hitInstance: Instance, _hitPos: Vector3, _normal: Vector3)
			local humanoid = hitInstance.Parent
				and hitInstance.Parent:FindFirstChildOfClass("Humanoid")
			if humanoid then
				humanoid:TakeDamage(25)
			end
		end, char and { char } or {})
	end)
end

initDemo()

