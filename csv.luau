--!strict
-- CSV/TSV parsing (RFC 4180) and shaping into a header plus padded rows.
-- Pure Luau with no `tern` dependency, so it runs under the standalone
-- `luau` CLI too (see tests/csv_test.luau).
--
-- What the parser accepts:
-- - fields separated by one delimiter byte (`,` for CSV, a tab for TSV);
-- - records ended by CRLF, LF or a lone CR; the last record may lack one;
-- - quoted fields holding delimiters, line breaks (kept as written) and
--   quotes doubled as `""`;
-- - a quote inside an unquoted field (`5" disk`), kept literally;
-- - a UTF-8 byte order mark at the start, which is dropped.
-- Empty lines between records are skipped. Two faults raise a `ParseError`:
-- a quoted field that never closes, and text after a closing quote.

local csv = {}

export type ParseError = {
	msg: string,
	-- 1-based byte offset of the fault.
	pos: number,
	-- 1-based line and column (in bytes) of `pos`.
	line: number,
	col: number,
}

export type Table = {
	-- Column names, one per column; blank or missing names are `Column <n>`.
	header: { string },
	-- Data rows (the header excluded), each exactly `#header` cells long.
	rows: { { string } },
	-- Records shorter than the widest one, padded with empty cells.
	ragged: number,
	-- Whether each column holds only numbers (blank cells aside).
	numeric: { boolean },
}

local BOM = "\239\187\191"
local QUOTE = 34
local CR = 13
local LF = 10

-- The 1-based line and byte column of byte `pos` in `src`, counting CRLF,
-- LF and lone CR as line ends.
function csv.locate(src: string, pos: number): (number, number)
	local line, start, at = 1, 1, 1
	while true do
		local brk = string.find(src, "[\r\n]", at)
		if brk == nil or brk >= pos then
			break
		end
		local next_at = brk + 1
		if string.byte(src, brk) == CR and string.byte(src, next_at) == LF then
			next_at += 1
		end
		if next_at > pos then
			break -- `pos` is the LF of a CRLF: still on this line
		end
		line += 1
		start = next_at
		at = next_at
	end
	return line, pos - start + 1
end

-- The 1-based record that text line `line` belongs to (a record spans more
-- than one line when a quoted field holds line breaks). Lines past the end
-- give the last record.
function csv.record_at_line(src: string, line: number): number
	local record, cur, quoted = 1, 1, false
	local i, n = 1, #src
	while i <= n and cur < line do
		local b = string.byte(src, i)
		if b == QUOTE then
			quoted = not quoted
		elseif b == CR or b == LF then
			if b == CR and string.byte(src, i + 1) == LF then
				i += 1
			end
			cur += 1
			if not quoted and i < n then
				record += 1
			end
		end
		i += 1
	end
	return record
end

local function fail(src: string, msg: string, pos: number): never
	local line, col = csv.locate(src, pos)
	local err: ParseError = { msg = msg, pos = pos, line = line, col = col }
	error(err, 0)
end

-- The delimiter for a file name: a tab for `.tsv` and `.tab`, else a comma.
function csv.delimiter_for(path: string): string
	local ext = string.lower(string.match(path, "%.([^./]+)$") or "")
	if ext == "tsv" or ext == "tab" then
		return "\t"
	end
	return ","
end

-- Splits `src` into records of fields. `delim` is one byte, not a quote or
-- a line break. Raises a `ParseError` on an unclosed quote or text after a
-- closing quote.
function csv.parse(src: string, delim: string): { { string } }
	assert(#delim == 1 and delim ~= '"' and delim ~= "\r" and delim ~= "\n", "delimiter must be one byte")
	local dbyte = string.byte(delim)
	-- Ends an unquoted field. `%` escapes the delimiter, whatever it is.
	local stop_pat = "[%" .. delim .. "\r\n]"
	local n = #src
	local pos = 1
	if string.sub(src, 1, 3) == BOM then
		pos = 4
	end

	local records: { { string } } = {}
	local record: { string } = {}
	-- Whether the current record has a quoted field (`""` alone isn't blank).
	local quoted_in_record = false

	while pos <= n do
		local value: string
		if string.byte(src, pos) == QUOTE then
			quoted_in_record = true
			local open = pos
			local parts: { string } = {}
			local seg = pos + 1
			while true do
				local q = string.find(src, '"', seg, true)
				if q == nil then
					return fail(src, "quoted field is never closed", open)
				end
				if string.byte(src, q + 1) == QUOTE then
					table.insert(parts, string.sub(src, seg, q)) -- keeps one quote
					seg = q + 2
				else
					table.insert(parts, string.sub(src, seg, q - 1))
					pos = q + 1
					break
				end
			end
			value = table.concat(parts)
			local after = string.byte(src, pos)
			if after ~= nil and after ~= dbyte and after ~= CR and after ~= LF then
				fail(src, "unexpected text after a closing quote; quote the whole field and double inner quotes", pos)
			end
		else
			local stop = string.find(src, stop_pat, pos) or n + 1
			value = string.sub(src, pos, stop - 1)
			pos = stop
		end
		table.insert(record, value)

		local b = string.byte(src, pos)
		if b == dbyte then
			pos += 1
			if pos > n then
				table.insert(record, "") -- `a,b,` at the end: an empty last field
			end
		else
			-- A line end or the end of the input closes the record.
			if b == CR then
				pos += 1
				if string.byte(src, pos) == LF then
					pos += 1
				end
			elseif b == LF then
				pos += 1
			end
			if not (#record == 1 and record[1] == "" and not quoted_in_record) then
				table.insert(records, record)
			end
			record = {}
			quoted_in_record = false
		end
	end
	if #record > 0 then
		table.insert(records, record)
	end
	return records
end

-- Whether `s` reads as a number (blanks around it allowed).
local function is_number(s: string): boolean
	local t = string.match(s, "^%s*(.-)%s*$") or s
	return tonumber(t) ~= nil and not string.find(t, "^0[xXbB]")
end

-- Turns records into a `Table`: the first record names the columns, every
-- row is padded to the widest record, and columns whose non-blank cells
-- are all numbers are flagged numeric.
function csv.shape(records: { { string } }): Table
	local width = 0
	for _, r in records do
		width = math.max(width, #r)
	end
	local ragged = 0
	for _, r in records do
		if #r < width then
			ragged += 1
		end
	end

	local first = records[1] or {}
	local header: { string } = table.create(width, "")
	for i = 1, width do
		local name = first[i]
		if name == nil or string.match(name, "^%s*$") then
			name = "Column " .. i
		end
		header[i] = name
	end

	local rows: { { string } } = {}
	local numeric: { boolean } = table.create(width, true)
	local seen: { boolean } = table.create(width, false)
	for ri = 2, #records do
		local src = records[ri]
		local row: { string } = table.create(width, "")
		for ci = 1, width do
			local cell = src[ci]
			if cell ~= nil then
				row[ci] = cell
				if numeric[ci] and not string.match(cell, "^%s*$") then
					seen[ci] = true
					if not is_number(cell) then
						numeric[ci] = false
					end
				end
			end
		end
		rows[ri - 1] = row
	end
	for ci = 1, width do
		numeric[ci] = numeric[ci] and seen[ci]
	end

	return { header = header, rows = rows, ragged = ragged, numeric = numeric }
end

-- One record as a line of `delim`-separated fields (no line end), quoting
-- the fields that hold the delimiter, a quote or a line break.
function csv.format_row(fields: { string }, delim: string): string
	local out: { string } = table.create(#fields, "")
	for i, f in fields do
		if string.find(f, '"', 1, true) or string.find(f, delim, 1, true) or string.find(f, "[\r\n]") then
			out[i] = '"' .. string.gsub(f, '"', '""') .. '"'
		else
			out[i] = f
		end
	end
	return table.concat(out, delim)
end

return csv
