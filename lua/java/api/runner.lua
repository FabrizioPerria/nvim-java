local log = require('java.utils.log')
local async = require('java-core.utils.async').sync
local get_error_handler = require('java.handlers.error')
local jdtls = require('java.utils.jdtls')
local DapSetup = require('java-dap.api.setup')
local ui = require('java.utils.ui')
local profile_config = require('java.api.profile_config')
local class = require('java-core.utils.class')

--- @class BuiltInMainRunner
--- @field win  number
--- @field bufnr number
--- @field job_id number
--- @field is_open boolean
local BuiltInMainRunner = class()

function BuiltInMainRunner:_set_up_buffer_autocmd()
	local group = vim.api.nvim_create_augroup('logger', { clear = true })
	vim.api.nvim_create_autocmd({ 'BufHidden' }, {
		group = group,
		buffer = self.bufnr,
		callback = function(_)
			self.is_open = true
		end,
	})
end

function BuiltInMainRunner:_init()
	self.is_open = false
end

function BuiltInMainRunner:stop()
	if self.job_id ~= nil then
		vim.fn.jobstop(self.job_id)
		vim.fn.jobwait({ self.job_id }, 1000)
		self.job_id = nil
	end
end

--- @param cmd string[]
function BuiltInMainRunner:run_app(cmd)
	self:stop()
	if not self.bufnr then
		self.bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_call(self.bufnr, function()
			self:_set_up_buffer()
		end)
	end

	self.chan = vim.api.nvim_open_term(self.bufnr, {
		on_input = function(_, _, _, data)
			if self.job_id then
				vim.fn.chansend(self.job_id, data)
			end
		end,
	})

	local command = table.concat(cmd, ' ')
	vim.fn.chansend(self.chan, command)
	self.job_id = vim.fn.jobstart(command, {
		pty = true,
		on_stdout = function(_, data)
			self:_on_stdout(data)
		end,
		on_exit = function(_, exit_code)
			self:_on_exit(exit_code)
		end,
	})
end

function BuiltInMainRunner:hide_logs()
	if self.bufnr then
		self.is_open = true
		vim.api.nvim_buf_call(self.bufnr, function()
			vim.cmd('hide')
		end)
	end
end

function BuiltInMainRunner:toggle_logs()
	if self.is_open then
		vim.api.nvim_buf_call(self.bufnr, function()
			self:_set_up_buffer()
			self:_scroll_down()
		end)
	else
		self:hide_logs()
	end
end

function BuiltInMainRunner:_set_up_buffer()
	vim.cmd('sp | winc J | res 15 | buffer ' .. self.bufnr)
	self.win = vim.api.nvim_get_current_win()

	vim.wo[self.win].number = false
	vim.wo[self.win].relativenumber = false
	vim.wo[self.win].signcolumn = 'no'

	self:_set_up_buffer_autocmd()
	self.is_open = false
end

--- @param data string[]
function BuiltInMainRunner:_on_stdout(data)
	vim.fn.chansend(self.chan, data)
	vim.api.nvim_buf_call(self.bufnr, function()
		local current_buf = vim.api.nvim_get_current_buf()
		local mode = vim.api.nvim_get_mode().mode
		if current_buf ~= self.bufnr or mode ~= 'i' then
			self:_scroll_down()
		end
	end)
end

--- @param exit_code number
function BuiltInMainRunner:_on_exit(exit_code)
	vim.fn.chansend(
		self.chan,
		'\nProcess finished with exit code ' .. exit_code .. '\n'
	)
	self.job_id = nil
	local current_buf = vim.api.nvim_get_current_buf()
	if current_buf == self.bufnr then
		vim.cmd('stopinsert')
	end
end

function BuiltInMainRunner:_scroll_down()
	local last_line = vim.api.nvim_buf_line_count(self.bufnr)
	vim.api.nvim_win_set_cursor(self.win, { last_line, 0 })
end

--- @class RunnerApi
--- @field client LspClient
--- @field private dap java.DapSetup
local RunnerApi = class()

function RunnerApi:_init(args)
	self.client = args.client
	self.dap = DapSetup(args.client)
end

function RunnerApi:get_config()
	local configs = self.dap:get_dap_config()
	return ui.select_from_dap_configs(configs)
end

--- @param callback fun(cmd)
--- @param args string
function RunnerApi:run_app(callback, args)
	local config = self:get_config()
	if not config then
		return
	end

	config.request = 'launch'
	local enrich_config = self.dap:enrich_config(config)
	local class_paths = table.concat(enrich_config.classPaths, ':')
	local main_class = enrich_config.mainClass
	local java_exec = enrich_config.javaExec

	local active_profile = profile_config.get_active_profile(enrich_config.name)

	local vm_args = ''
	local prog_args = ''
	if active_profile then
		prog_args = (active_profile.prog_args or '') .. ' ' .. (args or '')
		vm_args = active_profile.vm_args or ''
	end

	local cmd = {
		java_exec,
		vm_args,
		'-cp',
		class_paths,
		main_class,
		prog_args,
	}

	log.debug('run app cmd: ', cmd)
	callback(cmd)
end

local M = {
	built_in = {},
}

--- @param callback fun(cmd)
--- @param args string
function M.run_app(callback, args)
	return async(function()
			return RunnerApi(jdtls()):run_app(callback, args)
		end)
		.catch(get_error_handler('failed to run app'))
		.run()
end

--- @param opts {}
function M.built_in.run_app(opts)
	if not M.BuildInRunner then
		M.BuildInRunner = BuiltInMainRunner()
	end
	M.run_app(function(cmd)
		M.BuildInRunner:run_app(cmd)
	end, opts.args)
end

function M.built_in.toggle_logs()
	if M.BuildInRunner then
		M.BuildInRunner:toggle_logs()
	end
end

function M.built_in.stop_app()
	if M.BuildInRunner then
		M.BuildInRunner:stop(false)
	end
end

M.RunnerApi = RunnerApi
M.BuiltInMainRunner = BuiltInMainRunner
return M
