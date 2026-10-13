--!strict
-- The `table` block (kind `csv.table`): a CSV or TSV file as a table.
--
-- Its first launch argument is a file to show ("Open with › CSV Table",
-- the window's route, `cx:new_block("csv.table", { path })`) or a folder
-- to pick a .csv/.tsv file from (the "Open CSV…" command); with none it
-- lists the block's working directory. A relative path resolves against
-- the block's working directory. An optional second argument is a 1-based
-- text line: the cursor starts on the row holding it.
--
-- A file shows under a bar holding a Table | Text switch, as Tern's file
-- block shows Markdown under a Rendered | Source one. Text is Tern's own
-- file block: choosing it opens a `csv-text:<path>` link, which the window
-- half turns into an in-place open of the file, replacing this block; the
-- window's "Show CSV as table" command comes back.
--
-- Keys: ↑↓←→ (or hjkl) move the cursor cell, PageUp/PageDown (or Space)
-- page, Home/End (or g/G) go to the first/last row, 0/$ to the first/last
-- column; y copies the cell, Y the row; t switches to Text, r reloads,
-- Backspace returns to the folder the file was picked from.

local csv = require("./csv")

local ui = tern.ui

-- Files above this are refused: parsing runs in Luau, inside one 2-second
-- host call.
local MAX_BYTES = 4 * 1024 * 1024
-- Characters a table cell shows: longer values are cut (the dock shows
-- the cursor cell in full).
local CELL_CHARS = 40
-- Characters of the cursor cell the dock shows.
local VALUE_CHARS = 400
-- The widest a column header counts (in characters) in the dock.
local COL_CHARS = 24
-- Pane rows the bar, the dock, the table header and the margins take.
local CHROME_ROWS = 9
-- Pane rows per table row: a table row is one line plus 6px of padding,
-- about 1.4 terminal cells (measured at the default font size).
local ROW_STRIDE = 1.4

-- Rows rendered at once. A file this long or shorter is all rendered and
-- the pane scrolls it natively, filling whatever height the pane has;
-- longer files render this many rows around the cursor.
local WINDOW = 2000
-- The row markers' node id prefix: one invisible marker beside each rendered
-- row (table rows aren't nodes), so a `reveal` frame op scrolls a row into view.
local MARK_ID = "main.sheet.marks.m"
-- The header's marker: revealing it scrolls the pane to the top (the bar
-- above may be unmounted by the pane's virtualization; the markers never are).
local TOP_ID = "main.sheet.marks.head"
-- The link scheme of the Text side, handled by the window half's route.
local TEXT_LINK = "csv-text:"

type Problem = {
	-- `nofile`, `read`, `parse` or `empty`.
	kind: string,
	title: string,
	text: string,
	diag: Diag?,
}

type State = {
	cx: BlockCx,
	-- The file shown, absolute; nil while picking from `dir`.
	path: string?,
	-- The folder being picked from; nil while showing a file.
	dir: string?,
	-- The folder the file was picked from, for Backspace.
	back: string?,
	name: string,
	delim: string,
	data: csv.Table?,
	bytes: number,
	latin1: boolean,
	loading: boolean,
	problem: Problem?,
	-- Cursor cell (1-based data row and column; row 0 when there are no rows).
	row: number,
	col: number,
	-- First data row rendered (see WINDOW).
	top: number,
	-- Picker: the matching file names in `dir` and the selected one.
	files: { string },
	pick: number,
	-- A line to put the cursor on once the file is read (a line-targeted open).
	line: number?,
}

local function basename(path: string): string
	return string.match(path, "([^/]+)/*$") or path
end

local function plural(n: number, word: string): string
	return n .. " " .. word .. (if n == 1 then "" else "s")
end

local function grouped(n: number): string
	local s = tostring(n)
	while true do
		local swapped, k = string.gsub(s, "^(%d+)(%d%d%d)", "%1,%2")
		s = swapped
		if k == 0 then
			return s
		end
	end
end

local function bytes(n: number): string
	if n < 1024 then
		return plural(n, "byte")
	elseif n < 1024 * 1024 then
		return string.format("%.1f KiB", n / 1024)
	end
	return string.format("%.1f MiB", n / (1024 * 1024))
end

local function is_table_file(name: string): boolean
	local ext = string.lower(string.match(name, "%.([^./]+)$") or "")
	return ext == "csv" or ext == "tsv" or ext == "tab"
end

-- The first `max` characters of `s`, with an ellipsis when cut.
local function clip(s: string, max: number): string
	local cut = utf8.offset(s, max + 1)
	if cut == nil or cut > #s then
		return s
	end
	return string.sub(s, 1, cut - 1) .. "…"
end

-- A cell as one line: line breaks show as ↵ and tabs as spaces.
local function one_line(s: string, max: number): string
	if string.find(s, "[\r\n\t]") then
		s = string.gsub(string.gsub(string.gsub(s, "\r\n", "↵"), "[\r\n]", "↵"), "\t", " ")
	end
	return clip(s, max)
end

-- `path` made absolute against `base` (a leading ~ is the home directory).
local function absolute(path: string, base: string?): string
	if string.sub(path, 1, 1) == "/" then
		return path
	end
	local home = tern.getenv("HOME")
	if home and (path == "~" or string.sub(path, 1, 2) == "~/") then
		return home .. string.sub(path, 2)
	end
	return (base or "") .. "/" .. path
end

-- Whether `path` is a directory, and its entries when it is.
local function list_dir(path: string): { string }?
	local ok, entries = pcall(tern.fs.list, path)
	return if ok then entries else nil
end

-- Rows PageUp/PageDown move by: an estimate from the reported pane height
-- (which can lag the real one; the view itself doesn't depend on it).
local function page_size(cx: BlockCx): number
	return math.max(3, math.floor((cx.rows - CHROME_ROWS) / ROW_STRIDE))
end

-- Clamps the cursor and moves the window of rendered rows so it holds the
-- cursor row (the pane scrolls within the window; see `reveal`).
local function follow(state: State, cx: BlockCx)
	local data = state.data
	if data == nil then
		return
	end
	local n = #data.rows
	state.row = if n == 0 then 0 else math.clamp(state.row, 1, n)
	state.col = math.clamp(state.col, 1, math.max(#data.header, 1))
	if state.row < state.top or state.row >= state.top + WINDOW then
		state.top = state.row - WINDOW // 2
	end
	state.top = math.clamp(state.top, 1, math.max(1, n - WINDOW + 1))
end


-- A parse error as a diagnostic pointing at its line.
local function diagnostic(src: string, err: csv.ParseError, path: string): Diag
	local start = err.pos
	while start > 1 do
		local b = string.byte(src, start - 1)
		if b == 10 or b == 13 then
			break
		end
		start -= 1
	end
	local text = string.match(src, "^[^\r\n]*", start) or ""
	if #text > 160 then
		local from = math.max(1, err.col - 60)
		text = (if from > 1 then "…" else "") .. string.sub(text, from, from + 119) .. "…"
	end
	return {
		severity = "error",
		message = err.msg,
		path = path,
		line = err.line,
		col = err.col,
		snippet = { err.line :: any, text },
	}
end

local function set_problem(state: State, kind: string, title: string, text: string, diag: Diag?)
	state.data = nil
	state.problem = { kind = kind, title = title, text = text, diag = diag }
end

-- Reads at most MAX_BYTES of `path`: the bytes, or why not (one line).
local function read_capped(path: string): (string?, string)
	local ok, read = pcall(tern.fs.read, path, MAX_BYTES)
	if ok then
		return read, ""
	end
	-- "runtime error: tern.fs.read <path>: <reason>\nstack traceback: …"
	local msg = string.match(tostring(read), "^[^\n]*") or ""
	msg = string.gsub(msg, "^runtime error: ", "")
	msg = string.gsub(msg, "^tern%.fs%.read .-: ", "")
	return nil, msg
end

-- Parses `src`, read from `path`, into the table or a problem.
local function show(state: State, path: string, src: string)
	state.bytes = #src
	state.latin1 = utf8.len(src) == nil
	if state.latin1 then
		-- Not UTF-8: read it as Latin-1, as spreadsheets often write it.
		src = string.gsub(src, "[\128-\255]", function(c: string): string
			return utf8.char(string.byte(c))
		end)
	end
	local parsed, records = pcall(csv.parse, src, state.delim)
	if not parsed then
		local err = records :: any
		if type(err) == "table" then
			local e = err :: csv.ParseError
			return set_problem(state, "parse", state.name .. " is not valid CSV", e.msg, diagnostic(src, e, path))
		end
		return set_problem(state, "parse", "Could not parse " .. state.name, tostring(err))
	end
	local data = csv.shape(records :: { { string } })
	if #data.header == 0 then
		return set_problem(state, "empty", state.name .. " is empty", "The file holds no rows.")
	end
	state.data = data
	state.problem = nil
	local line = state.line
	if line then
		-- A line-targeted open: the cursor on the row holding that line (the
		-- header's line puts it on the first row).
		state.line = nil
		state.row = math.max(1, csv.record_at_line(src, line) - 1)
		local cx = state.cx
		tern.timer(0, function()
			cx:frame({ { "reveal", MARK_ID .. state.row, "nearest" } })
		end)
	end
	follow(state, state.cx)
end

-- A failed read (`msg` from `read_capped`) as a problem.
local function read_failed(state: State, msg: string)
	if string.find(msg, "max_bytes", 1, true) then
		return set_problem(
			state,
			"read",
			state.name .. " is too large",
			"CSV Table reads files up to " .. bytes(MAX_BYTES) .. ". Open it as text instead."
		)
	end
	set_problem(state, "read", "Could not read " .. state.name, msg)
end

-- Reads and parses the file; a problem replaces the table on failure. A
-- symlink is resolved by a `realpath` process first (the capped read takes
-- only regular files, and a process can't hang the worker on a FIFO), and
-- the block renders when it answers.
local function load(state: State)
	state.loading = false
	local path = state.path
	if path == nil then
		return
	end
	if not tern.fs.exists(path) then
		return set_problem(state, "nofile", state.name .. " was not found", "There is no file at " .. path .. ".")
	end
	if list_dir(path) then
		return set_problem(state, "read", state.name .. " is a folder", path .. " is a folder, not a CSV file.")
	end
	local src, msg = read_capped(path)
	if src then
		return show(state, path, src)
	elseif not string.find(msg, "non-symlink", 1, true) then
		return read_failed(state, msg)
	end
	state.loading = true
	local started = pcall(function()
		tern.process.run({ "realpath", path }, { timeout_ms = 3000 }, function(result: ProcessResult, _)
			if not state.loading or state.path ~= path then
				return -- reloaded or moved on meanwhile
			end
			state.loading = false
			local target = string.match(result.stdout, "^[^\n]+")
			local resolved, why = nil, "not a regular file"
			if result.status == 0 and target ~= nil then
				resolved, why = read_capped(target)
			end
			if resolved then
				show(state, path, resolved)
			elseif string.find(why, "regular", 1, true) then
				-- A FIFO, socket or device (or a link to one).
				set_problem(state, "read", "Could not read " .. state.name, path .. " is not a regular file.")
			else
				read_failed(state, why)
			end
			state.cx:render()
		end)
	end)
	if not started then
		state.loading = false
		read_failed(state, msg)
	end
end

-- Shows `path`: a file as a table (loaded now, or on a timer when `defer`
-- so `init` returns at once), a folder as a picker.
local function open_path(state: State, path: string, defer: boolean)
	state.data = nil
	state.problem = nil
	state.files = {}
	local entries = list_dir(path)
	if entries then
		state.dir, state.path = path, nil
		state.name = basename(path)
		for _, name in entries do
			if is_table_file(name) then
				table.insert(state.files, name)
			end
		end
		state.pick = math.clamp(state.pick, 1, math.max(1, #state.files))
		return
	end
	state.dir, state.path = nil, path
	state.name = basename(path)
	state.delim = csv.delimiter_for(path)
	if defer then
		state.loading = true
		tern.timer(0, function()
			if state.loading and state.path == path then
				load(state)
				state.cx:render()
			end
		end)
	else
		load(state)
	end
end

local function reload(state: State, cx: BlockCx)
	if state.dir then
		open_path(state, state.dir, false)
		return
	end
	load(state)
	local data = state.data
	if data and not state.loading then
		cx:toast("success", "Reloaded " .. state.name, plural(#data.rows, "row") .. " × " .. plural(#data.header, "column"))
	end
end

-- The Text side: Tern's file block for the same file, in this block's place
-- (the window half's link route opens it).
local function open_as_text(state: State, cx: BlockCx)
	if state.path then
		cx:open(TEXT_LINK .. state.path :: string)
	end
end

local function button(label: string, act: string, tone: string): Node
	local node = ui.badge(label, tone)
	local p: { [string]: any } = node.p or {}
	p.actions = { click = act }
	node.p = p
	return node
end

local function problem_view(state: State, problem: Problem): Node
	local children: { Node } = {}
	local diag = problem.diag
	if diag then
		table.insert(children, ui.diagnostic(diag, state.cx.cwd))
	else
		table.insert(children, ui.text({ ui.span(problem.text) }))
	end
	local buttons: { Node } = { button("Reload", "reload", "accent") }
	if state.path and problem.kind ~= "nofile" then
		table.insert(buttons, button("Open as text", "text", "neutral"))
	end
	if state.back then
		table.insert(buttons, button("Back to " .. basename(state.back :: string), "back", "neutral"))
	end
	table.insert(children, ui.row(buttons))
	if problem.kind == "nofile" then
		table.insert(children, ui.text({ ui.span("Paste a path to open another file.", "dim") }))
	end
	local card = ui.card({ ui.span(problem.title, "strong") }, children)
	local p: { [string]: any } = card.p or {}
	p.tone = if problem.kind == "nofile" or problem.kind == "empty" then "warning" else "error"
	card.p = p
	return card
end

local function table_view(state: State, data: csv.Table, cx: BlockCx): Node
	local last_row = math.min(#data.rows, state.top + WINDOW - 1)
	-- Every column, at its natural width: the sheet scrolls sideways.
	local ncols = #data.header
	local last_col = ncols

	local cols: { { [string]: any } } = {
		{ id = "n", head = { ui.span("#", "dim") }, align = "end" },
	}
	for ci = 1, last_col do
		local cur = ci == state.col
		table.insert(cols, {
			id = "c" .. ci,
			head = { ui.span(one_line(data.header[ci], CELL_CHARS), if cur then "accent" else nil) },
			align = if data.numeric[ci] then "end" else "start",
		})
	end
	local rows: { { [string]: any } } = {}
	for ri = state.top, last_row do
		local src = data.rows[ri]
		local on_row = ri == state.row
		-- A cell is a span list (a lone span table draws nothing).
		local n: { Span } = if on_row
			then { ui.span("▸ ", "accent"), ui.span(tostring(ri), "accent strong") }
			else { ui.span(tostring(ri), "dim") }
		local cells: { [string]: any } = { n = n }
		for ci = 1, last_col do
			local text = one_line(src[ci], CELL_CHARS)
			if on_row then
				cells["c" .. ci] = { ui.span(text, if ci == state.col then "accent strong" else "strong") }
			else
				cells["c" .. ci] = text
			end
		end
		-- Row ids follow the data row, so scrolling moves rows instead of
		-- rewriting them.
		table.insert(rows, { id = "r" .. ri, cells = cells })
	end
	-- The first marker stands beside the header: revealing it shows the top.
	local marks: { Node } = { ui.el("div", { key = "head", class = "csv-mark-head" }) }
	for ri = state.top, last_row do
		table.insert(marks, ui.el("div", { key = "m" .. ri, class = "csv-mark" }))
	end
	-- The table hides columns that don't fit its width, so it is made as wide
	-- as all of them: each column's widest cell (cells are one character
	-- cell per character) plus its 14px padding (about 2 cells).
	local width = #tostring(last_row) + 4
	for ci = 1, last_col do
		local w = utf8.len(one_line(data.header[ci], CELL_CHARS)) or 0
		for ri = state.top, last_row do
			w = math.max(w, utf8.len(one_line(data.rows[ri][ci], CELL_CHARS)) or 0)
		end
		width += w + 2
	end
	return ui.el("div", { key = "sheet", class = "csv-sheet" }, {
		ui.node("table", { key = "grid", cols = cols, rows = rows, min = { w = width .. "ch" } }),
		ui.el("div", { key = "marks", class = "csv-marks" }, marks),
	})
end

local KEYS = "↑↓←→ move · PgUp/PgDn page · g/G first/last row · 0/$ first/last column · y/Y copy cell/row · t text · r reload"

-- One side of the Table | Text switch; this block is always the Table side.
local function side_button(side: string, icon: string, label: string, act: string?): Node
	local on = act == nil
	return ui.el("button", {
		key = side,
		class = "csv-mode",
		title = label,
		aria = label,
		attrs = { ["data-mode"] = side, ["aria-pressed"] = if on then "true" else "false" },
		actions = if act then { click = act } else nil,
	}, { ui.node("icon", { name = icon }) })
end

-- The bar over a file: its name and folder, and the Table | Text switch.
local function bar_view(state: State, path: string): Node
	local dir = string.match(path, "^(.*)/[^/]*$") or ""
	return ui.el("div", { key = "bar", class = "csv-bar" }, {
		ui.el("span", { class = "csv-name", text = state.name }),
		ui.el("span", { class = "csv-dir", text = dir, title = path }),
		ui.el("div", { class = "csv-modes", aria = "View", attrs = { role = "group" } }, {
			side_button("table", "grid", "Table", nil),
			side_button("text", "code", "Text", "text"),
		}),
	})
end

local function dock_view(state: State, data: csv.Table): Node
	local kind = if state.delim == "\t" then "TSV" else "CSV"
	local summary = ui.text({
		ui.span(state.name, "strong"),
		ui.span("  " .. grouped(#data.rows) .. (if #data.rows == 1 then " row" else " rows"), "muted"),
		ui.span(" × " .. plural(#data.header, "column"), "muted"),
		ui.span("  " .. kind .. " · " .. bytes(state.bytes), "dim"),
	})
	local sp: { [string]: any } = summary.p or {}
	sp.grow = 1
	summary.p = sp
	local lines: { Node } = { ui.row({ summary, button("Reload", "reload", "neutral") }) }
	if state.row > 0 then
		local value = data.rows[state.row][state.col]
		local where = string.format("Row %s of %s · ", grouped(state.row), grouped(#data.rows))
		table.insert(
			lines,
			ui.text({
				ui.span(where, "muted"),
				ui.span(one_line(data.header[state.col], COL_CHARS), "info"),
				ui.span(": ", "muted"),
				if value == "" then ui.span("(empty)", "dim") else ui.span(one_line(value, VALUE_CHARS), "mono"),
			})
		)
	end
	if data.ragged > 0 then
		local what = plural(data.ragged, "short row")
		table.insert(lines, ui.text({ ui.span(what .. " padded with empty cells to " .. plural(#data.header, "column") .. ".", "warning") }))
	end
	if state.latin1 then
		table.insert(lines, ui.text({ ui.span("Not UTF-8: read as Latin-1.", "warning") }))
	end
	local keys = KEYS .. (if state.back then " · ⌫ back" else "")
	table.insert(lines, ui.text({ ui.span(keys, "dim") }))
	return ui.col(lines)
end

-- The picker's list is keyed `files`: items are `main.files.<name>`.
local FILES_ID = "main.files."

local function picker_view(state: State, cx: BlockCx): Node
	local items: { Item } = {}
	for i, name in state.files do
		items[i] = { label = name, icon = "grid", detail = if csv.delimiter_for(name) == "\t" then "TSV" else "CSV" }
	end
	local list = ui.list(items)
	local kids = list.c or {}
	for i, name in state.files do
		local p: { [string]: any } = kids[i].p or {}
		p.key = name
		kids[i].p = p
	end
	local p: { [string]: any } = list.p or {}
	p.key = "files"
	p.selected = if state.files[state.pick] then FILES_ID .. state.files[state.pick] else nil
	p.empty = { ui.span("No .csv or .tsv files here. Paste a path to open one.", "muted") }
	p.max = { lines = math.max(4, cx.rows - CHROME_ROWS) }
	list.p = p
	return ui.col({
		ui.text({ ui.span("CSV and TSV files in ", "muted"), ui.span(state.dir or "", "strong") }),
		list,
	})
end

-- Shows another file, picked or pasted, from its first cell.
local function open_other(state: State, path: string)
	state.row, state.col, state.top = 1, 1, 1
	open_path(state, path, false)
	-- The pane keeps its scroll position across files; start at the top.
	tern.timer(0, function()
		state.cx:frame({ { "reveal", TOP_ID, "start" } })
	end)
end

local function open_pick(state: State)
	local name = state.files[state.pick]
	local dir = state.dir
	if name and dir then
		state.back = dir
		open_other(state, dir .. "/" .. name)
	end
end

local function table_key(state: State, data: csv.Table, key: Key, cx: BlockCx): boolean
	local k = key.text or key.name
	local page = page_size(cx)
	local n = #data.rows
	if key.name == "up" or k == "k" then
		state.row -= 1
	elseif key.name == "down" or k == "j" then
		state.row += 1
	elseif key.name == "left" or k == "h" then
		state.col -= 1
	elseif key.name == "right" or k == "l" then
		state.col += 1
	elseif key.name == "page_up" then
		state.row -= page
	elseif key.name == "page_down" or key.name == "space" then
		state.row += page
	elseif key.name == "home" or k == "g" then
		state.row = 1
	elseif key.name == "end" or k == "G" then
		state.row = n
	elseif k == "0" or k == "^" then
		state.col = 1
	elseif k == "$" then
		state.col = #data.header
	elseif k == "y" then
		if state.row > 0 then
			local value = data.rows[state.row][state.col]
			cx:copy(value)
			cx:toast("success", "Copied cell", one_line(value, 80))
		end
		return false
	elseif k == "Y" then
		if state.row > 0 then
			cx:copy(csv.format_row(data.rows[state.row], state.delim))
			cx:toast("success", "Copied row " .. state.row, state.name)
		end
		return false
	else
		return false
	end
	follow(state, cx)
	return true
end

local block: BlockDef<State> = {
	init = function(cx, args, saved)
		local state: State = {
			cx = cx,
			path = nil,
			dir = nil,
			back = nil,
			name = "CSV Table",
			delim = ",",
			data = nil,
			bytes = 0,
			latin1 = false,
			loading = false,
			problem = nil,
			row = 1,
			col = 1,
			top = 1,
			files = {},
			pick = 1,
			-- Only on the first start: a restart keeps the saved cell.
			line = if saved == nil then tonumber(args[2]) else nil,
		}
		-- A restart reopens what the block last showed, at the same cell.
		local target: string? = args[1]
		if type(saved) == "table" then
			if type(saved.path) == "string" then
				target = saved.path
			elseif type(saved.dir) == "string" then
				target = saved.dir
			end
			if type(saved.back) == "string" then
				state.back = saved.back
			end
			if type(saved.row) == "number" and type(saved.col) == "number" then
				state.row, state.col = saved.row, saved.col
				-- The rows in view too, so a reload doesn't scroll.
				state.top = if type(saved.top) == "number" then saved.top else saved.row
			end
		end
		target = target or cx.cwd
		if target == nil then
			state.problem = {
				kind = "nofile",
				title = "No file to show",
				text = "Open a .csv or .tsv file from the Files pane, or choose Open with › CSV Table in a file's menu.",
			}
			return state
		end
		open_path(state, absolute(target :: string, cx.cwd), true)
		return state
	end,

	title = function(state)
		if state.dir then
			return "CSV · " .. state.name
		end
		return state.name
	end,

	view = function(state, cx)
		-- A region draws its root's children, not the root itself, so every
		-- view sits inside a column.
		local problem = state.problem
		local data = state.data
		local path = state.path
		if path == nil then
			if state.dir then
				return {
					main = picker_view(state, cx),
					dock = ui.col({ ui.text({ ui.span("↑↓ choose  ⏎ open  r rescan  paste a path to open it", "dim") }) }),
				}
			end
			return { main = ui.col({ if problem then problem_view(state, problem) else ui.progress(nil, "Reading…") }) }
		end
		local function file(body: { Node }): Node
			table.insert(body, 1, bar_view(state, path))
			return ui.col(body)
		end
		if problem then
			return { main = file({ problem_view(state, problem) }) }
		elseif data then
			local body: { Node } = { table_view(state, data, cx) }
			if #data.rows == 0 then
				table.insert(body, ui.text({ ui.span("No data rows below the header.", "muted") }))
			end
			return { main = file(body), dock = dock_view(state, data) }
		end
		return { main = file({ ui.progress(nil, "Reading " .. state.name .. "…") }) }
	end,

	key = function(state, key, cx)
		if key.ctrl or key.alt or key.meta then
			return false
		end
		if key.name == "paste" then
			local text = string.match(key.text or "", "^%s*(.-)%s*$") or ""
			if text == "" or string.find(text, "[\r\n]") or state.data then
				return false
			end
			state.back = state.dir or state.back
			open_other(state, absolute(text, state.dir or cx.cwd))
			return true
		end
		local k = key.text or key.name
		if k == "r" then
			reload(state, cx)
			return true
		elseif k == "t" and state.path then
			open_as_text(state, cx)
			return false
		elseif key.name == "backspace" and state.back and not state.dir then
			open_path(state, state.back :: string, false)
			return true
		end
		local data = state.data
		if data and not state.problem then
			local row = state.row
			local changed = table_key(state, data, key, cx)
			if changed and state.row > 0 then
				-- After the render, so a moved window's marker exists. Columns
				-- have no such marker: sideways, the sheet scrolls natively only.
				local new_row = state.row
				tern.timer(0, function()
					if new_row == row then
						return
					elseif new_row == 1 then
						cx:frame({ { "reveal", TOP_ID, "start" } })
					else
						cx:frame({ { "reveal", MARK_ID .. new_row, "nearest" } })
					end
				end)
			end
			return changed
		end
		if state.dir then
			local n = #state.files
			if key.name == "up" or k == "k" then
				state.pick = math.max(1, state.pick - 1)
			elseif key.name == "down" or k == "j" then
				state.pick = math.min(math.max(n, 1), state.pick + 1)
			elseif key.name == "home" or k == "g" then
				state.pick = 1
			elseif key.name == "end" or k == "G" then
				state.pick = math.max(n, 1)
			elseif key.name == "enter" or key.name == "space" then
				open_pick(state)
			else
				return false
			end
			return true
		end
		return false
	end,

	event = function(state, ev, cx)
		if ev.ev == "action" then
			if ev.act == "reload" then
				reload(state, cx)
			elseif ev.act == "text" then
				open_as_text(state, cx)
			elseif ev.act == "back" and state.back then
				open_path(state, state.back :: string, false)
			end
		elseif (ev.ev == "select" or ev.ev == "activate") and type(ev.item) == "string" then
			local name = string.sub(ev.item, #FILES_ID + 1)
			for i, f in state.files do
				if f == name then
					state.pick = i
					if ev.ev == "activate" then
						open_pick(state)
					end
				end
			end
		end
	end,

	resize = function(state, _cols, _rows, cx)
		follow(state, cx)
	end,

	save = function(state)
		return {
			path = state.path or tern.json.null,
			dir = state.dir or tern.json.null,
			back = state.back or tern.json.null,
			row = state.row,
			col = state.col,
			top = state.top,
		}
	end,
}

tern.block.define("table", block)
