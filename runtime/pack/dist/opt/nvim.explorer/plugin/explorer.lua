if vim.g.loaded_explorer_plugin ~= nil then
  return
end
vim.g.loaded_explorer_plugin = true

package.preload['nvim.explorer'] = function()
  return require 'explorer'
end

require('explorer').setup()

vim.api.nvim_create_user_command('Explorer', function(opts)
  require('explorer').open(opts.args)
end, {
  nargs = '?',
  complete = 'dir',
})
