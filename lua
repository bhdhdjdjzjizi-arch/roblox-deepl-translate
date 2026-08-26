local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")
local Camera = workspace.CurrentCamera

local LocalPlayer = Players.LocalPlayer

-- ============================================================
-- 状态管理 & 配置读取
-- ============================================================
local CONFIG = {
    API_URL = "http://103.72.62.109:65312", 
    -- 已经为你填入官方 DeepL 密钥
    DEEPL_API_KEY = "6a39df48-fd87-4f1b-8fa2-2f30e2aa4742:fx", 
    NETWORK_COMPAT_MODE = false 
}

local UI_STATE = {
    Minimized = false,
    UnreadCount = 0,
    TargetLangCode = "en" 
}

-- UI 显示的语言映射不变
local LANG_MAP = {
    ["EN"] = {name = "English", code = "en"},
    ["JA"] = {name = "日语 (Japanese)", code = "ja"},
    ["KO"] = {name = "韩语 (Korean)", code = "ko"},
    ["ES"] = {name = "西班牙语 (Spanish)", code = "es"},
    ["RU"] = {name = "俄语 (Russian)", code = "ru"}
}

-- 更换配置名以强制加载带密钥的新配置
local configFileName = "PublicChatTranslator_DeepL_v2.json"
local function loadConfig()
    if isfile and isfile(configFileName) and readfile then
        pcall(function()
            local saved = HttpService:JSONDecode(readfile(configFileName))
            if saved.API_URL then CONFIG.API_URL = saved.API_URL end
            if saved.DEEPL_API_KEY then CONFIG.DEEPL_API_KEY = saved.DEEPL_API_KEY end
            if saved.NETWORK_COMPAT_MODE ~= nil then CONFIG.NETWORK_COMPAT_MODE = saved.NETWORK_COMPAT_MODE end
        end)
    end
end
local function saveConfig()
    if writefile then pcall(function() writefile(configFileName, HttpService:JSONEncode(CONFIG)) end) end
end
loadConfig()

local httpRequest = (syn and syn.request) or (http and http.request) or http_request or (fluxus and fluxus.request) or request
if not httpRequest then warn("你的执行器不支持 HTTP 请求 (request)！") end

local function containsChinese(str)
    for _, c in utf8.codes(str) do
        if c >= 0x4E00 and c <= 0x9FFF then return true end
    end
    return false
end

local function isMeaningfulToTranslate(str)
    for _, c in utf8.codes(str) do
        if (c >= 65 and c <= 90) or 
           (c >= 97 and c <= 122) or
           (c >= 0x00C0 and c <= 0x1FFF) or 
           (c >= 0x3040 and c <= 0x9FFF) or
           (c >= 0xAC00 and c <= 0xD7AF) then
            return true 
        end
    end
    return false
end

local function sendRealChatMessage(message)
    pcall(function()
        local channel = TextChatService.TextChannels:FindFirstChild("RBXGeneral")
        if channel then
            channel:SendAsync(message)
        else
            local legacyChat = ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
            if legacyChat then
                legacyChat.SayMessageRequest:FireServer(message, "All")
            end
        end
    end)
end

-- ============================================================
-- 严格按照 DeepL 官方 API 文档重写网络请求
-- ============================================================
local function callPublicTranslateAPI(text, targetLang, callback)
    if not httpRequest then return callback(false, "不支持HTTP请求") end
    
    local baseUrl = CONFIG.API_URL
    if string.sub(baseUrl, -1) == "/" then
        baseUrl = string.sub(baseUrl, 1, -2)
    end
    
    -- DeepL 端点
    local url = baseUrl .. "/v2/translate"
    
    -- 【关键修复】DeepL 官方要求：代码必须大写；中文只能用 ZH；英语必须区分 US/GB
    local dlTarget = string.upper(targetLang)
    if dlTarget == "ZH-CN" then dlTarget = "ZH" end
    if dlTarget == "EN" then dlTarget = "EN-US" end 

    local success, result = pcall(function()
        local reqHeaders = {
            ["Authorization"] = "DeepL-Auth-Key " .. CONFIG.DEEPL_API_KEY,
            ["Content-Type"] = "application/json"
        }
        
        if CONFIG.NETWORK_COMPAT_MODE then
            reqHeaders["User-Agent"] = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
        end
        
        -- DeepL 官方要求：text 必须是 Array (数组) 格式
        local requestData = {
            text = { text },
            target_lang = dlTarget
        }
        
        local response = httpRequest({
            Url = url, 
            Method = "POST",
            Headers = reqHeaders,
            Body = HttpService:JSONEncode(requestData)
        })
        
        if response.StatusCode == 200 then
            local data = HttpService:JSONDecode(response.Body)
            -- 解析 DeepL 官方响应格式 {"translations": [{"text": "结果"}]}
            if data and data.translations and data.translations[1] then
                return data.translations[1].text
            else
                error("DeepL 返回格式异常")
            end
        else
            error("HTTP " .. tostring(response.StatusCode) .. " API Key/网络错误")
        end
    end)
    
    if success and result ~= "" then 
        callback(true, result) 
    else 
        callback(false, tostring(result)) 
    end
end

-- ============================================================
-- UI 彻底重构 (原封不动保留)
-- ============================================================
local function createUI()
    local oldGui = LocalPlayer.PlayerGui:FindFirstChild("AppleTranslatorHelper")
    if oldGui then oldGui:Destroy() end

    local ScreenGui = Instance.new("ScreenGui")
    ScreenGui.Name = "AppleTranslatorHelper"
    ScreenGui.ResetOnSpawn = false
    ScreenGui.IgnoreGuiInset = true 
    ScreenGui.DisplayOrder = 999999999 
    ScreenGui.Parent = LocalPlayer.PlayerGui

    local EXPANDED_SIZE = UDim2.new(0, 320, 0, 240)
    local MINIMIZED_SIZE = UDim2.new(0, 40, 0, 40)

    -- 主容器
    local MainFrame = Instance.new("Frame")
    MainFrame.Size = EXPANDED_SIZE
    MainFrame.AnchorPoint = Vector2.new(0, 0)
    MainFrame.Position = UDim2.new(0, 20, 0, 100) 
    MainFrame.BackgroundColor3 = Color3.fromRGB(28, 28, 30)
    MainFrame.BackgroundTransparency = 0.25 
    MainFrame.ClipsDescendants = false 
    MainFrame.Active = true 
    MainFrame.Parent = ScreenGui
    
    Instance.new("UICorner", MainFrame).CornerRadius = UDim.new(0, 10)
    local Stroke = Instance.new("UIStroke")
    Stroke.Color = Color3.fromRGB(255, 255, 255)
    Stroke.Transparency = 0.85
    Stroke.Thickness = 1
    Stroke.Parent = MainFrame

    -- 防穿透绝缘垫
    local ClickBlocker = Instance.new("TextButton")
    ClickBlocker.Size = UDim2.new(1, 0, 1, 0)
    ClickBlocker.BackgroundTransparency = 1
    ClickBlocker.Text = ""
    ClickBlocker.AutoButtonColor = false
    ClickBlocker.ZIndex = 0
    ClickBlocker.Parent = MainFrame

    -- 裁切遮罩层
    local ClipFrame = Instance.new("Frame")
    ClipFrame.Size = UDim2.new(1, 0, 1, 0)
    ClipFrame.BackgroundTransparency = 1
    ClipFrame.ClipsDescendants = true
    ClipFrame.Parent = MainFrame
    Instance.new("UICorner", ClipFrame).CornerRadius = UDim.new(0, 10)

    -- 关闭按钮
    local CloseBtn = Instance.new("TextButton")
    CloseBtn.Size = UDim2.new(0, 40, 0, 40)
    CloseBtn.Position = UDim2.new(1, -40, 0, 0)
    CloseBtn.BackgroundTransparency = 1
    CloseBtn.Text = "×"
    CloseBtn.TextColor3 = Color3.fromRGB(255, 69, 58) 
    CloseBtn.Font = Enum.Font.GothamBold
    CloseBtn.TextSize = 22
    CloseBtn.ZIndex = 50
    CloseBtn.Parent = ClipFrame

    CloseBtn.MouseButton1Click:Connect(function()
        ScreenGui:Destroy() 
    end)

    -- 最小化时用于展开的按钮
    local ExpandBtn = Instance.new("TextButton")
    ExpandBtn.Size = UDim2.new(1, 0, 1, 0)
    ExpandBtn.BackgroundTransparency = 1
    ExpandBtn.Text = "💬"
    ExpandBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    ExpandBtn.Font = Enum.Font.GothamBold
    ExpandBtn.TextSize = 16
    ExpandBtn.Visible = false
    ExpandBtn.ZIndex = 60
    ExpandBtn.Parent = ClipFrame

    local UnreadBadge = Instance.new("Frame")
    UnreadBadge.Size = UDim2.new(0, 18, 0, 18)
    UnreadBadge.Position = UDim2.new(1, -14, 0, -4)
    UnreadBadge.BackgroundColor3 = Color3.fromRGB(255, 59, 48)
    UnreadBadge.Visible = false
    UnreadBadge.ZIndex = 61
    UnreadBadge.Parent = MainFrame 
    Instance.new("UICorner", UnreadBadge).CornerRadius = UDim.new(1, 0)

    local UnreadText = Instance.new("TextLabel")
    UnreadText.Size = UDim2.new(1, 0, 1, 0)
    UnreadText.BackgroundTransparency = 1
    UnreadText.Text = "0"
    UnreadText.TextColor3 = Color3.fromRGB(255, 255, 255)
    UnreadText.Font = Enum.Font.GothamBold
    UnreadText.TextSize = 10
    UnreadText.ZIndex = 62
    UnreadText.Parent = UnreadBadge

    local AbsoluteWrapper = Instance.new("Frame")
    AbsoluteWrapper.Size = EXPANDED_SIZE
    AbsoluteWrapper.BackgroundTransparency = 1
    AbsoluteWrapper.Parent = ClipFrame

    local TopBar = Instance.new("Frame")
    TopBar.Size = UDim2.new(1, 0, 0, 40)
    TopBar.BackgroundTransparency = 1
    TopBar.Parent = AbsoluteWrapper

    local TitleText = Instance.new("TextLabel")
    TitleText.Size = UDim2.new(1, -40, 1, 0) 
    TitleText.Position = UDim2.new(0, 14, 0, 0)
    TitleText.BackgroundTransparency = 1
    TitleText.Text = "免费同声传译器 (DeepL 代理版)"
    TitleText.TextColor3 = Color3.fromRGB(240, 240, 245)
    TitleText.Font = Enum.Font.GothamMedium
    TitleText.TextSize = 13
    TitleText.TextXAlignment = Enum.TextXAlignment.Left
    TitleText.Parent = TopBar

    local Divider = Instance.new("Frame")
    Divider.Size = UDim2.new(1, 0, 0, 1)
    Divider.Position = UDim2.new(0, 0, 0, 40)
    Divider.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    Divider.BackgroundTransparency = 0.9
    Divider.BorderSizePixel = 0
    Divider.Parent = AbsoluteWrapper

    local NavBar = Instance.new("Frame")
    NavBar.Size = UDim2.new(1, 0, 0, 30)
    NavBar.Position = UDim2.new(0, 0, 0, 41)
    NavBar.BackgroundTransparency = 1
    NavBar.Parent = AbsoluteWrapper

    local function createTab(icon, text, posX)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(0.5, 0, 1, 0)
        btn.Position = UDim2.new(posX, 0, 0, 0)
        btn.BackgroundTransparency = 1
        btn.Text = icon .. " " .. text
        btn.TextColor3 = Color3.fromRGB(150, 150, 155)
        btn.Font = Enum.Font.GothamBold
        btn.TextSize = 12
        btn.Parent = NavBar
        return btn
    end

    local TabChat = createTab("💬", "聊天翻译", 0)
    local TabSettings = createTab("⚙️", "通用设置", 0.5)

    local ContentFrame = Instance.new("Frame")
    ContentFrame.Size = UDim2.new(1, 0, 1, -71)
    ContentFrame.Position = UDim2.new(0, 0, 0, 71)
    ContentFrame.BackgroundTransparency = 1
    ContentFrame.Parent = AbsoluteWrapper

    local ViewChat = Instance.new("Frame")
    ViewChat.Size = UDim2.new(1, 0, 1, 0)
    ViewChat.BackgroundTransparency = 1
    ViewChat.Parent = ContentFrame

    local ChatScroll = Instance.new("ScrollingFrame")
    ChatScroll.Size = UDim2.new(1, -20, 1, -44)
    ChatScroll.Position = UDim2.new(0, 10, 0, 0)
    ChatScroll.BackgroundTransparency = 1
    ChatScroll.BorderSizePixel = 0
    ChatScroll.ScrollBarThickness = 2
    ChatScroll.Active = true 
    ChatScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    ChatScroll.Parent = ViewChat
    local ChatLayout = Instance.new("UIListLayout")
    ChatLayout.Padding = UDim.new(0, 4)
    ChatLayout.Parent = ChatScroll

    local InputArea = Instance.new("Frame")
    InputArea.Size = UDim2.new(1, -20, 0, 32)
    InputArea.Position = UDim2.new(0, 10, 1, -38)
    InputArea.BackgroundTransparency = 1
    InputArea.Parent = ViewChat

    local LangBtn = Instance.new("TextButton")
    LangBtn.Size = UDim2.new(0, 40, 1, 0)
    LangBtn.BackgroundColor3 = Color3.fromRGB(40, 40, 45)
    LangBtn.BackgroundTransparency = 0.5
    LangBtn.Text = "EN"
    LangBtn.TextColor3 = Color3.fromRGB(10, 132, 255)
    LangBtn.Font = Enum.Font.GothamBold
    LangBtn.TextSize = 12
    LangBtn.Parent = InputArea
    Instance.new("UICorner", LangBtn).CornerRadius = UDim.new(0, 6)

    local ChatBox = Instance.new("TextBox")
    ChatBox.Size = UDim2.new(1, -45, 1, 0)
    ChatBox.Position = UDim2.new(0, 45, 0, 0)
    ChatBox.BackgroundColor3 = Color3.fromRGB(40, 40, 45)
    ChatBox.BackgroundTransparency = 0.5
    ChatBox.PlaceholderText = "输入中文，回车翻译并发送..."
    ChatBox.Text = ""
    ChatBox.TextColor3 = Color3.fromRGB(255, 255, 255)
    ChatBox.Font = Enum.Font.Gotham
    ChatBox.TextSize = 11
    ChatBox.ClearTextOnFocus = false
    ChatBox.Parent = InputArea
    Instance.new("UICorner", ChatBox).CornerRadius = UDim.new(0, 6)

    local DropMenu = Instance.new("Frame")
    DropMenu.Size = UDim2.new(0, 100, 0, 150)
    DropMenu.Position = UDim2.new(0, 10, 1, -195) 
    DropMenu.BackgroundColor3 = Color3.fromRGB(35, 35, 40)
    DropMenu.Visible = false
    DropMenu.ZIndex = 10
    DropMenu.Parent = MainFrame 
    Instance.new("UICorner", DropMenu).CornerRadius = UDim.new(0, 8)
    local DropStroke = Instance.new("UIStroke")
    DropStroke.Color = Color3.fromRGB(100, 100, 105)
    DropStroke.Thickness = 1
    DropStroke.Parent = DropMenu

    local DropLayout = Instance.new("UIListLayout")
    DropLayout.Padding = UDim.new(0, 2)
    DropLayout.Parent = DropMenu

    for code, info in pairs(LANG_MAP) do
        local opt = Instance.new("TextButton")
        opt.Size = UDim2.new(1, 0, 0, 30)
        opt.BackgroundTransparency = 1
        opt.Text = " " .. code .. " - " .. info.name:match("^[^(]+")
        opt.TextColor3 = Color3.fromRGB(200, 200, 200)
        opt.Font = Enum.Font.Gotham
        opt.TextSize = 11
        opt.TextXAlignment = Enum.TextXAlignment.Left
        opt.ZIndex = 11
        opt.Parent = DropMenu
        
        opt.MouseButton1Click:Connect(function()
            UI_STATE.TargetLangCode = info.code
            LangBtn.Text = code
            DropMenu.Visible = false
        end)
    end

    LangBtn.MouseButton1Click:Connect(function() DropMenu.Visible = not DropMenu.Visible end)

    local ViewSettings = Instance.new("ScrollingFrame")
    ViewSettings.Size = UDim2.new(1, -20, 1, -10)
    ViewSettings.Position = UDim2.new(0, 10, 0, 0)
    ViewSettings.BackgroundTransparency = 1
    ViewSettings.Visible = false
    ViewSettings.ScrollBarThickness = 2
    ViewSettings.Active = true 
    ViewSettings.AutomaticCanvasSize = Enum.AutomaticSize.Y
    ViewSettings.Parent = ContentFrame
    local SetLayout = Instance.new("UIListLayout")
    SetLayout.Padding = UDim.new(0, 6)
    SetLayout.Parent = ViewSettings

    local Tips = Instance.new("TextLabel")
    Tips.Size = UDim2.new(1, 0, 0, 20)
    Tips.BackgroundTransparency = 1
    Tips.Text = "正在使用您私有的 DeepL API 代理节点。"
    Tips.TextColor3 = Color3.fromRGB(180, 180, 185)
    Tips.Font = Enum.Font.Gotham
    Tips.TextSize = 11
    Tips.TextWrapped = true
    Tips.Parent = ViewSettings

    local function createInput(placeholder, text)
        local box = Instance.new("TextBox")
        box.Size = UDim2.new(1, 0, 0, 30)
        box.BackgroundColor3 = Color3.fromRGB(40, 40, 45)
        box.BackgroundTransparency = 0.5
        box.PlaceholderText = placeholder
        box.Text = text or ""
        box.TextColor3 = Color3.fromRGB(255, 255, 255)
        box.Font = Enum.Font.Gotham
        box.TextSize = 11
        box.ClearTextOnFocus = false
        box.Parent = ViewSettings
        Instance.new("UICorner", box).CornerRadius = UDim.new(0, 6)
        return box
    end

    local UrlInput = createInput("代理服务器地址(含端口)", CONFIG.API_URL)
    local KeyInput = createInput("DeepL API Key (必须填写)", CONFIG.DEEPL_API_KEY)

    local CompatBtn = Instance.new("TextButton")
    CompatBtn.Size = UDim2.new(1, 0, 0, 30)
    CompatBtn.BackgroundColor3 = Color3.fromRGB(40, 40, 45)
    CompatBtn.BackgroundTransparency = 0.5
    CompatBtn.Text = "改善网络兼容性: " .. (CONFIG.NETWORK_COMPAT_MODE and "已开启 ✅" or "已关闭 ❌")
    CompatBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    CompatBtn.Font = Enum.Font.Gotham
    CompatBtn.TextSize = 11
    CompatBtn.Parent = ViewSettings
    Instance.new("UICorner", CompatBtn).CornerRadius = UDim.new(0, 6)

    CompatBtn.MouseButton1Click:Connect(function()
        CONFIG.NETWORK_COMPAT_MODE = not CONFIG.NETWORK_COMPAT_MODE
        CompatBtn.Text = "改善网络兼容性: " .. (CONFIG.NETWORK_COMPAT_MODE and "已开启 ✅" or "已关闭 ❌")
    end)

    local SaveBtn = Instance.new("TextButton")
    SaveBtn.Size = UDim2.new(1, 0, 0, 30)
    SaveBtn.BackgroundColor3 = Color3.fromRGB(10, 132, 255)
    SaveBtn.Text = "保存设置"
    SaveBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    SaveBtn.Font = Enum.Font.GothamMedium
    SaveBtn.TextSize = 12
    SaveBtn.Parent = ViewSettings
    Instance.new("UICorner", SaveBtn).CornerRadius = UDim.new(0, 8)

    local function switchTab(tab)
        ViewChat.Visible = (tab == 1)
        ViewSettings.Visible = (tab == 2)
        DropMenu.Visible = false
        TabChat.TextColor3 = tab == 1 and Color3.fromRGB(255,255,255) or Color3.fromRGB(120,120,125)
        TabSettings.TextColor3 = tab == 2 and Color3.fromRGB(255,255,255) or Color3.fromRGB(120,120,125)
    end
    TabChat.MouseButton1Click:Connect(function() switchTab(1) end)
    TabSettings.MouseButton1Click:Connect(function() switchTab(2) end)
    switchTab(1)
    
    SaveBtn.MouseButton1Click:Connect(function()
        CONFIG.API_URL = UrlInput.Text
        CONFIG.DEEPL_API_KEY = KeyInput.Text
        saveConfig()
        SaveBtn.Text = "保存成功 ✓"
        SaveBtn.BackgroundColor3 = Color3.fromRGB(50, 215, 75)
        task.wait(1)
        SaveBtn.Text = "保存设置"
        SaveBtn.BackgroundColor3 = Color3.fromRGB(10, 132, 255)
    end)

    local function getSafePosition(x, y, targetWidth, targetHeight)
        local screen = ScreenGui.AbsoluteSize
        local safeX = math.clamp(x, -targetWidth + 30, screen.X - 30)
        local safeY = math.clamp(y, -5, screen.Y - 30) 
        return safeX, safeY
    end

    local isDragging = false
    local hasDragged = false 
    local dragInput = nil 
    local dragStart, startPos

    local function applyDrag(uiElement)
        uiElement.InputBegan:Connect(function(input)
            if (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) and input.UserInputState == Enum.UserInputState.Begin then
                isDragging = true
                hasDragged = false 
                dragInput = input 
                dragStart = input.Position
                startPos = MainFrame.Position
            end
        end)
    end

    applyDrag(TopBar)
    applyDrag(ExpandBtn)

    UserInputService.InputChanged:Connect(function(input)
        if input == dragInput and isDragging then
            local delta = input.Position - dragStart
            if delta.Magnitude > 3 then hasDragged = true end
            
            local newX = startPos.X.Offset + delta.X
            local newY = startPos.Y.Offset + delta.Y
            local frameSize = MainFrame.AbsoluteSize
            local safeX, safeY = getSafePosition(newX, newY, frameSize.X, frameSize.Y)
            MainFrame.Position = UDim2.new(0, safeX, 0, safeY)
        end
    end)

    UserInputService.InputEnded:Connect(function(input)
        if input == dragInput then
            isDragging = false
            dragInput = nil 
        end
    end)

    return {
        ScreenGui = ScreenGui,
        MainFrame = MainFrame,
        CloseBtn = CloseBtn,
        ExpandBtn = ExpandBtn,
        DropMenu = DropMenu,
        ChatScroll = ChatScroll,
        ChatLayout = ChatLayout,
        UnreadBadge = UnreadBadge,
        UnreadText = UnreadText,
        ChatBox = ChatBox,
        TopBar = TopBar,
        Divider = Divider,
        isDragging = function() return isDragging end,
        hasDragged = function() return hasDragged end 
    }
end

local UI = createUI()

-- ============================================================
-- 智能滚动系统 
-- ============================================================
local function isScrolledToBottom()
    local maxScroll = UI.ChatLayout.AbsoluteContentSize.Y - UI.ChatScroll.AbsoluteWindowSize.Y
    if maxScroll <= 0 then return true end
    local currentScroll = UI.ChatScroll.CanvasPosition.Y
    return (maxScroll - currentScroll) <= 50 
end

local function executeSmoothScroll()
    task.defer(function()
        local maxScroll = UI.ChatLayout.AbsoluteContentSize.Y - UI.ChatScroll.AbsoluteWindowSize.Y
        if maxScroll > 0 then
            TweenService:Create(UI.ChatScroll, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                CanvasPosition = Vector2.new(0, maxScroll)
            }):Play()
        end
    end)
end

-- ============================================================
-- 最小化功能 
-- ============================================================
local function SetMinimizedState(state)
    if UI_STATE.Minimized == state then return end
    UI_STATE.Minimized = state
    UI.DropMenu.Visible = false
    
    if not UI_STATE.Minimized then
        UI_STATE.UnreadCount = 0
        UI.UnreadBadge.Visible = false
    end

    local EXPANDED_SIZE = UDim2.new(0, 320, 0, 240)
    local MINIMIZED_SIZE = UDim2.new(0, 40, 0, 40)
    local targetSize = UI_STATE.Minimized and MINIMIZED_SIZE or EXPANDED_SIZE

    local screen = UI.MainFrame.Parent.AbsoluteSize
    local currentX = UI.MainFrame.Position.X.Offset
    local currentY = UI.MainFrame.Position.Y.Offset
    local safeX = math.clamp(currentX, -targetSize.X.Offset + 30, screen.X - 30)
    local safeY = math.clamp(currentY, -5, screen.Y - 30)

    TweenService:Create(UI.MainFrame, TweenInfo.new(0.35, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
        Size = targetSize,
        Position = UDim2.new(0, safeX, 0, safeY)
    }):Play()

    if UI_STATE.Minimized then
        UI.TopBar.Visible = false
        UI.Divider.Visible = false
        UI.ExpandBtn.Visible = true
        UI.CloseBtn.Visible = false
    else
        UI.TopBar.Visible = true
        UI.Divider.Visible = true
        UI.ExpandBtn.Visible = false
        UI.CloseBtn.Visible = true
        executeSmoothScroll()
    end
end

UI.ExpandBtn.MouseButton1Click:Connect(function()
    if UI.hasDragged() then return end
    SetMinimizedState(false)
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
        if not UI_STATE.Minimized and not UI.isDragging() then
            local pos = input.Position
            local framePos = UI.MainFrame.AbsolutePosition
            local frameSize = UI.MainFrame.AbsoluteSize
            
            local buffer = 5
            local isInsideMain = (pos.X >= framePos.X - buffer and pos.X <= framePos.X + frameSize.X + buffer) and
                                 (pos.Y >= framePos.Y - buffer and pos.Y <= framePos.Y + frameSize.Y + buffer)
            
            local isInsideDrop = false
            if UI.DropMenu.Visible then
                local dPos = UI.DropMenu.AbsolutePosition
                local dSize = UI.DropMenu.AbsoluteSize
                isInsideDrop = (pos.X >= dPos.X and pos.X <= dPos.X + dSize.X) and
                               (pos.Y >= dPos.Y and pos.Y <= dPos.Y + dSize.Y)
            end

            if not isInsideMain and not isInsideDrop then
                SetMinimizedState(true) 
            end
        end
    end
end)

-- ============================================================
-- 并发翻译与 API 调用
-- ============================================================
local function addLog(senderName, message, isTranslated)
    local wasAtBottom = isScrolledToBottom()

    local Label = Instance.new("TextLabel")
    Label.Size = UDim2.new(1, 0, 0, 0)
    Label.AutomaticSize = Enum.AutomaticSize.Y
    Label.BackgroundTransparency = 1
    Label.RichText = true
    Label.TextXAlignment = Enum.TextXAlignment.Left
    Label.TextWrapped = true
    Label.Font = Enum.Font.Gotham
    Label.TextSize = 13
    
    if senderName == "系统" then
        Label.Text = string.format("<b>[%s]</b> %s", senderName, message)
        Label.TextColor3 = Color3.fromRGB(255, 200, 100) 
    else
        local tag = isTranslated and ' <font size="11" color="#888888">(已翻译)</font>' or ''
        
        local displayNameStr = senderName
        if senderName == LocalPlayer.DisplayName or senderName == LocalPlayer.Name then
            displayNameStr = string.format('<font color="#FF453A">%s</font>', senderName)
        end
        
        Label.Text = string.format("<b>[%s]:</b> %s%s", displayNameStr, message, tag)
        Label.TextColor3 = Color3.fromRGB(240, 240, 245)
    end
    Label.Parent = UI.ChatScroll

    if UI_STATE.Minimized and senderName ~= "系统" and senderName ~= LocalPlayer.DisplayName and senderName ~= LocalPlayer.Name then
        UI_STATE.UnreadCount = UI_STATE.UnreadCount + 1
        UI.UnreadText.Text = UI_STATE.UnreadCount > 99 and "99+" or tostring(UI_STATE.UnreadCount)
        UI.UnreadBadge.Visible = true
    end

    if wasAtBottom then
        executeSmoothScroll()
    end
    return Label
end

local function processIncomingMessage(senderPlayer, messageText)
    if senderPlayer == LocalPlayer or containsChinese(messageText) or not isMeaningfulToTranslate(messageText) then
        addLog(senderPlayer.DisplayName, messageText, false)
        return
    end

    local uiLabel = addLog(senderPlayer.DisplayName, '<font color="#aaaaaa"><i>[翻译中...]</i></font>', false)
    
    task.spawn(function()
        -- 接收消息强制翻译为中文 (在 callPublicTranslateAPI 里会自动转成 DeepL 的大写 ZH)
        callPublicTranslateAPI(messageText, "ZH", function(ok, response)
            local isCurrentlyAtBottom = isScrolledToBottom() 
            
            if ok then
                local clean = response:gsub("^%s+", ""):gsub("%s+$", ""):gsub("\n", " ")
                
                local displayNameStr = senderPlayer.DisplayName
                if senderPlayer == LocalPlayer then
                    displayNameStr = string.format('<font color="#FF453A">%s</font>', senderPlayer.DisplayName)
                end
                
                uiLabel.Text = string.format("<b>[%s]:</b> %s <font size=\"11\" color=\"#888888\">(已翻译)</font>", displayNameStr, clean)
            else
                local displayNameStr = senderPlayer.DisplayName
                if senderPlayer == LocalPlayer then
                    displayNameStr = string.format('<font color="#FF453A">%s</font>', senderPlayer.DisplayName)
                end
                
                uiLabel.Text = string.format("<b>[%s]:</b> %s <font size=\"11\" color=\"#FF5555\">(出错)</font>", displayNameStr, messageText)
            end
            
            if isCurrentlyAtBottom then
                executeSmoothScroll()
            end
        end)
    end)
end

-- ============================================================
-- 主动输入与翻译发送逻辑
-- ============================================================
UI.ChatBox.FocusLost:Connect(function(enterPressed)
    if not enterPressed then return end
    local textToTranslate = UI.ChatBox.Text
    if textToTranslate == "" then return end

    UI.ChatBox.Text = "正在翻译并发送中..."
    UI.ChatBox.Interactable = false 

    task.spawn(function()
        local targetLang = UI_STATE.TargetLangCode
        
        callPublicTranslateAPI(textToTranslate, targetLang, function(ok, response)
            UI.ChatBox.Interactable = true
            UI.ChatBox.Text = "" 

            if ok then
                local clean = response:gsub("^%s+", ""):gsub("%s+$", ""):gsub("\n", " ")
                sendRealChatMessage(clean)
            else
                UI.ChatBox.Text = "翻译发送失败，请重试..."
                task.wait(1)
                UI.ChatBox.Text = textToTranslate
            end
        end)
    end)
end)

local function setupChatListener()
    for _, channel in ipairs(TextChatService.TextChannels:GetChildren()) do
        if channel:IsA("TextChannel") then
            channel.MessageReceived:Connect(function(msg)
                if msg.TextSource then
                    local sender = Players:GetPlayerByUserId(msg.TextSource.UserId)
                    if not UI.ScreenGui.Parent then return end
                    
                    if sender then 
                        processIncomingMessage(sender, msg.Text) 
                    end
                end
            end)
        end
    end
end

setupChatListener()
addLog("系统", "已成功挂载 DeepL 翻译驱动 (65312)，享受丝滑翻译吧！", false)
