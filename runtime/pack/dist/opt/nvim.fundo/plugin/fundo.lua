if vim.g.loaded_fundo_plugin ~= nil then
  return
end
vim.g.loaded_fundo_plugin = true

vim.api.nvim_create_user_command('FundoEnable', function()
  require('fundo').enable()
end, {})

vim.api.nvim_create_user_command('FundoDisable', function()
  require('fundo').disable()
end, {})

require('fundo').enable()
