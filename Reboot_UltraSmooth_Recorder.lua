--========================================================--
-- REBOOT ULTRASMOOTH RECORDER
-- Catmull-Rom / Centripedal Route Recorder
-- Standalone Roblox Lua module/script
--========================================================--

--[[
    Features
    • Smooth waypoint recording
    • Centripetal Catmull-Rom interpolation
    • Smooth CFrame rotation interpolation
    • Adaptive playback timing
    • Adjustable sample interval / playback speed / smoothness
    • Route preview
    • JSON export/import
    • Loop playback
    • Jump / humanoid-state capture
    • Mobile-friendly simple command API

    Usage:
        local Recorder = loadstring(<this file>)()

        Recorder:StartRecording()
        -- move around
        Recorder:StopRecording()

        Recorder:SetSmoothness(0.85)
        Recorder:SetPlaybackSpeed(1)
        Recorder:Play()

    This recorder is intended for use in Roblox experiences where you
    are permitted to run custom Lua code.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer

local Recorder = {}
Recorder.__index = Recorder

--========================================================--
-- Configuration
--========================================================--

local DEFAULTS = {
    SampleInterval = 0.045, -- ~22 samples/sec
    PlaybackSpeed = 1,
    Smoothness = 0.85,      -- 0 = less smoothing, 1 = maximum curve smoothing
    Tension = 0.0,
    Loop = false,
    PreviewColor = Color3.fromRGB(255, 170, 60),
    PreviewThickness = 2,
}

--========================================================--
-- Helpers
--========================================================--

local function clamp(x, a, b)
    return math.max(a, math.min(b, x))
end

local function getCharacter()
    return LocalPlayer and LocalPlayer.Character
end

local function getRoot(character)
    if not character then
        return nil
    end

    return character:FindFirstChild("HumanoidRootPart")
end

local function getHumanoid(character)
    if not character then
        return nil
    end

    return character:FindFirstChildOfClass("Humanoid")
end

local function getStateName(humanoid)
    if not humanoid then
        return "None"
    end

    local ok, state = pcall(function()
        return humanoid:GetState()
    end)

    return ok and state.Name or "None"
end

local function cframeToArray(cf)
    local p = cf.Position
    local x, y, z,
        r00, r01, r02,
        r10, r11, r12,
        r20, r21, r22 = cf:GetComponents()

    return {
        p.X, p.Y, p.Z,
        r00, r01, r02,
        r10, r11, r12,
        r20, r21, r22
    }
end

local function arrayToCFrame(a)
    return CFrame.new(
        a[1], a[2], a[3],
        a[4], a[5], a[6],
        a[7], a[8], a[9],
        a[10], a[11], a[12]
    )
end

local function distance(a, b)
    return (a.Position - b.Position).Magnitude
end

--========================================================--
-- Constructor
--========================================================--

function Recorder.new()
    local self = setmetatable({}, Recorder)

    self.Config = table.clone(DEFAULTS)

    self.Route = {}
    self.IsRecording = false
    self.IsPlaying = false

    self._recordConnection = nil
    self._playConnection = nil
    self._recordClock = 0
    self._playTime = 0
    self._routeDuration = 0
    self._previewFolder = nil

    return self
end

--========================================================--
-- Configuration API
--========================================================--

function Recorder:SetSampleInterval(value)
    value = tonumber(value)
    if not value then
        return
    end

    self.Config.SampleInterval = clamp(value, 0.01, 0.5)
end

function Recorder:SetPlaybackSpeed(value)
    value = tonumber(value)
    if not value then
        return
    end

    self.Config.PlaybackSpeed = clamp(value, 0.05, 5)
end

function Recorder:SetSmoothness(value)
    value = tonumber(value)
    if not value then
        return
    end

    self.Config.Smoothness = clamp(value, 0, 1)
end

function Recorder:SetTension(value)
    value = tonumber(value)
    if not value then
        return
    end

    self.Config.Tension = clamp(value, -1, 1)
end

function Recorder:SetLoop(enabled)
    self.Config.Loop = enabled == true
end

--========================================================--
-- Recording
--========================================================--

function Recorder:_capture()
    local character = getCharacter()
    local root = getRoot(character)
    local humanoid = getHumanoid(character)

    if not root then
        return
    end

    local now = os.clock()
    local previous = self.Route[#self.Route]

    -- Prevent virtually identical samples from bloating the route.
    if previous and now - previous.AbsoluteTime < self.Config.SampleInterval then
        return
    end

    local cf = root.CFrame

    -- Store time relative to recording start.
    local t = now - (self._recordStartTime or now)

    local point = {
        Time = t,
        CFrame = cframeToArray(cf),
        State = getStateName(humanoid),
        Velocity = {
            root.AssemblyLinearVelocity.X,
            root.AssemblyLinearVelocity.Y,
            root.AssemblyLinearVelocity.Z
        },
        AbsoluteTime = now,
    }

    -- Adaptive sampling:
    -- keep important turns / movement changes even if the normal interval
    -- has not elapsed by a large margin.
    if previous then
        local previousCF = arrayToCFrame(previous.CFrame)
        local movement = distance(previousCF, cf)
        local angle = previousCF:ToObjectSpace(cf)
        local _, yAngle = angle:ToEulerAnglesYXZ()

        if movement < 0.035 and math.abs(yAngle) < math.rad(1.5)
            and previous.State == point.State
            and now - previous.AbsoluteTime < self.Config.SampleInterval * 1.75 then
            return
        end
    end

    table.insert(self.Route, point)
end

function Recorder:StartRecording()
    if self.IsPlaying then
        self:StopPlayback()
    end

    self:StopRecording()

    self.Route = {}
    self._recordClock = 0
    self._recordStartTime = os.clock()
    self.IsRecording = true

    self._recordConnection = RunService.Heartbeat:Connect(function(dt)
        if not self.IsRecording then
            return
        end

        self._recordClock += dt

        -- Heartbeat runs every frame, but actual route samples are throttled.
        if self._recordClock >= self.Config.SampleInterval then
            self._recordClock = 0
            self:_capture()
        end
    end)

    -- Capture the first point immediately.
    self:_capture()

    return true
end

function Recorder:StopRecording()
    if self._recordConnection then
        self._recordConnection:Disconnect()
        self._recordConnection = nil
    end

    self.IsRecording = false

    -- Strip internal fields from recorded points.
    for _, point in ipairs(self.Route) do
        point.AbsoluteTime = nil
    end

    self:_recalculateDuration()

    return #self.Route
end

--========================================================--
-- Route Processing
--========================================================--

function Recorder:_recalculateDuration()
    self._routeDuration = 0

    if #self.Route > 0 then
        self._routeDuration = self.Route[#self.Route].Time
    end
end

function Recorder:Clear()
    self:StopRecording()
    self:StopPlayback()
    self.Route = {}
    self._routeDuration = 0
    self:ClearPreview()
end

function Recorder:GetPointCount()
    return #self.Route
end

function Recorder:GetDuration()
    return self._routeDuration
end

--========================================================--
-- Centripetal Catmull-Rom
--========================================================--

-- Centripetal parameterization avoids many of the loops/overshoots
-- produced by uniform Catmull-Rom on unevenly spaced waypoints.

local function getKnot(t, p0, p1, alpha)
    local d = (p1 - p0).Magnitude
    return t + math.pow(math.max(d, 0.0001), alpha)
end

local function centripetalCR(p0, p1, p2, p3, u, alpha, tension)
    alpha = alpha or 0.5
    tension = tension or 0

    local t0 = 0
    local t1 = getKnot(t0, p0, p1, alpha)
    local t2 = getKnot(t1, p1, p2, alpha)
    local t3 = getKnot(t2, p2, p3, alpha)

    local t = t1 + (t2 - t1) * clamp(u, 0, 1)

    local A1 = p0:Lerp(p1, (t - t0) / math.max(t1 - t0, 0.0001))
    local A2 = p1:Lerp(p2, (t - t1) / math.max(t2 - t1, 0.0001))
    local A3 = p2:Lerp(p3, (t - t2) / math.max(t3 - t2, 0.0001))

    local B1 = A1:Lerp(A2, (t - t0) / math.max(t2 - t0, 0.0001))
    local B2 = A2:Lerp(A3, (t - t1) / math.max(t3 - t1, 0.0001))

    local C = B1:Lerp(B2, (t - t1) / math.max(t2 - t1, 0.0001))

    -- Tension moves the result toward the center linear interpolation.
    local linear = p1:Lerp(p2, u)
    return C:Lerp(linear, clamp(tension, -1, 1) * 0.5)
end

local function smoothCFrame(a, b, amount)
    amount = clamp(amount or 0.85, 0, 1)

    local pa = a.Position
    local pb = b.Position

    local pos = pa:Lerp(pb, amount)

    -- CFrame:Lerp provides stable rotational interpolation without
    -- manually manipulating Euler angles.
    local rot = a:Lerp(b, amount)

    return CFrame.new(pos) * rot.Rotation
end

function Recorder:_getSample(index, u)
    local count = #self.Route

    if count == 0 then
        return nil
    end

    if count == 1 then
        return arrayToCFrame(self.Route[1].CFrame)
    end

    index = clamp(index, 1, count - 1)
    u = clamp(u, 0, 1)

    local i0 = math.max(1, index - 1)
    local i1 = index
    local i2 = math.min(count, index + 1)
    local i3 = math.min(count, index + 2)

    local p0 = arrayToCFrame(self.Route[i0].CFrame).Position
    local p1 = arrayToCFrame(self.Route[i1].CFrame).Position
    local p2 = arrayToCFrame(self.Route[i2].CFrame).Position
    local p3 = arrayToCFrame(self.Route[i3].CFrame).Position

    -- Convert global smoothness to a curve bias.
    -- 0.5 = standard centripetal CR.
    local alpha = 0.5

    -- Blend CR output with linear interpolation so the user can tune
    -- between direct and ultra-smooth motion.
    local crPos = centripetalCR(
        p0, p1, p2, p3,
        u,
        alpha,
        self.Config.Tension
    )

    local linearPos = p1:Lerp(p2, u)
    local smoothness = self.Config.Smoothness
    local finalPos = linearPos:Lerp(crPos, smoothness)

    local cf1 = arrayToCFrame(self.Route[i1].CFrame)
    local cf2 = arrayToCFrame(self.Route[i2].CFrame)

    -- Smooth orientation continuously across the same segment.
    local finalCF = cf1:Lerp(cf2, u)

    return CFrame.new(finalPos) * finalCF.Rotation
end

function Recorder:_findSegment(time)
    local count = #self.Route

    if count <= 1 then
        return 1, 0
    end

    if time <= self.Route[1].Time then
        return 1, 0
    end

    if time >= self.Route[count].Time then
        return count - 1, 1
    end

    -- Binary search keeps long routes inexpensive.
    local low = 1
    local high = count - 1

    while low <= high do
        local mid = math.floor((low + high) / 2)

        local t1 = self.Route[mid].Time
        local t2 = self.Route[mid + 1].Time

        if time >= t1 and time <= t2 then
            local span = math.max(t2 - t1, 0.000001)
            return mid, (time - t1) / span
        elseif time < t1 then
            high = mid - 1
        else
            low = mid + 1
        end
    end

    return clamp(low, 1, count - 1), 0
end

--========================================================--
-- Playback
--========================================================--

function Recorder:_applyState(point)
    local character = getCharacter()
    local humanoid = getHumanoid(character)

    if not humanoid or not point then
        return
    end

    -- Preserve the most meaningful recorded state.
    local state = point.State

    if state == "Jumping" then
        pcall(function()
            humanoid.Jump = true
        end)
    elseif state == "Freefall" then
        pcall(function()
            humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
        end)
    elseif state == "Landed" then
        pcall(function()
            humanoid:ChangeState(Enum.HumanoidStateType.Landed)
        end)
    end
end

function Recorder:_moveTo(cf)
    local character = getCharacter()
    local root = getRoot(character)

    if not root then
        return false
    end

    -- PivotTo is used so the entire character remains coherent.
    character:PivotTo(cf)
    return true
end

function Recorder:Play()
    if self.IsRecording then
        self:StopRecording()
    end

    self:StopPlayback()

    if #self.Route < 2 then
        return false, "Not enough route points."
    end

    self:_recalculateDuration()

    self.IsPlaying = true
    self._playTime = 0

    self._playConnection = RunService.RenderStepped:Connect(function(dt)
        if not self.IsPlaying then
            return
        end

        if #self.Route < 2 or self._routeDuration <= 0 then
            self:StopPlayback()
            return
        end

        self._playTime += dt * self.Config.PlaybackSpeed

        if self._playTime >= self._routeDuration then
            if self.Config.Loop then
                self._playTime = self._playTime % self._routeDuration
            else
                self._playTime = self._routeDuration
            end
        end

        local index, u = self:_findSegment(self._playTime)
        local cf = self:_getSample(index, u)

        if cf then
            self:_moveTo(cf)
        end

        -- State changes are only checked around waypoint boundaries.
        local p = self.Route[index]
        if p and u < 0.05 then
            self:_applyState(p)
        end

        if not self.Config.Loop and self._playTime >= self._routeDuration then
            self:StopPlayback()
        end
    end)

    return true
end

function Recorder:StopPlayback()
    if self._playConnection then
        self._playConnection:Disconnect()
        self._playConnection = nil
    end

    self.IsPlaying = false
end

function Recorder:Pause()
    if not self.IsPlaying then
        return
    end

    self:StopPlayback()
end

function Recorder:Resume()
    if self.IsPlaying or #self.Route < 2 then
        return
    end

    self.IsPlaying = true

    self._playConnection = RunService.RenderStepped:Connect(function(dt)
        if not self.IsPlaying then
            return
        end

        self._playTime += dt * self.Config.PlaybackSpeed

        if self._playTime >= self._routeDuration then
            if self.Config.Loop then
                self._playTime = self._playTime % self._routeDuration
            else
                self._playTime = self._routeDuration
            end
        end

        local index, u = self:_findSegment(self._playTime)
        local cf = self:_getSample(index, u)

        if cf then
            self:_moveTo(cf)
        end

        if not self.Config.Loop and self._playTime >= self._routeDuration then
            self:StopPlayback()
        end
    end)
end

--========================================================--
-- Preview
--========================================================--

function Recorder:ClearPreview()
    if self._previewFolder then
        self._previewFolder:Destroy()
        self._previewFolder = nil
    end
end

function Recorder:Preview(step)
    self:ClearPreview()

    if #self.Route < 2 then
        return false, "Not enough route points."
    end

    step = tonumber(step) or 0.08
    step = clamp(step, 0.02, 0.5)

    local folder = Instance.new("Folder")
    folder.Name = "RebootRecorderPreview"
    folder.Parent = workspace
    self._previewFolder = folder

    local duration = self._routeDuration
    local previous = nil

    for t = 0, duration, step do
        local index, u = self:_findSegment(t)
        local cf = self:_getSample(index, u)

        if cf then
            local part = Instance.new("Part")
            part.Name = "Point"
            part.Anchored = true
            part.CanCollide = false
            part.CanQuery = false
            part.CanTouch = false
            part.Transparency = 1
            part.Size = Vector3.new(0.15, 0.15, 0.15)
            part.CFrame = cf
            part.Parent = folder

            local attachment = Instance.new("Attachment")
            attachment.Parent = part

            if previous then
                local beam = Instance.new("Beam")
                beam.Attachment0 = previous
                beam.Attachment1 = attachment
                beam.Width0 = self.Config.PreviewThickness * 0.01
                beam.Width1 = self.Config.PreviewThickness * 0.01
                beam.FaceCamera = true
                beam.LightEmission = 1
                beam.Color = ColorSequence.new(self.Config.PreviewColor)
                beam.Parent = folder
            end

            previous = attachment
        end
    end

    return true
end

--========================================================--
-- JSON Export / Import
--========================================================--

function Recorder:Export()
    local payload = {
        Version = 2,
        Name = "Reboot UltraSmooth Route",
        Settings = {
            SampleInterval = self.Config.SampleInterval,
            PlaybackSpeed = self.Config.PlaybackSpeed,
            Smoothness = self.Config.Smoothness,
            Tension = self.Config.Tension,
            Loop = self.Config.Loop,
        },
        Points = self.Route,
    }

    local ok, encoded = pcall(function()
        return HttpService:JSONEncode(payload)
    end)

    if not ok then
        return nil, encoded
    end

    return encoded
end

function Recorder:Import(json)
    if type(json) ~= "string" then
        return false, "Expected JSON string."
    end

    local ok, payload = pcall(function()
        return HttpService:JSONDecode(json)
    end)

    if not ok or type(payload) ~= "table" then
        return false, "Invalid JSON route."
    end

    local points = payload.Points

    if type(points) ~= "table" or #points < 1 then
        return false, "Route contains no points."
    end

    local clean = {}

    for _, point in ipairs(points) do
        if type(point) == "table"
            and type(point.Time) == "number"
            and type(point.CFrame) == "table"
            and #point.CFrame >= 12 then

            table.insert(clean, {
                Time = point.Time,
                CFrame = point.CFrame,
                State = point.State or "None",
                Velocity = point.Velocity or {0, 0, 0},
            })
        end
    end

    if #clean == 0 then
        return false, "No valid route points."
    end

    self:StopRecording()
    self:StopPlayback()
    self:ClearPreview()

    self.Route = clean

    if payload.Settings then
        local s = payload.Settings

        if s.SampleInterval then
            self:SetSampleInterval(s.SampleInterval)
        end

        if s.PlaybackSpeed then
            self:SetPlaybackSpeed(s.PlaybackSpeed)
        end

        if s.Smoothness then
            self:SetSmoothness(s.Smoothness)
        end

        if s.Tension then
            self:SetTension(s.Tension)
        end

        if s.Loop ~= nil then
            self:SetLoop(s.Loop)
        end
    end

    self:_recalculateDuration()

    return true
end

--========================================================--
-- Route Optimization
--========================================================--

function Recorder:Optimize(minDistance)
    minDistance = tonumber(minDistance) or 0.08
    minDistance = math.max(minDistance, 0.001)

    if #self.Route < 3 then
        return #self.Route
    end

    local result = {self.Route[1]}

    for i = 2, #self.Route - 1 do
        local prev = result[#result]
        local current = self.Route[i]
        local nextPoint = self.Route[i + 1]

        local a = arrayToCFrame(prev.CFrame).Position
        local b = arrayToCFrame(current.CFrame).Position
        local c = arrayToCFrame(nextPoint.CFrame).Position

        local ab = (b - a).Magnitude
        local bc = (c - b).Magnitude

        -- Keep points that represent real movement or state changes.
        if ab >= minDistance
            or bc >= minDistance
            or current.State ~= prev.State then
            table.insert(result, current)
        end
    end

    table.insert(result, self.Route[#self.Route])

    self.Route = result
    self:_recalculateDuration()

    return #self.Route
end

--========================================================--
-- Status
--========================================================--

function Recorder:GetStatus()
    return {
        Recording = self.IsRecording,
        Playing = self.IsPlaying,
        Points = #self.Route,
        Duration = self._routeDuration,
        SampleInterval = self.Config.SampleInterval,
        PlaybackSpeed = self.Config.PlaybackSpeed,
        Smoothness = self.Config.Smoothness,
        Tension = self.Config.Tension,
        Loop = self.Config.Loop,
    }
end

--========================================================--
-- Cleanup
--========================================================--

function Recorder:Destroy()
    self:StopRecording()
    self:StopPlayback()
    self:ClearPreview()

    self.Route = {}
end

--========================================================--
-- Singleton + Convenience API
--========================================================--

local instance = Recorder.new()

-- Expose class and singleton-style methods.
instance.New = Recorder.new

return instance
