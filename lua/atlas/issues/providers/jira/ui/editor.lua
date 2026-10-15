local M = {}

local form = require("atlas.ui.form")
local issues = require("atlas.issues.providers.jira.api.issues")
local service = require("atlas.providers.jira.client")
local users = require("atlas.providers.jira.users")
local notify = require("atlas.core.notify")
local picker = require("atlas.ui.picker")
local requests = require("atlas.core.requests")
local keymaps = require("atlas.core.keymaps")
local icons = require("atlas.ui.shared.icons")
local presentation = require("atlas.issues.ui.presentation")
local adf = require("atlas.formats.adf.from_markdown")

---@class JiraIssueEditorResult
---@field key string
---@field id string|nil
---@field self string|nil

---@class JiraIssueEditorValues
---@field title string
---@field body string
---@field assignee string|false
---@field reporter string|false
---@field issue_type string|false
---@field fields table<string, { name: string, label: string, value: any }>

---@class JiraIssueEditorState
---@field project_key string
---@field issue JiraIssue|nil
---@field on_done (fun(result: JiraIssueEditorResult|nil, err: string|nil))|nil
---@field assignee AtlasUser|nil
---@field reporter AtlasUser|nil
---@field issue_type IssueType|nil
---@field fields table<string, { name: string, label: string, value: any }>
---@field raw_description table|string|nil
---@field initial JiraIssueEditorValues
---@field requests AtlasRequestScope
---@field loading { assignee?: boolean, reporter?: boolean, type?: boolean, fields?: boolean }
---@field submitting boolean

---@param state JiraIssueEditorState
---@param editor AtlasForm
---@return JiraIssueEditorValues
local function values(state, editor)
	local content = form.get_content(editor)
	return {
		title = vim.trim(content.title),
		body = content.body,
		assignee = state.assignee and state.assignee.id or false,
		reporter = state.reporter and state.reporter.id or false,
		issue_type = state.issue_type and state.issue_type.id or false,
		fields = state.fields,
	}
end

---@param state JiraIssueEditorState
---@param editor AtlasForm
---@return boolean
local function is_modified(state, editor)
	return not vim.deep_equal(values(state, editor), state.initial)
end

---@param state JiraIssueEditorState
---@param body string
---@return table|string|userdata
local function description(state, body)
	if body == state.initial.body and state.raw_description then
		return state.raw_description
	elseif body == "" then
		return vim.NIL
	end

	return service.is_server() and body or adf.to_adf(body)
end

---@param state JiraIssueEditorState
---@param editor AtlasForm
local function render_loading(state, editor)
	form.render_meta(editor)
	if not state.submitting and editor.statusline.loading_spinner then
		local pending = next(state.loading)
		if pending then
			editor.statusline:notify("loading", "Loading " .. pending .. "...")
		else
			editor.statusline:clear_notice()
		end
	end
end

---@param state JiraIssueEditorState
---@param editor AtlasForm
---@param field "assignee"|"reporter"
local function select_user(state, editor, field)
	if state.submitting or state.loading[field] then
		return
	end

	local unassigned = { id = "__unassigned__", name = "None" }
	picker.search({
		title = field == "assignee" and "Assignee" or "Reporter",
		format_item = function(user)
			return user.name
		end,
		fetch = function(query, done)
			state.loading[field] = true
			editor.statusline:notify("loading", "Loading " .. field .. "...")
			form.render_meta(editor)

			return state.requests.run(function(callback)
				return issues.get_assignable_users({
					project = state.project_key,
					issue_key = state.issue and state.issue.key,
				}, query, callback)
			end, function(items, err)
				state.loading[field] = nil
				if err and not state.submitting then
					editor.statusline:notify("error", err)
				end
				render_loading(state, editor)

				if items and field == "assignee" then
					items = vim.list_extend({ unassigned }, items)
				end
				done(items, err)
			end)
		end,
		on_select = function(user)
			state.loading[field] = nil
			if not editor.closed and not state.submitting then
				state[field] = user ~= unassigned and user or nil
				render_loading(state, editor)
			end
		end,
		on_cancel = function()
			state.loading[field] = nil
			render_loading(state, editor)
		end,
	})
end

---@param state JiraIssueEditorState
---@param editor AtlasForm
---@param on_selected (fun())|nil
local function select_issue_type(state, editor, on_selected)
	if state.submitting or state.loading.type then
		return
	end

	state.loading.type = true
	editor.statusline:notify("loading", "Loading issue types...")
	form.render_meta(editor)

	state.requests.run(function(done)
		return issues.get_issue_types(state.project_key, done)
	end, function(items, err)
		state.loading.type = nil
		if state.submitting then
			form.render_meta(editor)
			return
		end

		if err or not items then
			editor.statusline:notify("error", err or "Unable to load issue types")
			render_loading(state, editor)
			return
		end

		local subtask = state.issue_type and state.issue_type.subtask or false
		items = vim.tbl_filter(function(item)
			return item.subtask == subtask
		end, items)

		render_loading(state, editor)

		picker.select({
			title = "Issue type",
			items = items,
			format_item = function(item)
				return (item.icon and item.icon.icon or icons.get("issue")) .. " " .. item.name
			end,
			on_select = function(item)
				if item and not editor.closed and not state.submitting then
					if not state.issue_type or state.issue_type.id ~= item.id then
						state.fields = {}
					end
					state.issue_type = item
					form.render_meta(editor)
					if on_selected then
						on_selected()
					end
				end
			end,
		})
	end)
end

---@param state JiraIssueEditorState
---@param editor AtlasForm
local function load_reporter(state, editor)
	state.loading.reporter = true
	editor.statusline:notify("loading", "Loading reporter...")
	form.render_meta(editor)

	state.requests.run(users.fetch_user, function(user, err)
		state.loading.reporter = nil
		if err then
			editor.statusline:notify("error", err)
		else
			state.reporter = user
			state.initial.reporter = user and user.id or false
		end
		render_loading(state, editor)
	end)
end

---@param state JiraIssueEditorState
---@param editor AtlasForm
---@param field_id string
---@param field JiraMetaField
local function edit_field(state, editor, field_id, field)
	local current = state.fields[field_id]
	---@param label string|nil
	---@param value any
	local function set(label, value)
		if not editor.closed and not state.submitting then
			state.fields[field_id] = label and { name = field.name, label = label, value = value } or nil
			form.render_meta(editor)
		end
	end

	if field.kind == "select" then
		local none = { id = "", name = "None" }
		picker.select({
			title = field.name,
			items = vim.list_extend({ none }, field.options),
			format_item = function(option)
				return option.name
			end,
			on_select = function(option)
				if option == none then
					set(nil)
				elseif option then
					set(option.name, { id = option.id })
				end
			end,
		})
	elseif field.kind == "multi_select" then
		local chosen = {}
		for _, option in ipairs(current and current.value or {}) do
			chosen[option.id] = true
		end
		picker.multi_select({
			title = field.name,
			items = field.options,
			selected = vim.tbl_filter(function(option)
				return chosen[option.id]
			end, field.options),
			key = function(option)
				return option.id
			end,
			format_item = function(option)
				return option.name
			end,
			on_done = function(selected)
				local names = vim.tbl_map(function(option)
					return option.name
				end, selected)
				local ids = vim.tbl_map(function(option)
					return { id = option.id }
				end, selected)
				set(#selected > 0 and table.concat(names, ", ") or nil, ids)
			end,
		})
	else
		local prompt = field.name .. (field.kind == "date" and " (YYYY-MM-DD)" or "") .. ": "
		vim.ui.input({ prompt = prompt, default = current and current.label }, function(input)
			input = input and vim.trim(input)
			if input == nil then
				return
			elseif input == "" then
				set(nil)
			elseif field.kind == "labels" then
				local labels = vim.split(input, "[,%s]+", { trimempty = true })
				set(#labels > 0 and table.concat(labels, ", ") or nil, labels)
			elseif field.kind == "date" and not input:match("^%d%d%d%d%-%d%d%-%d%d$") then
				editor.statusline:notify("error", field.name .. " must look like YYYY-MM-DD")
			elseif field.kind == "number" and not tonumber(input) then
				editor.statusline:notify("error", field.name .. " must be a number")
			else
				set(input, field.kind == "number" and tonumber(input) or input)
			end
		end)
	end
end

---@param state JiraIssueEditorState
---@param editor AtlasForm
local function select_field(state, editor)
	if state.submitting or state.loading.fields then
		return
	end

	local issue_type = state.issue_type
	if not issue_type then
		select_issue_type(state, editor, function()
			select_field(state, editor)
		end)
		return
	end

	state.loading.fields = true
	editor.statusline:notify("loading", "Loading fields...")
	form.render_meta(editor)

	state.requests.run(function(done)
		return issues.get_create_fields(state.project_key, issue_type.id, done)
	end, function(fields, err)
		state.loading.fields = nil
		render_loading(state, editor)
		if state.submitting or state.issue_type ~= issue_type then
			return
		elseif not fields then
			editor.statusline:notify("error", err or "Unable to load fields")
			return
		end

		local handled = {
			summary = true,
			description = true,
			issuetype = true,
			project = true,
			assignee = true,
			reporter = true,
		}
		local items = {}
		for field_id, field in pairs(fields) do
			if field.kind and not handled[field_id] then
				table.insert(items, { id = field_id, field = field })
			end
		end
		table.sort(items, function(a, b)
			if a.field.required ~= b.field.required then
				return a.field.required
			end
			return a.field.name < b.field.name
		end)

		picker.select({
			title = "Fields",
			items = items,
			format_item = function(item)
				local current = state.fields[item.id]
				local required = item.field.required and " *" or ""
				return item.field.name .. required .. ": " .. (current and current.label or "None")
			end,
			on_select = function(item)
				if item and not editor.closed and not state.submitting then
					edit_field(state, editor, item.id, item.field)
				end
			end,
		})
	end)
end

---@param state JiraIssueEditorState
---@return AtlasFormMetaRow[]
local function render_meta(state)
	local type_name = state.issue_type and state.issue_type.name
	local type_style = state.issue_type and state.issue_type.icon
	local type_icon = type_style and type_style.icon or icons.get("issue")
	local type_hl = type_style and type_style.hl_group or "AtlasTextMuted"
	local assignee = state.assignee and state.assignee.name
	local reporter = state.reporter and state.reporter.name

	local rows = {
		{
			{
				key = "Project:",
				value = icons.provider_icon("jira", "issues") .. " " .. state.project_key,
				hl = "AtlasJiraKey",
			},
			{
				key = "Type:",
				value = type_name and type_icon .. " " .. type_name or "None",
				hl = type_hl,
				loading = state.loading.type,
			},
		},
		{
			{
				key = "Assignee:",
				value = icons.get("user") .. " " .. (assignee or "None"),
				hl = presentation.person_hl(assignee),
				loading = state.loading.assignee,
			},
			{
				key = "Reporter:",
				value = icons.get("user") .. " " .. (reporter or "None"),
				hl = presentation.person_hl(reporter),
				loading = state.loading.reporter,
			},
		},
	}

	local fields = vim.tbl_values(state.fields)
	table.sort(fields, function(a, b)
		return a.name < b.name
	end)
	for i = 1, #fields, 2 do
		local row = {}
		for _, field in ipairs({ fields[i], fields[i + 1] }) do
			table.insert(row, { key = field.name .. ":", value = field.label })
		end
		table.insert(rows, row)
	end
	return rows
end

---@param state JiraIssueEditorState
---@param editor AtlasForm
local function submit(state, editor)
	if state.submitting then
		return
	end

	local current = values(state, editor)
	if current.title == "" then
		notify.warn("Title is required")
		return
	elseif not current.issue_type then
		notify.warn("Issue type is required")
		return
	elseif not state.issue and next(state.loading) then
		return
	end

	if state.issue and not is_modified(state, editor) then
		form.close(editor)
		notify.info("No changes")
		return
	end

	state.submitting = true
	vim.bo[editor.editor_buf].modifiable = false
	editor.statusline:notify("loading", state.issue and "Saving issue..." or "Creating issue...")

	---@param result JiraIssueEditorResult|nil
	---@param err string|nil
	local function done(result, err)
		editor.statusline:clear_notice()
		if not result then
			err = err or "Unable to save issue"
			state.submitting = false
			if not editor.closed then
				vim.bo[editor.editor_buf].modifiable = true
				editor.statusline:notify("error", err)
			else
				if state.on_done then
					state.on_done(nil, err)
				end
				notify.error(err)
			end
			return
		end

		local was_closed = editor.closed
		form.close(editor)
		state.submitting = false
		if state.on_done then
			state.on_done(result, nil)
		end

		notify.info((state.issue and "Updated " or "Created ") .. result.key, { vim_notify = true })
		if not state.issue and not was_closed then
			require("atlas.commands.open").open(result.key)
		end
	end

	local user_key = service.is_server() and "name" or "accountId"
	local fields = {
		summary = current.title,
		description = description(state, current.body),
		issuetype = { id = current.issue_type },
	}
	if current.assignee ~= state.initial.assignee then
		fields.assignee = current.assignee and { [user_key] = current.assignee } or vim.NIL
	end
	if current.reporter ~= state.initial.reporter then
		fields.reporter = current.reporter and { [user_key] = current.reporter } or vim.NIL
	end

	if state.issue then
		issues.update_issue(state.issue.key, fields, function(ok, err)
			done(ok and { key = state.issue.key } or nil, err)
		end)
		return
	end

	fields.project = { key = state.project_key }
	for field_id, field in pairs(state.fields) do
		fields[field_id] = field.value
	end
	issues.create_issue(fields, done)
end

---@param state JiraIssueEditorState
---@param editor AtlasForm
local function close(state, editor)
	if state.submitting then
		return
	elseif not is_modified(state, editor) then
		form.close(editor)
	else
		vim.ui.input({ prompt = "Discard issue changes? [y/N]: " }, function(answer)
			if not state.submitting and (answer or ""):lower() == "y" then
				form.close(editor)
			end
		end)
	end
end

---@param state JiraIssueEditorState
---@param editor AtlasForm
local function preview_description(state, editor)
	local content = description(state, form.get_content(editor).body)
	local text = type(content) == "string" and content or require("atlas.ui.shared.utils").encode_pretty_json(content)
	vim.lsp.util.open_floating_preview(
		vim.split(text, "\n", { plain = true }),
		service.is_server() and "text" or "json",
		{
			border = "rounded",
			focus_id = "atlas_jira_description",
		}
	)
end

---@param project_key string
---@param issue JiraIssue|nil
---@param details JiraIssueDetails|nil
---@param on_done (fun(result: JiraIssueEditorResult|nil, err: string|nil))|nil
---@return AtlasForm
local function open_editor(project_key, issue, details, on_done)
	local assignee = details and details.assignees[1]
	local reporter = details and details.reporter
	local issue_type = details and details.type

	---@type JiraIssueEditorState
	local state = {
		project_key = project_key,
		issue = issue,
		on_done = on_done,
		assignee = assignee,
		reporter = reporter,
		issue_type = issue_type,
		fields = {},
		raw_description = details and details.raw_description,
		initial = {
			title = vim.trim(details and details.title or ""),
			body = details and details.description or "",
			assignee = assignee and assignee.id or false,
			reporter = reporter and reporter.id or false,
			issue_type = issue_type and issue_type.id or false,
			fields = {},
		},
		requests = requests.new(),
		loading = {},
		submitting = false,
	}

	local editor_keys = {
		{
			key = "ga",
			desc = "assignee",
			action = function(editor)
				select_user(state, editor, "assignee")
			end,
		},
		{
			key = "gr",
			desc = "reporter",
			action = function(editor)
				select_user(state, editor, "reporter")
			end,
		},
		{
			key = "gt",
			desc = "issue type",
			action = function(editor)
				select_issue_type(state, editor)
			end,
		},
	}

	if not issue then
		table.insert(editor_keys, {
			key = "gf",
			desc = "fields",
			action = function(editor)
				select_field(state, editor)
			end,
		})
	end

	local preview_keys = keymaps.resolve("ui.toggle_description_mode")
	if preview_keys then
		table.insert(editor_keys, {
			key = preview_keys,
			desc = "raw preview",
			action = function(editor)
				preview_description(state, editor)
			end,
		})
	end

	local editor = form.open({
		header = issue and "Edit issue " .. issue.key or "Create issue",
		initial_title = state.initial.title,
		initial_body = state.initial.body,
		completion = {
			context = { provider = "jira", project = project_key, issue = issue and { key = issue.key } },
		},
		is_modified = issue and function(form_editor)
			return is_modified(state, form_editor)
		end,
		meta = function()
			return render_meta(state)
		end,
		submit = function(form_editor)
			submit(state, form_editor)
		end,
		close = function(form_editor)
			close(state, form_editor)
		end,
		on_closed = function()
			state.requests.cancel()
			if not state.submitting and state.on_done then
				state.on_done(nil, nil)
			end
		end,
		keymaps = editor_keys,
	})

	if not issue then
		load_reporter(state, editor)
	end
	return editor
end

---@param project_key string
---@param on_done (fun(result: JiraIssueEditorResult|nil, err: string|nil))|nil
---@return AtlasForm
function M.open(project_key, on_done)
	return open_editor(project_key, nil, nil, on_done)
end

---@param issue JiraIssue
---@param on_done (fun(result: JiraIssueEditorResult|nil, err: string|nil))|nil
---@return { cancel: fun() }|nil
function M.edit(issue, on_done)
	notify.loading("Loading " .. issue.key .. "...")
	return issues.fetch_issue(issue, { force_refresh = true }, function(details, err)
		if not details then
			err = err or "Unable to load issue"
			notify.error(err)
			if on_done then
				on_done(nil, err)
			end
			return
		end

		notify.clear()
		local project_key = issue.project and issue.project.key or issue.key:match("^(.+)-%d+$")
		open_editor(project_key, issue, details, on_done)
	end)
end

return M
