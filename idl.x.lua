-- ycode-idl: build and install iOS apps with idl (github.com/jbisfun/idl) from a dock panel.
--
-- Finds the idlproj.yml files at or above the open folders, and one or two levels below
-- them (a pull workspace keeps repos one level down). Lists the selected project's targets
-- (`idl list`) and the devices the Jimpactor tray app can reach (`idl devices list`).
-- Build, install, check, gen, test, lint, fmt and clean run `idl` for one target or all of
-- them, in the debug or release profile, optionally --strict. Output streams into the
-- panel; compiler diagnostics (`file:line:col: error:`) are highlighted and open their
-- file on click. Toggle with "idl: panel" (right dock); "idl: build" / "idl: install"
-- run from the command palette with the panel's current selection.

local socket = require("socket")

local LIST_SECONDS = 15      -- re-read targets
local DISCOVER_SECONDS = 20  -- re-scan folders for idlproj.yml
local MAX_LINES = 3000       -- output lines kept in the panel

-- All panels (one per workspace) and the palette actions share this.
local S = {
    projects = {},        -- idlproj.yml paths
    project = nil,        -- selected idlproj.yml
    targets = {},         -- { name, kind, builder, bundle_id, ios, dir }
    target = nil,         -- selected target name; nil = all
    profile = "debug",
    strict = false,
    devices = nil,        -- { udid, connection, available, name }; nil = not listed yet
    device = nil,         -- selected udid
    lines = {},
    job = nil,            -- running command: { label, log, pid, started }
}

local function q(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function exists(p)
    local f = io.open(p)
    if f then f:close(); return true end
    return false
end

local function dirname(p) return p:match("^(.*)/[^/]*$") or "." end
local function basename(p) return p:match("([^/]+)/*$") or p end

local function walk_up(dir)
    while dir and dir ~= "" do
        if exists(dir .. "/idlproj.yml") then return dir .. "/idlproj.yml" end
        local parent = dir:match("^(.*)/[^/]+$")
        if not parent or parent == dir then break end
        dir = parent
    end
end

local function folders()
    local ok, f = pcall(ycode.workspace_folders)
    f = ok and f or {}
    if #f == 0 and os.getenv("PWD") then f = { os.getenv("PWD") } end
    return f
end

-- `cd <project dir> && idl -f <yml> ARGS...`
local function idl_cmd(args)
    local argv = { "idl", "-f", q(S.project) }
    for _, a in ipairs(args) do argv[#argv + 1] = q(a) end
    return "cd " .. q(dirname(S.project)) .. " && " .. table.concat(argv, " ")
end

local function now() return socket.gettime() end

local list_targets, list_devices

local function select_project(path)
    if S.project == path then return end
    S.project, S.targets, S.target, S.list_error = path, {}, nil, nil
    S.last_list = 0
end

local function discover()
    if S.discovering then return end
    S.discovering, S.last_discover = true, now()
    local found, seen = {}, {}
    local function add(p)
        if p and not seen[p] then seen[p] = true; found[#found + 1] = p end
    end
    local roots = folders()
    for _, f in ipairs(roots) do add(walk_up(f)) end
    local quoted = {}
    for i, f in ipairs(roots) do quoted[i] = q(f) end
    local cmd = "find " .. table.concat(quoted, " ") .. " -mindepth 2 -maxdepth 3"
        .. " \\( -name '.*' -o -name node_modules -o -name target -o -name build \\) -prune"
        .. " -o -name idlproj.yml -type f -print 2>/dev/null"
    ycode.spawn(cmd, function(_, out)
        S.discovering = false
        local below = {}
        for line in out:gmatch("[^\n]+") do below[#below + 1] = line end
        table.sort(below)
        for _, p in ipairs(below) do add(p) end
        S.projects = found
        if not (S.project and seen[S.project]) then
            S.project = nil
            select_project(found[1])
        end
    end)
end

function list_targets()
    if S.listing or not S.project then return end
    S.listing, S.last_list = true, now()
    local project = S.project
    ycode.spawn(idl_cmd({ "list", "-c", S.profile }) .. " 2>&1", function(ok, out)
        S.listing = false
        if project ~= S.project then return end
        if not ok then S.list_error = out:gsub("%s+$", ""); return end
        local targets = {}
        for line in out:gmatch("[^\n]+") do
            local name, kind, builder, bundle, ios, dir =
                line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+iOS%s+(%S+)%s+(.-)%s*$")
            if name then
                targets[#targets + 1] = { name = name, kind = kind, builder = builder,
                    bundle_id = bundle, ios = ios, dir = dir }
            end
        end
        S.targets, S.list_error = targets, nil
        local still = false
        for _, t in ipairs(targets) do if t.name == S.target then still = true end end
        if not still then S.target = nil end
    end)
end

function list_devices()
    if S.listing_devices or not S.project then return end
    S.listing_devices = true
    ycode.spawn(idl_cmd({ "devices", "list" }) .. " 2>&1", function(ok, out)
        S.listing_devices = false
        if not ok then
            S.devices, S.device_error = {}, (out:gsub("^error: ", ""):gsub("%s+$", ""))
            return
        end
        local devices = {}
        for line in out:gmatch("[^\n]+") do
            local udid, conn, avail, name = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(.-)%s*$")
            if udid and udid ~= "UDID" then
                devices[#devices + 1] = { udid = udid, connection = conn,
                    available = avail == "yes", name = name }
            end
        end
        S.devices, S.device_error = devices, nil
        local still = false
        for _, d in ipairs(devices) do if d.udid == S.device then still = true end end
        if not still then
            S.device = nil
            for _, d in ipairs(devices) do
                if d.available then S.device = d.udid; break end
            end
        end
    end)
end

local function read_log(path)
    local f = io.open(path)
    if not f then return end
    local text = f:read("a")
    f:close()
    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = line end
    if lines[#lines] == "" then lines[#lines] = nil end
    if #lines > MAX_LINES then
        lines = table.move(lines, #lines - MAX_LINES + 1, #lines, 1, {})
    end
    S.lines = lines
    S.log_size = #text
end

-- Run `idl <args>` in its own process group, its output streamed through a log file.
local function run(args, label)
    if S.job then S.message = S.job.label .. " is still running"; return end
    if not S.project then S.message = "no idlproj.yml found"; return end
    local log = os.tmpname()
    local pid = log .. ".pid"
    local inner = "echo $$ > " .. q(pid) .. "; exec \"$0\" \"$@\""
    local argv = { "idl", "-f", S.project }
    for _, a in ipairs(args) do argv[#argv + 1] = a end
    local quoted = {}
    for i, a in ipairs(argv) do quoted[i] = q(a) end
    local cmd = "cd " .. q(dirname(S.project)) .. " && setsid -w sh -c " .. q(inner) .. " "
        .. table.concat(quoted, " ") .. " > " .. q(log) .. " 2>&1"
    S.job = { label = label, log = log, pid = pid, started = now() }
    S.lines, S.log_size, S.last, S.message, S.follow = {}, 0, nil, nil, true
    ycode.spawn(cmd, function(ok, _, code)
        local job = S.job
        read_log(log)
        os.remove(log)
        os.remove(pid)
        S.job = nil
        S.last = { label = label, ok = ok, code = code, seconds = now() - job.started,
            stopped = job.stopped }
        S.last_list = 0
    end)
end

local function stop()
    local job = S.job
    if not job then return end
    local f = io.open(job.pid)
    local pid = f and f:read("l")
    if f then f:close() end
    if not pid or not pid:match("^%d+$") then S.message = "not started yet"; return end
    job.stopped = true
    ycode.spawn("kill -TERM -- -" .. pid .. " 2>/dev/null || kill -TERM " .. pid, function() end)
end

local function common(cmd, with_target)
    local args = { cmd, "-c", S.profile }
    if S.strict and (cmd == "build" or cmd == "check" or cmd == "install") then
        args[#args + 1] = "--strict"
    end
    if with_target ~= false and S.target then args[#args + 1] = S.target end
    return args
end

local function label(cmd)
    return "idl " .. cmd .. " " .. (S.target or "all") .. " (" .. S.profile
        .. (S.strict and ", strict" or "") .. ")"
end

local function action(cmd)
    return function() run(common(cmd), label(cmd)) end
end

local function install()
    if not S.device then
        S.message = S.devices and "pick a device first" or "listing devices…"
        if not S.devices then list_devices() end
        return
    end
    local args = { "install", S.device, "-c", S.profile }
    if S.strict then args[#args + 1] = "--strict" end
    if S.target then args[#args + 1] = S.target end
    local name = S.device
    for _, d in ipairs(S.devices or {}) do if d.udid == S.device then name = d.name end end
    run(args, "idl install " .. (S.target or "all") .. " → " .. name .. " (" .. S.profile .. ")")
end

-- Resolve a diagnostic path: absolute, else relative to the project or a target dir.
local function resolve(path)
    if path:sub(1, 1) == "/" then return path end
    local base = dirname(S.project)
    local candidates = { base .. "/" .. path }
    for _, t in ipairs(S.targets) do candidates[#candidates + 1] = base .. "/" .. t.dir .. "/" .. path end
    for _, c in ipairs(candidates) do if exists(c) then return c end end
end

local function output_line(line)
    local path, row, col, kind = line:match("^(.-):(%d+):(%d+): (%a+):")
    if not path then path, row, kind = line:match("^(.-):(%d+): (%a+):") end
    if path and (kind == "error" or kind == "warning" or kind == "note") then
        local abs = resolve(path)
        return { "text", line, fg = kind == "error" and "error" or kind == "warning" and "warning"
            or "accent", on_click = abs and function()
                S.message = basename(abs) .. ":" .. row .. (col and (":" .. col) or "")
                ycode.open(abs)
            end or nil }
    end
    local fg
    if line:match("^error") or line:match("^fatal") then fg = "error"
    elseif line:match("^warning") then fg = "warning" end
    return { "text", line == "" and " " or line, fg = fg }
end

local function choice(text, selected, on_click, size)
    return { "button", (selected and "● " or "") .. text, size = size or 11,
        on_click = function() on_click() end }
end

local function section(title, extra)
    local row = { "row", gap = 6, align = "center",
        { "text", title, bold = true, size = 12, fg = "muted", grow = true } }
    for _, e in ipairs(extra or {}) do row[#row + 1] = e end
    return row
end

local function target_row(t)
    local sel = S.target == (t and t.name)
    local row = { "col", px = 6, py = 3, rounded = 4, bg = sel and "element" or nil,
        on_click = function() S.target = t and t.name end }
    if not t then
        row[#row + 1] = { "text", "All targets (" .. #S.targets .. ")", bold = sel }
        return row
    end
    row[#row + 1] = { "row", gap = 6,
        { "text", t.name, bold = sel, grow = true },
        { "text", t.kind .. " · " .. t.builder .. " · iOS " .. t.ios, size = 11, fg = "muted" } }
    row[#row + 1] = { "text", t.bundle_id .. "  " .. t.dir, size = 11, fg = "muted", mono = true }
    return row
end

local function render(w)
    local t = now()
    if t - (S.last_discover or 0) > DISCOVER_SECONDS then discover() end
    if not S.project then
        return { "col", p = 12, gap = 6,
            { "text", S.discovering and "looking for idlproj.yml…"
                or "no idlproj.yml in the open folders, above them or one level below",
              fg = "muted", size = 12 },
            { "button", "Rescan", size = 11, on_click = function() S.last_discover = 0 end } }
    end
    if t - (S.last_list or 0) > LIST_SECONDS then list_targets() end
    if S.devices == nil and not S.listing_devices then list_devices() end
    if S.job then
        local f = io.open(S.job.log)
        local size = f and f:seek("end")
        if f then f:close() end
        if size and size ~= S.log_size then read_log(S.job.log) end
    end

    local body = { "col", id = "idl-body", scroll = true, grow = true, gap = 4, p = 8 }
    local function add(e) body[#body + 1] = e end

    if #S.projects > 1 then
        add(section("Project"))
        local row = { "row", gap = 4 }
        for _, p in ipairs(S.projects) do
            row[#row + 1] = choice(basename(dirname(p)), p == S.project,
                function() select_project(p) end)
        end
        add(row)
    end

    add(section("Targets", { { "button", "↻", size = 11,
        on_click = function() S.last_list = 0 end } }))
    if S.list_error then
        add({ "text", S.list_error, fg = "error", size = 11, mono = true })
    else
        add(target_row(nil))
        for _, tg in ipairs(S.targets) do add(target_row(tg)) end
    end

    add({ "row", gap = 4, align = "center",
        choice("debug", S.profile == "debug", function() S.profile = "debug" end),
        choice("release", S.profile == "release", function() S.profile = "release" end),
        { "button", (S.strict and "☑" or "☐") .. " strict", size = 11,
          on_click = function() S.strict = not S.strict end } })

    local busy = S.job ~= nil
    add({ "row", gap = 4,
        { "button", "Build", on_click = action("build") },
        { "button", "Install", on_click = install },
        { "button", "Check", on_click = action("check") },
        { "button", "Test", on_click = action("test") } })
    add({ "row", gap = 4,
        { "button", "Gen", size = 11, on_click = action("gen") },
        { "button", "Lint", size = 11, on_click = action("lint") },
        { "button", "Fmt", size = 11, on_click = action("fmt") },
        { "button", "Clean", size = 11, on_click = action("clean") } })

    add(section("Devices (Jimpactor)", { { "button", S.listing_devices and "…" or "↻", size = 11,
        on_click = function() list_devices() end } }))
    if S.device_error then
        add({ "text", S.device_error, fg = "muted", size = 11 })
    elseif S.devices and #S.devices == 0 then
        add({ "text", "no devices", fg = "muted", size = 11 })
    end
    for _, d in ipairs(S.devices or {}) do
        local sel = d.udid == S.device
        add({ "row", gap = 6, px = 6, py = 3, rounded = 4, bg = sel and "element" or nil,
            on_click = function() S.device = d.udid end,
            { "text", d.name, bold = sel, grow = true, fg = d.available and "text" or "muted" },
            { "text", d.connection .. (d.available and "" or ", unavailable"), size = 11,
              fg = "muted" } })
    end

    -- Output
    local status, color
    if S.job then
        status, color = string.format("%s  %.0fs", S.job.label, t - S.job.started), "accent"
    elseif S.last then
        status = string.format("%s  %s  %.1fs", S.last.label,
            S.last.stopped and "stopped" or (S.last.ok and "ok" or ("failed (" .. S.last.code .. ")")),
            S.last.seconds)
        color = S.last.ok and "success" or "error"
    end
    local errors, warnings = 0, 0
    for _, l in ipairs(S.lines) do
        if l:match(": error:") or l:match("^error:") then errors = errors + 1
        elseif l:match(": warning:") or l:match("^warning:") then warnings = warnings + 1 end
    end
    local out = { "col", id = "idl-out", scroll = true, grow = true, p = 6, mono = true,
        size = 11, bg = "editor", border = "border", rounded = 4 }
    for _, l in ipairs(S.lines) do out[#out + 1] = output_line(l) end
    if #S.lines == 0 then out[#out + 1] = { "text", "no output", fg = "muted" } end
    if S.follow and #S.lines ~= S.followed then
        S.followed = #S.lines
        pcall(w.scroll_bottom, "idl-out")
    end

    local header = { "row", gap = 6, align = "center",
        { "text", status or "Output", size = 11, fg = color or "muted", grow = true } }
    if errors + warnings > 0 then
        header[#header + 1] = { "text", errors .. "E " .. warnings .. "W", size = 11,
            fg = errors > 0 and "error" or "warning" }
    end
    if busy then
        header[#header + 1] = { "button", "Stop", size = 11, on_click = stop }
    elseif #S.lines > 0 then
        header[#header + 1] = { "button", "Clear", size = 11,
            on_click = function() S.lines, S.last = {}, nil end }
    end

    return { "col", w = "full", h = "full",
        { "row", gap = 6, align = "center", px = 8, py = 6, border = "border",
            { "text", "idl", bold = true },
            { "text", basename(dirname(S.project)), size = 11, fg = "muted", grow = true },
            { "button", "Rescan", size = 11, on_click = function() S.last_discover = 0 end } },
        { "col", h = 330, body },
        { "col", grow = true, gap = 4, px = 8, py = 6, header, out },
        { "text", S.message or S.project, size = 11, mono = true, fg = "muted", px = 8, py = 4 },
    }
end

%ctor
    gpui.register_panel{
        id = "idl", title = "idl", icon = "tool_hammer", position = "right", size = 380,
        poll_ms = 300,
        state = {},
        render = function(w)
            local ok, tree = pcall(render, w)
            if ok then return tree end
            return { "text", "ycode-idl: " .. tostring(tree), fg = "error" }
        end,
    }
end

%hook idl
%new - Panel
    ycode.dispatch("ycode::TogglePanel", { id = "idl" })
end

%new - Build
    if not S.project then discover() end
    run(common("build"), label("build"))
end

%new - Install
    install()
end
%end
