-- Busted command-line runner

local path = require 'pl.path'
local tablex = require 'pl.tablex'
local term = require 'term'
local utils = require 'busted.utils'
local exit = require 'busted.compatibility'.exit
local loadstring = require 'busted.compatibility'.loadstring
local loaded = false

return function(options)
  if loaded then return else loaded = true end

  local isatty = io.type(io.stdout) == 'file' and term.isatty(io.stdout)
  options = tablex.update(require 'busted.options', options or {})
  options.defaultOutput = isatty and 'utfTerminal' or 'plainTerminal'

  local busted = require 'busted.core'()

  local cli = require 'busted.modules.cli'(options)
  local filterLoader = require 'busted.modules.filter_loader'()
  local helperLoader = require 'busted.modules.helper_loader'()
  local outputHandlerLoader = require 'busted.modules.output_handler_loader'()

  local luacov = require 'busted.modules.luacov'()

  require 'busted'(busted)

  local level = 2
  local info = debug.getinfo(level, 'Sf')
  local source = info.source
  local fileName = source:sub(1,1) == '@' and source:sub(2) or source

  -- Parse the cli arguments
  local appName = path.basename(fileName)
  cli:set_name(appName)
  local cliArgs, err = cli:parse(arg)
  if not cliArgs then
    io.stderr:write(err .. '\n')
    exit(1)
  end

  if cliArgs.version then
    -- Return early if asked for the version
    print(busted.version)
    exit(0)
  end

  -- Load current working directory
  local _, err = path.chdir(path.normpath(cliArgs.directory))
  if err then
    io.stderr:write(appName .. ': error: ' .. err .. '\n')
    exit(1)
  end

  -- If coverage arg is passed in, load LuaCovsupport
  if cliArgs.coverage then
    luacov()
  end

  -- If auto-insulate is disabled, re-register file without insulation
  if not cliArgs['auto-insulate'] then
    busted.register('file', 'file', {})
  end

  -- If lazy is enabled, make lazy setup/teardown the default
  if cliArgs.lazy then
    busted.register('setup', 'lazy_setup')
    busted.register('teardown', 'lazy_teardown')
  end

  -- Add additional package paths based on lpath and cpath cliArgs
  if #cliArgs.lpath > 0 then
    package.path = (cliArgs.lpath .. ';' .. package.path):gsub(';;',';')
  end

  if #cliArgs.cpath > 0 then
    package.cpath = (cliArgs.cpath .. ';' .. package.cpath):gsub(';;',';')
  end

  -- Load and execute commands given on the command-line
  if cliArgs.e then
    for k,v in ipairs(cliArgs.e) do
      loadstring(v)()
    end
  end

  -- watch for test errors and failures
  local failures = 0
  local errors = 0
  local quitOnError = not cliArgs['keep-going']

  busted.subscribe({ 'error', 'output' }, function(element, parent, message)
    io.stderr:write(appName .. ': error: Cannot load output library: ' .. element.name .. '\n' .. message .. '\n')
    return nil, true
  end)

  busted.subscribe({ 'error', 'helper' }, function(element, parent, message)
    io.stderr:write(appName .. ': error: Cannot load helper script: ' .. element.name .. '\n' .. message .. '\n')
    return nil, true
  end)

  busted.subscribe({ 'error' }, function(element, parent, message)
    errors = errors + 1
    busted.skipAll = quitOnError
    return nil, true
  end)

  busted.subscribe({ 'failure' }, function(element, parent, message)
    if element.descriptor == 'it' then
      failures = failures + 1
    else
      errors = errors + 1
    end
    busted.skipAll = quitOnError
    return nil, true
  end)

  -- Set up randomization options
  busted.sort = cliArgs['sort-tests']
  busted.randomize = cliArgs['shuffle-tests']
  busted.randomseed = tonumber(cliArgs.seed) or os.time()

  -- Set up output handler to listen to events
  outputHandlerLoader(busted, cliArgs.output, {
    defaultOutput = options.defaultOutput,
    enableSound = cliArgs['enable-sound'],
    verbose = cliArgs.verbose,
    suppressPending = cliArgs['suppress-pending'],
    language = cliArgs.lang,
    deferPrint = cliArgs['defer-print'],
    arguments = cliArgs.Xoutput,
  })

  -- Load tag and test filters
  filterLoader(busted, {
    tags = cliArgs.tags,
    excludeTags = cliArgs['exclude-tags'],
    filter = cliArgs.filter,
    filterOut = cliArgs['filter-out'],
    list = cliArgs.list,
    nokeepgoing = not cliArgs['keep-going'],
  })

  -- Set up helper script
  if cliArgs.helper and cliArgs.helper ~= '' then
    helperLoader(busted, cliArgs.helper, {
      verbose = cliArgs.verbose,
      language = cliArgs.lang,
      arguments = cliArgs.Xhelper
    })
  end

  -- Load test directory
  local rootFiles = cliArgs.ROOT or { fileName }
  local pattern = cliArgs.pattern
  local testFileLoader = require 'busted.modules.test_file_loader'(busted, cliArgs.loaders)
  testFileLoader(rootFiles, pattern, {
    verbose = cliArgs.verbose,
    sort = cliArgs['sort-files'],
    shuffle = cliArgs['shuffle-files'],
    recursive = cliArgs['recursive'],
    seed = busted.randomseed
  })

  -- If running standalone, setup test file to be compatible with live coding
  if options.standalone then
    local ctx = busted.context.get()
    local children = busted.context.children(ctx)
    local file = children[#children]
    debug.getmetatable(file.run).__call = info.func
  end

  local runs = cliArgs['repeat']
  local execute = require 'busted.execute'(busted)
  execute(runs, { seed = cliArgs.seed })

  busted.publish({ 'exit' })

  if options.standalone or failures > 0 or errors > 0 then
    exit(failures + errors)
  end
end
