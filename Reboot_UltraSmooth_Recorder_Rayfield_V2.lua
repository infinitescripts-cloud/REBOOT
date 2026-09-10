--========================================================--
-- REBOOT ULTRASMOOTH RECORDER • RAYFIELD
-- Standalone recorder with mobile-friendly Rayfield controls.
-- No KeyCode/keybind dependency.
--========================================================--

local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local Player = Players.LocalPlayer

local Config = {
    SampleInterval = 0.045,
    PlaybackSpeed = 1,
    Smoothness = 0.85,
    Tension = 0,
    Loop = false,
    PreviewStep = 0.06,
}

local Route = {}
local Recording = false
local Playing = false
local Paused = false
local RecordConnection
local PlaybackConnection
local PreviewFolder
local RecordStart = 0
local RecordClock = 0
local PlaybackTime = 0
local Duration = 0

local function clamp(v, a, b)
    return math.max(a, math.min(b, v))
end

local function character()
    return Player.Character
end

local function root()
    local c = character()
    return c and c:FindFirstChild("HumanoidRootPart")
end

local function humanoid()
    local c = character()
    return c and c:FindFirstChildOfClass("Humanoid")
end

local function stateName()
    local h = humanoid()
    if not h then return "None" end
    local ok, state = pcall(function()
        return h:GetState()
    end)
    return ok and state.Name or "None"
end

local function toArray(cf)
    local x,y,z,r00,r01,r02,r10,r11,r12,r20,r21,r22 = cf:GetComponents()
    return {x,y,z,r00,r01,r02,r10,r11,r12,r20,r21,r22}
end

local function fromArray(a)
    return CFrame.new(
        a[1],a[2],a[3],
        a[4],a[5],a[6],
        a[7],a[8],a[9],
        a[10],a[11],a[12]
    )
end

local function recalcDuration()
    Duration = Route[#Route] and Route[#Route].Time or 0
end

local function capture()
    local r = root()
    if not r then return end

    local now = os.clock()
    local previous = Route[#Route]

    if previous and now - previous._absolute < Config.SampleInterval then
        return
    end

    local point = {
        Time = now - RecordStart,
        CFrame = toArray(r.CFrame),
        State = stateName(),
        Velocity = {
            r.AssemblyLinearVelocity.X,
            r.AssemblyLinearVelocity.Y,
            r.AssemblyLinearVelocity.Z
        },
        _absolute = now
    }

    if previous then
        local old = fromArray(previous.CFrame)
        local movement = (old.Position - r.Position).Magnitude

        if movement < 0.035
            and previous.State == point.State
            and now - previous._absolute < Config.SampleInterval * 1.75 then
            return
        end
    end

    Route[#Route + 1] = point
end

local function stopRecording()
    if RecordConnection then
        RecordConnection:Disconnect()
        RecordConnection = nil
    end

    Recording = false

    for _, point in ipairs(Route) do
        point._absolute = nil
    end

    recalcDuration()
end

local function stopPlayback()
    if PlaybackConnection then
        PlaybackConnection:Disconnect()
        PlaybackConnection = nil
    end

    Playing = false
    Paused = false
end

local function startRecording()
    stopPlayback()
    stopRecording()

    Route = {}
    Duration = 0
    RecordClock = 0
    RecordStart = os.clock()
    Recording = true

    capture()

    RecordConnection = RunService.Heartbeat:Connect(function(dt)
        if not Recording then return end

        RecordClock += dt

        if RecordClock >= Config.SampleInterval then
            RecordClock = 0
            capture()
        end
    end)
end

--========================================================--
-- Centripetal Catmull-Rom interpolation
--========================================================--

local function knot(t, a, b)
    return t + math.pow(math.max((b - a).Magnitude, 0.0001), 0.5)
end

local function catmullRom(p0, p1, p2, p3, u, tension)
    local t0 = 0
    local t1 = knot(t0, p0, p1)
    local t2 = knot(t1, p1, p2)
    local t3 = knot(t2, p2, p3)

    local t = t1 + (t2 - t1) * u

    local a1 = p0:Lerp(p1, (t-t0)/math.max(t1-t0,0.0001))
    local a2 = p1:Lerp(p2, (t-t1)/math.max(t2-t1,0.0001))
    local a3 = p2:Lerp(p3, (t-t2)/math.max(t3-t2,0.0001))

    local b1 = a1:Lerp(a2, (t-t0)/math.max(t2-t0,0.0001))
    local b2 = a2:Lerp(a3, (t-t1)/math.max(t3-t1,0.0001))

    local curve = b1:Lerp(b2, (t-t1)/math.max(t2-t1,0.0001))
    local linear = p1:Lerp(p2, u)

    return curve:Lerp(linear, clamp(tension,-1,1) * 0.5)
end

local function getSegment(time)
    local n = #Route

    if n < 2 then return 1, 0 end
    if time <= Route[1].Time then return 1, 0 end
    if time >= Route[n].Time then return n-1, 1 end

    local low, high = 1, n-1

    while low <= high do
        local mid = math.floor((low + high) / 2)
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

    return clamp(low,1,n-1), 0
end

local function sample(time)
    if #Route == 0 then return nil end
    if #Route == 1 then return fromArray(Route[1].CFrame) end

    local i,u = getSegment(time)
    local n = #Route

    local p0 = fromArray(Route[math.max(1,i-1)].CFrame).Position
    local p1 = fromArray(Route[i].CFrame).Position
    local p2 = fromArray(Route[math.min(n,i+1)].CFrame).Position
    local p3 = fromArray(Route[math.min(n,i+2)].CFrame).Position

    local curve = catmullRom(p0,p1,p2,p3,u,Config.Tension)
    local position = p1:Lerp(p2,u):Lerp(curve,Config.Smoothness)

    local rotation =
        fromArray(Route[i].CFrame)
        :Lerp(fromArray(Route[i+1].CFrame),u)
        .Rotation

    return CFrame.new(position) * rotation
end

local function applyCFrame(cf)
    local c = character()
    if c and root() then
        c:PivotTo(cf)
    end
end

local function startPlayback()
    stopPlayback()
    recalcDuration()

    if #Route < 2 or Duration <= 0 then
        return false
    end

    Playing = true
    Paused = false
    PlaybackTime = 0

    PlaybackConnection = RunService.RenderStepped:Connect(function(dt)
        if not Playing or Paused then return end

        PlaybackTime += dt * Config.PlaybackSpeed

        if PlaybackTime >= Duration then
            if Config.Loop then
                PlaybackTime = PlaybackTime % Duration
            else
                PlaybackTime = Duration
            end
        end

        local cf = sample(PlaybackTime)

        if cf then
            applyCFrame(cf)
        end

        if not Config.Loop and PlaybackTime >= Duration then
            stopPlayback()
        end
    end)

    return true
end

local function pausePlayback()
    if Playing then
        Paused = true
    end
end

local function resumePlayback()
    if Playing then
        Paused = false
    end
end

--========================================================--
-- Route utilities
--========================================================--

local function clearPreview()
    if PreviewFolder then
        PreviewFolder:Destroy()
        PreviewFolder = nil
    end
end

local function previewRoute()
    clearPreview()

    if #Route < 2 then return false end

    PreviewFolder = Instance.new("Folder")
    PreviewFolder.Name = "RebootUltraSmoothPreview"
    PreviewFolder.Parent = workspace

    local previousAttachment

    for t = 0, Duration, Config.PreviewStep do
        local cf = sample(t)

        if cf then
            local part = Instance.new("Part")
            part.Anchored = true
            part.CanCollide = false
            part.CanTouch = false
            part.CanQuery = false
            part.Transparency = 1
            part.Size = Vector3.new(.1,.1,.1)
            part.CFrame = cf
            part.Parent = PreviewFolder

            local attachment = Instance.new("Attachment")
            attachment.Parent = part

            if previousAttachment then
                local beam = Instance.new("Beam")
                beam.Attachment0 = previousAttachment
                beam.Attachment1 = attachment
                beam.Width0 = .035
                beam.Width1 = .035
                beam.FaceCamera = true
                beam.LightEmission = 1
                beam.Color = ColorSequence.new(
                    Color3.fromRGB(255,170,60)
                )
                beam.Parent = PreviewFolder
            end

            previousAttachment = attachment
        end
    end

    return true
end

local function optimizeRoute(minDistance)
    minDistance = minDistance or 0.08

    if #Route < 3 then return end

    local result = {Route[1]}

    for i = 2, #Route-1 do
        local previous = result[#result]

        local a = fromArray(previous.CFrame).Position
        local b = fromArray(Route[i].CFrame).Position
        local c = fromArray(Route[i+1].CFrame).Position

        if (b-a).Magnitude >= minDistance
            or (c-b).Magnitude >= minDistance
            or Route[i].State ~= previous.State then
            result[#result+1] = Route[i]
        end
    end

    result[#result+1] = Route[#Route]
    Route = result
    recalcDuration()
end

local function exportRoute()
    local payload = {
        Version = 2,
        Name = "Reboot UltraSmooth Route",
        Settings = {
            SampleInterval = Config.SampleInterval,
            PlaybackSpeed = Config.PlaybackSpeed,
            Smoothness = Config.Smoothness,
            Tension = Config.Tension,
            Loop = Config.Loop,
            PreviewStep = Config.PreviewStep,
        },
        Points = Route,
    }

    for _, point in ipairs(payload.Points) do
        point._absolute = nil
    end

    return pcall(function()
        return HttpService:JSONEncode(payload)
    end)
end

local function importRoute(text)
    local ok, payload = pcall(function()
        return HttpService:JSONDecode(text)
    end)

    if not ok or type(payload) ~= "table" or type(payload.Points) ~= "table" then
        return false, "Invalid JSON."
    end

    local result = {}

    for _, point in ipairs(payload.Points) do
        if type(point) == "table"
            and type(point.Time) == "number"
            and type(point.CFrame) == "table"
            and #point.CFrame >= 12 then

            result[#result+1] = {
                Time = point.Time,
                CFrame = point.CFrame,
                State = point.State or "None",
                Velocity = point.Velocity or {0,0,0},
            }
        end
    end

    if #result < 1 then
        return false, "No valid points."
    end

    stopRecording()
    stopPlayback()
    clearPreview()

    Route = result
    recalcDuration()

    if payload.Settings then
        Config.SampleInterval = clamp(
            tonumber(payload.Settings.SampleInterval) or Config.SampleInterval,
            .01,.2
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
        Config.PreviewStep = clamp(
            tonumber(payload.Settings.PreviewStep) or Config.PreviewStep,
            .02,.25
        )
    end

    return true
end

--========================================================--
-- Rayfield
-- Use documented CreateTab(title, image) form.
--========================================================--

local Window = Rayfield:CreateWindow({
    Name = "Reboot UltraSmooth",
    Icon = "waves",
    LoadingTitle = "Reboot",
    LoadingSubtitle = "UltraSmooth Recorder",
    Theme = "Default",
    ConfigurationSaving = {
        Enabled = false,
    },
    Discord = {
        Enabled = false,
    },
    KeySystem = false,
})

-- Numeric image IDs are used for maximum compatibility with the
-- documented CreateTab(title, image) signature.
local Home = Window:CreateTab("Home", 4483362458)
local RecorderTab = Window:CreateTab("Recorder", 4483362458)
local PlaybackTab = Window:CreateTab("Playback", 4483362458)
local SmoothTab = Window:CreateTab("Smoothing", 4483362458)
local PreviewTab = Window:CreateTab("Preview", 4483362458)
local RoutesTab = Window:CreateTab("Routes", 4483362458)

--========================================================--
-- Home
--========================================================--

Home:CreateSection("Status")

local status = Home:CreateParagraph({
    Title = "READY",
    Content = "0 points • 0.00 seconds",
})

local function updateStatus()
    local mode

    if Recording then
        mode = "RECORDING"
    elseif Playing and Paused then
        mode = "PAUSED"
    elseif Playing then
        mode = "PLAYING"
    else
        mode = "READY"
    end

    status:Set({
        Title = mode,
        Content = string.format(
            "%d points • %.2f seconds",
            #Route,
            Duration
        ),
    })
end

Home:CreateSection("Quick Actions")

Home:CreateButton({
    Name = "Start Recording",
    Callback = function()
        startRecording()
        updateStatus()
    end,
})

Home:CreateButton({
    Name = "Stop Recording",
    Callback = function()
        stopRecording()
        updateStatus()
    end,
})

Home:CreateButton({
    Name = "Play UltraSmooth",
    Callback = function()
        if not startPlayback() then
            Rayfield:Notify({
                Title = "Reboot Recorder",
                Content = "Record or import a route first.",
                Duration = 3,
            })
        end
        updateStatus()
    end,
})

--========================================================--
-- Recorder
--========================================================--

RecorderTab:CreateSection("Recording Controls")

RecorderTab:CreateButton({
    Name = "Start Recording",
    Callback = function()
        startRecording()
        Rayfield:Notify({
            Title = "Recorder",
            Content = "Recording started.",
            Duration = 2,
        })
        updateStatus()
    end,
})

RecorderTab:CreateButton({
    Name = "Stop Recording",
    Callback = function()
        stopRecording()
        Rayfield:Notify({
            Title = "Recorder",
            Content = string.format("%d points captured.",#Route),
            Duration = 3,
        })
        updateStatus()
    end,
})

RecorderTab:CreateButton({
    Name = "Clear Route",
    Callback = function()
        stopRecording()
        stopPlayback()
        clearPreview()
        Route = {}
        Duration = 0
        updateStatus()
    end,
})

RecorderTab:CreateSection("Sampling")

RecorderTab:CreateSlider({
    Name = "Sample Interval",
    Range = {0.01,0.2},
    Increment = 0.005,
    Suffix = "s",
    CurrentValue = Config.SampleInterval,
    Flag = "RecorderSampleInterval",
    Callback = function(value)
        Config.SampleInterval = value
    end,
})

RecorderTab:CreateParagraph({
    Title = "Adaptive Capture",
    Content = "Near-identical frames are automatically skipped to keep routes smooth and compact.",
})

--========================================================--
-- Playback
--========================================================--

PlaybackTab:CreateSection("Controls")

PlaybackTab:CreateButton({
    Name = "Play UltraSmooth",
    Callback = function()
        if not startPlayback() then
            Rayfield:Notify({
                Title = "Playback",
                Content = "You need at least two route points.",
                Duration = 3,
            })
        end
        updateStatus()
    end,
})

PlaybackTab:CreateButton({
    Name = "Pause",
    Callback = function()
        pausePlayback()
        updateStatus()
    end,
})

PlaybackTab:CreateButton({
    Name = "Resume",
    Callback = function()
        resumePlayback()
        updateStatus()
    end,
})

PlaybackTab:CreateButton({
    Name = "Stop",
    Callback = function()
        stopPlayback()
        updateStatus()
    end,
})

PlaybackTab:CreateToggle({
    Name = "Loop Playback",
    CurrentValue = Config.Loop,
    Flag = "RecorderLoop",
    Callback = function(value)
        Config.Loop = value
    end,
})

PlaybackTab:CreateSlider({
    Name = "Playback Speed",
    Range = {0.05,5},
    Increment = 0.05,
    Suffix = "x",
    CurrentValue = Config.PlaybackSpeed,
    Flag = "RecorderPlaybackSpeed",
    Callback = function(value)
        Config.PlaybackSpeed = value
    end,
})

PlaybackTab:CreateParagraph({
    Title = "Interpolation",
    Content = "Playback uses centripetal Catmull–Rom position interpolation with smooth rotation blending.",
})

--========================================================--
-- Smoothing
--========================================================--

SmoothTab:CreateSection("Catmull–Rom")

SmoothTab:CreateSlider({
    Name = "Smoothness",
    Range = {0,1},
    Increment = 0.01,
    CurrentValue = Config.Smoothness,
    Flag = "RecorderSmoothness",
    Callback = function(value)
        Config.Smoothness = value
    end,
})

SmoothTab:CreateSlider({
    Name = "Tension",
    Range = {-1,1},
    Increment = 0.01,
    CurrentValue = Config.Tension,
    Flag = "RecorderTension",
    Callback = function(value)
        Config.Tension = value
    end,
})

SmoothTab:CreateDropdown({
    Name = "Smoothness Preset",
    Options = {"Balanced","Soft","Sharp","Raw"},
    CurrentOption = {"Balanced"},
    MultipleOptions = false,
    Flag = "RecorderSmoothPreset",
    Callback = function(option)
        local selected = option[1]

        if selected == "Balanced" then
            Config.Smoothness = 0.85
            Config.Tension = 0
        elseif selected == "Soft" then
            Config.Smoothness = 1
            Config.Tension = -0.2
        elseif selected == "Sharp" then
            Config.Smoothness = 0.65
            Config.Tension = 0.25
        elseif selected == "Raw" then
            Config.Smoothness = 0
            Config.Tension = 0
        end
    end,
})

SmoothTab:CreateParagraph({
    Title = "Centripetal Mode",
    Content = "α = 0.5 is used to reduce overshoot and produce a smoother path around uneven waypoint spacing.",
})

--========================================================--
-- Preview
--========================================================--

PreviewTab:CreateSection("Route Preview")

PreviewTab:CreateButton({
    Name = "Generate Smooth Preview",
    Callback = function()
        if previewRoute() then
            Rayfield:Notify({
                Title = "Preview",
                Content = "Smooth route preview generated.",
                Duration = 3,
            })
        else
            Rayfield:Notify({
                Title = "Preview",
                Content = "Record or import a route first.",
                Duration = 3,
            })
        end
    end,
})

PreviewTab:CreateButton({
    Name = "Clear Preview",
    Callback = function()
        clearPreview()
    end,
})

PreviewTab:CreateSlider({
    Name = "Preview Density",
    Range = {0.02,0.25},
    Increment = 0.01,
    Suffix = "s",
    CurrentValue = Config.PreviewStep,
    Flag = "RecorderPreviewDensity",
    Callback = function(value)
        Config.PreviewStep = value
    end,
})

--========================================================--
-- Routes
--========================================================--

RoutesTab:CreateSection("Route Tools")

RoutesTab:CreateButton({
    Name = "Optimize Route",
    Callback = function()
        optimizeRoute(0.08)
        updateStatus()
    end,
})

RoutesTab:CreateButton({
    Name = "Clear Route",
    Callback = function()
        stopRecording()
        stopPlayback()
        Route = {}
        Duration = 0
        updateStatus()
    end,
})

RoutesTab:CreateSection("JSON")

RoutesTab:CreateButton({
    Name = "Export Route",
    Callback = function()
        local ok, data = exportRoute()

        if ok and setclipboard then
            setclipboard(data)

            Rayfield:Notify({
                Title = "Route Exported",
                Content = "JSON copied to clipboard.",
                Duration = 3,
            })
        elseif ok then
            Rayfield:Notify({
                Title = "Route Exported",
                Content = "JSON generated, but clipboard is unavailable.",
                Duration = 3,
            })
        else
            Rayfield:Notify({
                Title = "Export Failed",
                Content = tostring(data),
                Duration = 3,
            })
        end
    end,
})

RoutesTab:CreateInput({
    Name = "Import JSON",
    PlaceholderText = "Paste route JSON here...",
    RemoveTextAfterFocusLost = false,
    Flag = "RecorderImportJSON",
    Callback = function(text)
        local ok, err = importRoute(text)

        Rayfield:Notify({
            Title = ok and "Route Imported" or "Import Failed",
            Content = ok
                and string.format("%d points loaded.",#Route)
                or tostring(err),
            Duration = 3,
        })

        updateStatus()
    end,
})

RoutesTab:CreateParagraph({
    Title = "Route Format",
    Content = "Reboot UltraSmooth JSON stores timestamps, CFrames, movement state, velocity, and recorder settings.",
})

-- Keep the status card current.
task.spawn(function()
    while true do
        updateStatus()
        task.wait(0.25)
    end
end)

Rayfield:Notify({
    Title = "Reboot UltraSmooth",
    Content = "Recorder loaded with 6 tabs.",
    Duration = 3,
})

updateStatus()
