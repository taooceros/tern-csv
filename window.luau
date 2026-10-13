--!strict
-- The window half: plain opens of .csv/.tsv files go to the CSV Table
-- block, which shows them as a table under a Table | Text switch (as Tern
-- shows Markdown with a Rendered | Source one). Text is Tern's own file
-- block, opened in the table's place; "Show CSV as table" (⌃⌥T) puts the
-- table back in the file block's place. "Open CSV…" opens one from the
-- palette.

local KIND = "csv.table"

local function is_table_file(path: string): boolean
	local ext = string.lower(string.match(path, "%.([^./]+)$") or "")
	return ext == "csv" or ext == "tsv" or ext == "tab"
end

-- Tern has no in-place open for a plugin block (`how = "replace"` and
-- `new_block(…, "replace")` open beside it), so a swap opens the other side
-- beside the pane, which splits it, and closes the pane: the new one takes
-- its place in the split tree.
local function swap(cx: WindowCx, old: number, new: number?)
	if new ~= nil and new ~= old then
		cx.layout:close(old)
	end
end

-- Every open of a .csv/.tsv/.tab file shows the table: from the Files pane
-- (previews too), the palette, drops, links in panes, `tern open` and the
-- system. Opens a plugin handler makes skip the routes, so the Text side's
-- open below still reaches Tern's editor. A line-targeted open puts the
-- cursor on the row holding that line. A route's `block` decision opens
-- beside the focused pane (it has no preview placement), so an in-place
-- (`replace`) open swaps the table in itself.
tern.route.open(function(req: OpenRequest, cx: WindowCx): RouteDecision?
	if not is_table_file(req.path) then
		return nil
	end
	local args = { req.path }
	if req.line ~= nil then
		table.insert(args, tostring(req.line))
	end
	local focused = cx.session:focused()
	if req.how == "replace" and focused ~= nil then
		local table_pane = cx.layout:split(focused, "right", { block = KIND, args = args })
		if table_pane ~= nil then
			swap(cx, focused, table_pane)
			return { handled = true }
		end
	end
	return { block = KIND, args = args }
end)

-- The block's Text side: its `csv-text:<path>` link opens the file in Tern's
-- own file block in the table's place. Opens a plugin handler makes skip the
-- routes, so the file block isn't routed back to a table.
tern.route.link(function(link: LinkRequest, cx: WindowCx): RouteDecision?
	local path = string.match(link.url, "^csv%-text:(/.+)$")
	if path == nil then
		return nil
	end
	cx.layout:focus(link.pane)
	cx:open(path, "beside")
	swap(cx, link.pane, cx.session:focused())
	return { handled = true }
end)

-- The way back: the focused file block showing a CSV becomes the table, in
-- its place.
local function show_table(cx: WindowCx)
	local focused = cx.session:focused()
	local info = if focused then cx.session:pane(focused) else nil
	local path = if info and info.kind == "file" then info.path else nil
	if focused == nil or path == nil or not is_table_file(path) then
		cx:toast("info", "No CSV file in focus", "Show CSV as table works on a .csv, .tsv or .tab file block")
		return
	end
	local read = cx.session:read(focused, { lines = 1 })
	if type(read) == "table" and (read :: any).dirty then
		cx:toast("info", "Save " .. (string.match(path, "[^/]+$") or path) .. " first", "The table shows the file as saved")
		return
	end
	local table_pane = cx.layout:split(focused, "right", { block = KIND, args = { path } })
	if table_pane == nil then
		cx:toast("error", "CSV Table is not available", "The csv plugin's host half is not ready on this host")
		return
	end
	swap(cx, focused, table_pane)
end

tern.command({ id = "show_table", title = "Show CSV as table", icon = "grid", run = show_table })
tern.bind("ctrl+alt+t", "plugin.csv.show_table")

tern.command({
	id = "open",
	title = "Open CSV…",
	icon = "grid",
	run = function(cx: WindowCx)
		-- A focused file block showing a CSV opens as a table; otherwise the
		-- block lists the CSV and TSV files in the focused pane's folder.
		local focused = cx.session:focused()
		local info = if focused then cx.session:pane(focused) else nil
		local args: { string } = {}
		if info and info.path and is_table_file(info.path) then
			args = { info.path }
		elseif info and info.cwd and info.cwd ~= "" then
			args = { info.cwd }
		end
		if cx:new_block(KIND, args, "beside") == nil then
			cx:toast("error", "CSV Table is not available", "The csv plugin's host half is not ready on this host")
		end
	end,
})
