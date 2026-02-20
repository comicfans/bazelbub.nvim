local log = require('log')
local plenary = require('plenary')

local api, fn = vim.api, vim.fn

local has_plenary, Float = pcall(require, "plenary.window.float")
if not has_plenary then
  log.error("Please install nvim-lua/plenary.nvim")
end

function highlight_passed(bufid, hlname, match_string, hlcolor)
  vim.api.nvim_set_hl(0, hlname, { fg = hlcolor })

  local lines = vim.api.nvim_buf_get_lines(bufid, 0, -1, true)
  local occurrences = {}

  for line_nr, line in ipairs(lines) do
    local start_col = 1
    while true do
      local s, e = line:find(match_string, start_col, true)
      if not s then break end
      table.insert(occurrences, { line_nr - 1, s - 1 })
      start_col = e + 1
    end
  end

  -- Add highlights for each occurrence
  for _, occurrence in ipairs(occurrences) do
    local line_nr, col = unpack(occurrence)
    vim.api.nvim_buf_add_highlight(bufid, -1, hlname, line_nr, col, col + string.len(match_string))
  end
end

function file_exists(p)
    local f = io.open(p, "r")
    if f then f:close() return true end
    return false
end


function find_bazel_root(filepath)
    -- Normalize separators
    local path = filepath:gsub("\\", "/")
    
    -- Split path into segments
    local segments = {}
    for segment in path:gmatch("[^/]+") do
        table.insert(segments, segment)
    end

    local workspace_root_idx = -1
    local root_files = {"WORKSPACE", "WORKSPACE.bazel", "MODULE.bazel"}

    -- 1. Walk up to find the root
    for i = #segments, 1, -1 do
        -- Reconstruct path up to current segment
        local current_path = "/" .. table.concat(segments, "/", 1, i) .. "/"

        local found = false
        for j = 1, #root_files do
            -- FIXED: Use 'j' to index root_files, not 'i'
            if file_exists(current_path .. root_files[j]) then
                workspace_root_idx = i
                found = true
                break
            end
        end

        if found then break end
    end

    if workspace_root_idx == -1 then 
        return nil, "Bazel root not found" 
    end

    -- FIXED: Use workspace_root_idx and remove the assignment '='
    return "/" .. table.concat(segments, "/", 1, workspace_root_idx)
end

function bazel_path(workspace_root, filepath)
    local p = plenary.path:new(filepath)
    local root = plenary.path:new(workspace_root):absolute()
    
    local build_dir = nil
    local current = p:parent()

    -- 1. Walk up to find the nearest BUILD/BUILD.bazel file
    while true do
        if plenary.path:new(current, "BUILD"):exists() or plenary.path:new(current, "BUILD.bazel"):exists() then
            build_dir = current:absolute()
            log.error("build_dir is :" .. build_dir)
            break
        end
        
        -- Stop if we've reached the workspace root or filesystem root
        if current:absolute() == root or current:absolute() == "/" then
            break
        end
        current = current:parent()
    end

    -- Fallback: If no BUILD file found, we can't construct a valid target
    if not build_dir then return nil end

    -- 2. Construct the Package part (from root to build_dir)
    -- make_relative returns a string
    local pkg = plenary.path:new(build_dir):make_relative(root)
    if pkg == "." then pkg = "" end -- Handle BUILD file at workspace root
    log.error("pkg is :"..pkg)

    -- 3. Construct the Target part (from build_dir to the file)
    local target = plenary.path:new(filepath):make_relative(build_dir)

    log.error("target is :"..target)
    -- 4. Combine into Bazel format: //package:target
    return string.format("//%s:%s", pkg, target)
end


function showFloatWindow(title, content)
  local float = Float.percentage_range_window(0.6, 0.3, { winblend = 5 }, {
    title = title,
    titlehighlight = "Bazel",
    topleft = "┌",
    topright = "┐",
    top = "─",
    left = "│",
    right = "│",
    botleft = "└",
    botright = "┘",
    bot = "─",
  })

  api.nvim_buf_set_lines(float.bufnr, 0, -1, true, content)
  highlight_passed(float.bufnr, 'MyPassed', 'PASSED', '#00FF00')
  highlight_passed(float.bufnr, 'MySuccess', 'successfully', '#00FF00')
  highlight_passed(float.bufnr, 'MyFailed', 'FAILED', '#FF0000')
  api.nvim_buf_set_keymap(float.bufnr, "n", "q", "<cmd>close!<CR>", { nowait = true, noremap = true, silent = true })
  api.nvim_set_option_value("readonly", true, { buf = float.bufnr })
end

--- Run the given command and return the output and exit code
-- @param the command to run
function runCommand(dir, executeCommand)


    local out_tmp = os.tmpname()
    local err_tmp = os.tmpname()

    local fullCommand = string.format("cd \"%s\";(%s) > \"%s\" 2> \"%s\"; echo $?", 
                                      dir ,executeCommand, out_tmp, err_tmp)
    local handle = io.popen(fullCommand)
    local lastLine = handle:read("*a")
    -- Close the handle

    local read_and_delete = function(filename)
        local f = io.open(filename, "r")
        local content = f:read("*a")
        f:close()
        os.remove(filename)
        return content
    end

    local stdout = read_and_delete(out_tmp)
    local stderr = read_and_delete(err_tmp)

    -- Get the exit code from the last line of the output
    local exitCode = tonumber(lastLine)
    return exitCode, stdout, stderr
end

function buildError(head, stdout, stderr)
    return head .. "\nstdout:\n" .. stdout .. "stderr:\n" .. stderr
end

local M = {}

function M.onInsertEnter()
  local curline = api.nvim_win_get_cursor(0)[1]
  vim.b.insert_top = curline
  vim.b.insert_bottom = curline
  vim.b.whitespace_lastline = curline
end



function M.runGazelle()

  -- always run from current file dir (since vim cmd might not always under workspace)
  local abs = plenary.path:new(vim.api.nvim_buf_get_name(0)):expand():absolute()
  local dir = abs.parent()
  local exit, stdout, stderr = runCommand(dir, "bazel run //:gazelle")
  local dBuffer = ""
  local title = "Gazelle ran successfully"
  if exit > 0 then
    dBuffer = buildError("bazel run //:gazelle failed!", stdout, stderr)
    title = "Gazelle failed"
  end

  showFloatWindow(title, vim.split(dBuffer, "\n"))
end

function M.runGazelleUpdateRepos()
  local abs = plenary.path:new(vim.api.nvim_buf_get_name(0)):expand():absolute()
  local dir = abs.parent()
  local exit, stdout, stderr = runCommand(dir, "bazel run //:gazelle-update-repos")
  local dBuffer = ""
  local title = "Gazelle update repos ran successfully"
  if exit > 0 then
    dBuffer = buildError("bazel run //:gazelle-update-repos failed!", stdout, stderr)
    title = "Gazelle update repos failed"
  end

  showFloatWindow(title, vim.split(dBuffer, "\n"))
end

-- Get the test targets for the file in the current buffer.
function M.getTestTargets()
  local abs = plenary.path:new(vim.api.nvim_buf_get_name(0)):expand():absolute()
  local dir = abs.parent()
  local fpa_rel = abs.head()
  local exit, stdout, stderr = runCommand(dir, string.format("bazel query 'kind(test, rdeps(//..., %s))' --keep_going", fpa_rel))
  local dBuffer = ""
  local title = "Bazel targets"
  if exit > 0 then
    dBuffer = buildError("Bazel failed", stdout, stderr)
    title = "Bazel run failed"
  end

  showFloatWindow(title, vim.split(dBuffer, "\n"))
end

-- Get the build targets for the file in the current buffer.
function M.getBuildTargets()
  local abs = plenary.path:new(vim.api.nvim_buf_get_name(0)):expand():absolute()
  local dir = abs.parent()
  local fpa_rel = abs.head()
  local exit, stdout, stderr = runCommand(dir, string.format("bazel query 'rdeps(//..., %s)' --keep_going", fpa_rel))
  local dBuffer = ""
  local title = "Bazel targets"
  if exit > 0 then
    dBuffer = buildError("Bazel failed", stdout, stderr)
    title = "Bazel run failed"
  end

  showFloatWindow(title, vim.split(dBuffer, "\n"))
end

-- Run bazel test on the targets for the current file.
function M.runTestTargets()
  local abs = plenary.path:new(vim.api.nvim_buf_get_name(0)):expand():absolute()
  local dir = abs.parent()
  local fpa_rel = abs.head()
  local exit, targets, stderr  = runCommand(dir, string.format("bazel query 'kind(test, rdeps(//..., %s))' --keep_going", fpa_rel))
  if exit > 0 then
    log.error(buildError("Bazel failed",  targets , stderr))
    return
  end

  local callback = function(obj)
    vim.schedule(function()
      if obj.code > 0 then
        showFloatWindow("Bazel test failed!", vim.split(obj.stderr, "\n"))
        return
      end
      showFloatWindow("Bazel tests ran successfully", vim.split(obj.stdout, "\n"))
    end)

  end

  index = 1
  cmd = {}
  cmd[index] = 'bazel'
  index = index + 1
  cmd[index] = 'test'
  index = index + 1

  for _, v in pairs(targets) do
    cmd[index] = v
    index = index + 1
  end

  vim.system(cmd, { text = true }, callback)
end



-- Build all dependencies for the current file.
function M.buildTargets()
  local file = vim.api.nvim_buf_get_name(0)
  local bazel_root = find_bazel_root(file)
  local fpa_rel = bazel_path(bazel_root, file)
  log.error(fpa_rel)

  local dir = plenary.path:new(file):parent()
  local exit,stdout,stderr  = runCommand(dir,string.format("bazel query 'rdeps(//..., %s)' --keep_going", fpa_rel))
  if exit > 0 then
    log.error(buildError("Bazel failed", stdout, stderr))
    return
  end

  local callback = function(obj)
    vim.schedule(function()
      if obj.code > 0 then
        showFloatWindow("Bazel build failed!", vim.split(obj.stderr, "\n"))
        return
      end
      -- For some reason the output is on stderr.
      showFloatWindow("Bazel build ran successfully", vim.split(obj.stderr, "\n"))
    end)
  end

  index = 1
  cmd = {}
  cmd[index] = 'bazel'
  index = index + 1
  cmd[index] = 'build'
  index = index + 1

  for v in stdout:gmatch("[^\r\n]+") do
    cmd[index] = v
    index = index + 1
  end

  vim.system(cmd, {cwd= dir.filename ,text = true }, callback)
end

function M.setup()
end

return M
