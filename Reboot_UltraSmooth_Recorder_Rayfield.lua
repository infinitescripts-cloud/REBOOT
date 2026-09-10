--========================================================--
-- REBOOT ULTRASMOOTH RECORDER • RAYFIELD EDITION
-- Standalone UI + custom centripetal Catmull-Rom recorder
-- No KeyCode bindings.
--========================================================--

local Rayfield = loadstring(game:HttpGet(
    "https://sirius.menu/rayfield"
))()

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer

local Config = {
    SampleInterval = 0.045,
    PlaybackSpeed = 1,
    Smoothness = 0.85,
    Tension = 0,
    Loop = false,
}

local Route = {}
local Recording = false
local Playing = false
local Paused = false
local RecordConnection
local PlayConnection
local RecordStart = 0
local RecordClock = 0
local PlayTime = 0
local RouteDuration = 0
local PreviewFolder

local function clamp(x,a,b)
    return math.max(a, math.min(b,x))
end

local function Character()
    return LocalPlayer.Character
end

local function Root()
    local c = Character()
    return c and c:FindFirstChild("HumanoidRootPart")
end

local function Humanoid()
    local c = Character()
    return c and c:FindFirstChildOfClass("Humanoid")
end

local function StateName()
    local h = Humanoid()
    if not h then return "None" end
    local ok, state = pcall(function() return h:GetState() end)
    return ok and state.Name or "None"
end

local function CFrameToArray(cf)
    local x,y,z,r00,r01,r02,r10,r11,r12,r20,r21,r22 = cf:GetComponents()
    return {x,y,z,r00,r01,r02,r10,r11,r12,r20,r21,r22}
end

local function ArrayToCFrame(a)
    return CFrame.new(
        a[1],a[2],a[3],
        a[4],a[5],a[6],
        a[7],a[8],a[9],
        a[10],a[11],a[12]
    )
end

local function RecalculateDuration()
    RouteDuration = Route[#Route] and Route[#Route].Time or 0
end

--========================================================--
-- Recording
--========================================================--

local function Capture()
    local r = Root()
    if not r then return end

    local now = os.clock()
    local previous = Route[#Route]

    if previous and now - previous._absolute < Config.SampleInterval then
        return
    end

    local point = {
        Time = now - RecordStart,
        CFrame = CFrameToArray(r.CFrame),
        State = StateName(),
        Velocity = {
            r.AssemblyLinearVelocity.X,
            r.AssemblyLinearVelocity.Y,
            r.AssemblyLinearVelocity.Z
        },
        _absolute = now
    }

    if previous then
        local old = ArrayToCFrame(previous.CFrame)
        local movement = (old.Position - r.Position).Magnitude
        local _, yaw = old:ToObjectSpace(r.CFrame):ToEulerAnglesYXZ()

        if movement < 0.035
            and math.abs(yaw) < math.rad(1.5)
            and previous.State == point.State
            and now - previous._absolute < Config.SampleInterval * 1.75 then
            return
        end
    end

    Route[#Route + 1] = point
end

local function StopRecording()
    if RecordConnection then
        RecordConnection:Disconnect()
        RecordConnection = nil
    end

    Recording = false

    for _, point in ipairs(Route) do
        point._absolute = nil
    end

    RecalculateDuration()
end

local function StartRecording()
    if Playing then
        if PlayConnection then
            PlayConnection:Disconnect()
            PlayConnection = nil
        end
        Playing = false
        Paused = false
    end

    StopRecording()

    Route = {}
    RouteDuration = 0
    RecordClock = 0
    RecordStart = os.clock()
    Recording = true

    Capture()

    RecordConnection = RunService.Heartbeat:Connect(function(dt)
        if not Recording then return end

        RecordClock += dt

        if RecordClock >= Config.SampleInterval then
            RecordClock = 0
            Capture()
        end
    end)
end

--========================================================--
-- Centripetal Catmull-Rom
--========================================================--

local function Knot(t, a, b, alpha)
    return t + math.pow(math.max((b-a).Magnitude, 0.0001), alpha)
end

local function CatmullRom(p0,p1,p2,p3,u,alpha,tension)
    local t0 = 0
    local t1 = Knot(t0,p0,p1,alpha)
    local t2 = Knot(t1,p1,p2,alpha)
    local t3 = Knot(t2,p2,p3,alpha)

    local t = t1 + (t2-t1) * clamp(u,0,1)

    local A1 = p0:Lerp(p1,(t-t0)/math.max(t1-t0,0.0001))
    local A2 = p1:Lerp(p2,(t-t1)/math.max(t2-t1,0.0001))
    local A3 = p2:Lerp(p3,(t-t2)/math.max(t3-t2,0.0001))

    local B1 = A1:Lerp(A2,(t-t0)/math.max(t2-t0,0.0001))
    local B2 = A2:Lerp(A3,(t-t1)/math.max(t3-t1,0.0001))

    local curve = B1:Lerp(B2,(t-t1)/math.max(t2-t1,0.0001))
    local linear = p1:Lerp(p2,u)

    return curve:Lerp(linear,clamp(tension,-1,1)*0.5)
end

local function GetSegment(time)
    local n = #Route

    if n <= 1 then
        return 1,0
    end

    if time <= Route[1].Time then
        return 1,0
    end

    if time >= Route[n].Time then
        return n-1,1
    end

    local low, high = 1, n-1

    while low <= high do
        local mid = math.floor((low+high)/2)
        local a = Route[mid].Time
        local b = Route[mid+1].Time

        if time >= a and time <= b then
            return mid, (time-a)/math.max(b-a,0.000001)
        elseif time < a then
            high = mid-1
        else
            low = mid+1
        end
    end

    return clamp(low,1,n-1),0
end

local function Sample(time)
    if #Route == 0 then return nil end
    if #Route == 1 then return ArrayToCFrame(Route[1].CFrame) end

    local i,u = GetSegment(time)

    local i0 = math.max(1,i-1)
    local i1 = i
    local i2 = math.min(#Route,i+1)
    local i3 = math.min(#Route,i+2)

    local p0 = ArrayToCFrame(Route[i0].CFrame).Position
    local p1 = ArrayToCFrame(Route[i1].CFrame).Position
    local p2 = ArrayToCFrame(Route[i2].CFrame).Position
    local p3 = ArrayToCFrame(Route[i3].CFrame).Position

    local curve = CatmullRom(
        p0,p1,p2,p3,
        u,
        0.5,
        Config.Tension
    )

    local linear = p1:Lerp(p2,u)
    local position = linear:Lerp(curve,Config.Smoothness)

    local rotation =
        ArrayToCFrame(Route[i1].CFrame)
        :Lerp(ArrayToCFrame(Route[i2].CFrame),u)
        .Rotation

    return CFrame.new(position) * rotation
end

--========================================================--
-- Playback
--========================================================--

local function StopPlayback()
    if PlayConnection then
        PlayConnection:Disconnect()
        PlayConnection = nil
    end

    Playing = false
end

local function MoveTo(cf)
    local c = Character()

    if not c or not Root() then
        return
    end

    c:PivotTo(cf)
end

local function ApplyState(point)
    local h = Humanoid()
    if not h or not point then return end

    if point.State == "Jumping" then
        pcall(function() h.Jump = true end)
    elseif point.State == "Freefall" then
        pcall(function()
            h:ChangeState(Enum.HumanoidStateType.Freefall)
        end)
    elseif point.State == "Landed" then
        pcall(function()
            h:ChangeState(Enum.HumanoidStateType.Landed)
        end)
    end
end

local function StartPlayback()
    StopPlayback()

    if #Route < 2 then
        return false
    end

    RecalculateDuration()

    if RouteDuration <= 0 then
        return false
    end

    Playing = true
    Paused = false
    PlayTime = 0

    PlayConnection = RunService.RenderStepped:Connect(function(dt)
        if not Playing or Paused then return end

        PlayTime += dt * Config.PlaybackSpeed

        if PlayTime >= RouteDuration then
            if Config.Loop then
                PlayTime = PlayTime % RouteDuration
            else
                PlayTime = RouteDuration
            end
        end

        local i,u = GetSegment(PlayTime)
        local cf = Sample(PlayTime)

        if cf then
            MoveTo(cf)
        end

        if u < 0.05 then
            ApplyState(Route[i])
        end

        if not Config.Loop and PlayTime >= RouteDuration then
            StopPlayback()
        end
    end)

    return true
end

local function PausePlayback()
    if Playing then
        Paused = true
    end
end

local function ResumePlayback()
    if Playing then
        Paused = false
    end
end

--========================================================--
-- Preview
--========================================================--

local function ClearPreview()
    if PreviewFolder then
        PreviewFolder:Destroy()
        PreviewFolder = nil
    end
end

local function PreviewRoute()
    ClearPreview()

    if #Route < 2 then return false end

    local folder = Instance.new("Folder")
    folder.Name = "RebootUltraSmoothPreview"
    folder.Parent = workspace
    PreviewFolder = folder

    local previous

    for t = 0,RouteDuration,0.06 do
        local cf = Sample(t)
        if cf then
            local part = Instance.new("Part")
            part.Anchored = true
            part.CanCollide = false
            part.CanTouch = false
            part.CanQuery = false
            part.Transparency = 1
            part.Size = Vector3.new(.12,.12,.12)
            part.CFrame = cf
            part.Parent = folder

            local attachment = Instance.new("Attachment")
            attachment.Parent = part

            if previous then
                local beam = Instance.new("Beam")
                beam.Attachment0 = previous
                beam.Attachment1 = attachment
                beam.Width0 = .035
                beam.Width1 = .035
                beam.FaceCamera = true
                beam.LightEmission = 1
                beam.Color = ColorSequence.new(
                    Color3.fromRGB(255,170,60)
                )
                beam.Parent = folder
            end

            previous = attachment
        end
    end

    return true
end

--========================================================--
-- Optimize
--========================================================--

local function OptimizeRoute(minDistance)
    minDistance = math.max(tonumber(minDistance) or .08,.001)

    if #Route < 3 then
        return
    end

    local result = {Route[1]}

    for i = 2,#Route-1 do
        local previous = result[#result]

        local a = ArrayToCFrame(previous.CFrame).Position
        local b = ArrayToCFrame(Route[i].CFrame).Position
        local c = ArrayToCFrame(Route[i+1].CFrame).Position

        if (b-a).Magnitude >= minDistance
            or (c-b).Magnitude >= minDistance
            or Route[i].State ~= previous.State then
            result[#result+1] = Route[i]
        end
    end

    result[#result+1] = Route[#Route]
    Route = result
    RecalculateDuration()
end

--========================================================--
-- Export / Import
--========================================================--

local function ExportRoute()
    local payload = {
        Version = 4,
        Name = "Reboot UltraSmooth Route",
        Settings = {
            SampleInterval = Config.SampleInterval,
            PlaybackSpeed = Config.PlaybackSpeed,
            Smoothness = Config.Smoothness,
            Tension = Config.Tension,
            Loop = Config.Loop,
        },
        Points = Route
    }

    for _,point in ipairs(payload.Points) do
        point._absolute = nil
    end

    local ok,result = pcall(function()
        return HttpService:JSONEncode(payload)
    end)

    if not ok then
        return nil,result
    end

    return result
end

local function ImportRoute(json)
    local ok,payload = pcall(function()
        return HttpService:JSONDecode(json)
    end)

    if not ok or type(payload) ~= "table" or type(payload.Points) ~= "table" then
        return false,"Invalid route JSON."
    end

    local result = {}

    for _,point in ipairs(payload.Points) do
        if type(point) == "table"
            and type(point.Time) == "number"
            and type(point.CFrame) == "table"
            and #point.CFrame >= 12 then

            result[#result+1] = {
                Time = point.Time,
                CFrame = point.CFrame,
                State = point.State or "None",
                Velocity = point.Velocity or {0,0,0}
            }
        end
    end

    if #result == 0 then
        return false,"No valid route points."
    end

    StopRecording()
    StopPlayback()
    ClearPreview()

    Route = result

    if payload.Settings then
        Config.SampleInterval = clamp(
            tonumber(payload.Settings.SampleInterval) or Config.SampleInterval,
            .01,.5
        )
        Config.PlaybackSpeed = clamp(
            tonumber(payload.Settings.PlaybackSpeed) or Config.PlaybackSpeed,
            .05,5
        )
        Config.Smoothness = clamp(
            tonumber(payload.Settings.Smoothness) or Config.Smoothness,
            0,1
        )
        Config.Tension = clamp(
            tonumber(payload.Settings.Tension) or Config.Tension,
            -1,1
        )
        Config.Loop = payload.Settings.Loop == true
    end

    RecalculateDuration()
    return true
end

--========================================================--
-- Rayfield UI
--========================================================--

local Window = Rayfield:CreateWindow({
    Name = "Reboot UltraSmooth",
    LoadingTitle = "Reboot",
    LoadingSubtitle = "UltraSmooth Recorder",
    ConfigurationSaving = {
        Enabled = false,
    },
    Discord = {
        Enabled = false,
    },
    KeySystem = false,
})

local Home = Window:CreateTab("Home", "house")
local RecorderTab = Window:CreateTab("Recorder", "circle-dot")
local PlaybackTab = Window:CreateTab("Playback", "play")
local SmoothTab = Window:CreateTab("Smoothing", "waves")
local RoutesTab = Window:CreateTab("Routes", "folder")

Home:CreateSection("Route Status")

local statusLabel = Home:CreateLabel("Ready • 0 points • 0.00s")

local function UpdateStatus()
    local mode = Recording and "Recording"
        or (Playing and (Paused and "Paused" or "Playing"))
        or "Ready"

    statusLabel:Set(
        string.format(
            "%s • %d points • %.2fs",
            mode,#Route,RouteDuration
        )
    )
end

Home:CreateButton({
    Name = "Clear Everything",
    Callback = function()
        StopRecording()
        StopPlayback()
        ClearPreview()
        Route = {}
        RouteDuration = 0
        PlayTime = 0
        UpdateStatus()
    end
})

RecorderTab:CreateSection("Recording")

RecorderTab:CreateButton({
    Name = "Start Recording",
    Callback = function()
        StartRecording()
        UpdateStatus()
    end
})

RecorderTab:CreateButton({
    Name = "Stop Recording",
    Callback = function()
        StopRecording()
        UpdateStatus()
    end
})

RecorderTab:CreateButton({
    Name = "Optimize Route",
    Callback = function()
        OptimizeRoute(.08)
        UpdateStatus()
    end
})

RecorderTab:CreateButton({
    Name = "Clear Route",
    Callback = function()
        StopRecording()
        StopPlayback()
        Route = {}
        RouteDuration = 0
        UpdateStatus()
    end
})

PlaybackTab:CreateSection("Playback")

PlaybackTab:CreateButton({
    Name = "Play UltraSmooth",
    Callback = function()
        Config.PlaybackSpeed = clamp(Config.PlaybackSpeed,.05,5)
        StartPlayback()
        UpdateStatus()
    end
})

PlaybackTab:CreateButton({
    Name = "Pause",
    Callback = function()
        PausePlayback()
        UpdateStatus()
    end
})

PlaybackTab:CreateButton({
    Name = "Resume",
    Callback = function()
        ResumePlayback()
        UpdateStatus()
    end
})

PlaybackTab:CreateButton({
    Name = "Stop Playback",
    Callback = function()
        StopPlayback()
        UpdateStatus()
    end
})

PlaybackTab:CreateToggle({
    Name = "Loop Playback",
    CurrentValue = Config.Loop,
    Callback = function(value)
        Config.Loop = value
    end
})

PlaybackTab:CreateSlider({
    Name = "Playback Speed",
    Range = {0.05,5},
    Increment = 0.05,
    Suffix = "x",
    CurrentValue = Config.PlaybackSpeed,
    Callback = function(value)
        Config.PlaybackSpeed = value
    end
})

SmoothTab:CreateSection("Catmull-Rom")

SmoothTab:CreateSlider({
    Name = "Smoothness",
    Range = {0,1},
    Increment = 0.01,
    Suffix = "",
    CurrentValue = Config.Smoothness,
    Callback = function(value)
        Config.Smoothness = value
    end
})

SmoothTab:CreateSlider({
    Name = "Tension",
    Range = {-1,1},
    Increment = 0.01,
    Suffix = "",
    CurrentValue = Config.Tension,
    Callback = function(value)
        Config.Tension = value
    end
})

SmoothTab:CreateSlider({
    Name = "Sample Interval",
    Range = {0.01,0.2},
    Increment = 0.005,
    Suffix = "s",
    CurrentValue = Config.SampleInterval,
    Callback = function(value)
        Config.SampleInterval = value
    end
})

RoutesTab:CreateSection("Preview")

RoutesTab:CreateButton({
    Name = "Preview Smooth Route",
    Callback = function()
        PreviewRoute()
    end
})

RoutesTab:CreateButton({
    Name = "Clear Preview",
    Callback = function()
        ClearPreview()
    end
})

RoutesTab:CreateSection("JSON")

RoutesTab:CreateButton({
    Name = "Export Route",
    Callback = function()
        local data,err = ExportRoute()

        if data and setclipboard then
            setclipboard(data)
            Rayfield:Notify({
                Title = "Route Exported",
                Content = "JSON copied to clipboard.",
                Duration = 3
            })
        elseif data then
            Rayfield:Notify({
                Title = "Route Exported",
                Content = "JSON generated, but clipboard is unavailable.",
                Duration = 4
            })
        else
            Rayfield:Notify({
                Title = "Export Failed",
                Content = tostring(err),
                Duration = 4
            })
        end
    end
})

RoutesTab:CreateInput({
    Name = "Import JSON",
    PlaceholderText = "Paste route JSON here...",
    RemoveTextAfterFocusLost = false,
    Callback = function(text)
        local ok,err = ImportRoute(text)

        Rayfield:Notify({
            Title = ok and "Route Imported" or "Import Failed",
            Content = ok
                and string.format("%d points loaded.",#Route)
                or tostring(err),
            Duration = 3
        })

        UpdateStatus()
    end
})

task.spawn(function()
    while Window do
        UpdateStatus()
        task.wait(.25)
    end
end)

Rayfield:Notify({
    Title = "Reboot UltraSmooth",
    Content = "Recorder initialized successfully.",
    Duration = 4
})

UpdateStatus()

-- Return API too, while the UI is already running.
return {
    Route = Route,
    StartRecording = StartRecording,
    StopRecording = StopRecording,
    StartPlayback = StartPlayback,
    StopPlayback = StopPlayback,
    PreviewRoute = PreviewRoute,
    ExportRoute = ExportRoute,
    ImportRoute = ImportRoute,
    OptimizeRoute = OptimizeRoute,
    Config = Config
}
