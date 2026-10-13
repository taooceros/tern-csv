--!strict
-- Parser tests for the standalone Luau CLI: `luau tests/csv_test.luau`
-- from the plugin folder. Exits with an error on the first failure.

local csv = require("../csv")

local passed = 0

local function show(v: any): string
	if type(v) == "table" then
		local parts = {}
		for _, x in v do
			table.insert(parts, show(x))
		end
		return "{" .. table.concat(parts, ", ") .. "}"
	elseif type(v) == "string" then
		return string.format("%q", v)
	end
	return tostring(v)
end

local function same(a: any, b: any): boolean
	if type(a) ~= type(b) then
		return false
	elseif type(a) ~= "table" then
		return a == b
	end
	if #a ~= #b then
		return false
	end
	for i = 1, #a do
		if not same(a[i], b[i]) then
			return false
		end
	end
	return true
end

local function check(name: string, got: any, want: any)
	if not same(got, want) then
		error(string.format("FAIL %s\n  got:  %s\n  want: %s", name, show(got), show(want)), 0)
	end
	passed += 1
end

local function parses(name: string, src: string, want: { { string } }, delim: string?)
	check(name, csv.parse(src, delim or ","), want)
end

local function fails(name: string, src: string, msg: string, line: number, col: number)
	local ok, err = pcall(csv.parse, src, ",")
	if ok then
		error("FAIL " .. name .. ": parsed, expected an error", 0)
	end
	local e = err :: csv.ParseError
	check(name .. " (message)", string.find(e.msg, msg, 1, true) ~= nil, true)
	check(name .. " (position)", { e.line, e.col }, { line, col })
end

-- Basic records and line endings.
parses("simple", "a,b,c\n1,2,3\n", { { "a", "b", "c" }, { "1", "2", "3" } })
parses("no final newline", "a,b\n1,2", { { "a", "b" }, { "1", "2" } })
parses("CRLF", "a,b\r\n1,2\r\n", { { "a", "b" }, { "1", "2" } })
parses("lone CR", "a,b\r1,2\r", { { "a", "b" }, { "1", "2" } })
parses("empty input", "", {})
parses("only a newline", "\n", {})
parses("BOM dropped", "\239\187\191id,name\n1,x\n", { { "id", "name" }, { "1", "x" } })
parses("blank lines skipped", "a\n\n\r\nb\n", { { "a" }, { "b" } })

-- Empty fields.
parses("empty fields", ",,\n", { { "", "", "" } })
parses("trailing delimiter at EOF", "a,b,", { { "a", "b", "" } })
parses("trailing delimiter then newline", "a,b,\n", { { "a", "b", "" } })
parses("quoted empty field is a record", '""\n', { { "" } })

-- RFC 4180 quoting.
parses("quoted comma", '"a,b",c\n', { { "a,b", "c" } })
parses("escaped quotes", '"say ""hi""",x\n', { { 'say "hi"', "x" } })
parses("only an escaped quote", '""""\n', { { '"' } })
parses("embedded LF", '"line 1\nline 2",x\n', { { "line 1\nline 2", "x" } })
parses("embedded CRLF kept", '"a\r\nb",c\r\nd,e\r\n', { { "a\r\nb", "c" }, { "d", "e" } })
parses("quoted at EOF", '"a","b"', { { "a", "b" } })
parses("bare quote inside unquoted field", '5" disk,x\n', { { '5" disk', "x" } })
parses("spaces kept", " a , b \n", { { " a ", " b " } })

-- TSV.
parses("tsv", "a\tb\n1\t2,3\n", { { "a", "b" }, { "1", "2,3" } }, "\t")
parses("tsv quoted tab", '"x\ty"\tz\n', { { "x\ty", "z" } }, "\t")
check("delimiter .tsv", csv.delimiter_for("/data/People.TSV"), "\t")
check("delimiter .tab", csv.delimiter_for("x.tab"), "\t")
check("delimiter .csv", csv.delimiter_for("/data/x.csv"), ",")
check("delimiter no ext", csv.delimiter_for("/data.d/README"), ",")

-- Errors with positions.
fails("unclosed quote", 'a,b\n1,"oops\n2,3\n', "never closed", 2, 3)
fails("text after closing quote", 'a,"b"c\n', "after a closing quote", 1, 6)
fails("text after quote on CRLF line 3", 'a\r\nb\r\n"x"y\r\n', "after a closing quote", 3, 4)

-- Shaping: header, padding, numeric columns.
local t = csv.shape(csv.parse("name,qty,,\nApple,3\nPear,10,x,y,extra\nFig\n", ","))
check("header padded and named", t.header, { "name", "qty", "Column 3", "Column 4", "Column 5" })
check("rows padded", t.rows, {
	{ "Apple", "3", "", "", "" },
	{ "Pear", "10", "x", "y", "extra" },
	{ "Fig", "", "", "", "" },
})
check("ragged count", t.ragged, 3) -- the header, Apple and Fig rows
check("numeric columns", t.numeric, { false, true, false, false, false })

local empty = csv.shape({})
check("empty table", { #empty.header, #empty.rows, empty.ragged }, { 0, 0, 0 })

local only_header = csv.shape(csv.parse("a,b\n", ","))
check("header only", only_header.header, { "a", "b" })
check("header only has no rows", #only_header.rows, 0)

local nums = csv.shape(csv.parse("n\n1.5\n-2\n 3e4 \n\n0x10\n", ","))
check("hex is not numeric", nums.numeric, { false })

-- Formatting a row back (what `Y` copies) round-trips through the parser.
local fields = { "plain", "a,b", 'say "hi"', "two\nlines", "" }
local line = csv.format_row(fields, ",")
check("format_row", line, 'plain,"a,b","say ""hi""","two\nlines",')
check("format_row round trip", csv.parse(line, ","), { fields })
check("format_row tsv", csv.format_row({ "a,b", "c\td" }, "\t"), 'a,b\t"c\td"')

-- A line-targeted open finds the record holding that line.
local multi = 'id,note\r\n1,"two\nlines"\r\n2,x\r\n'
check("record_at_line header", csv.record_at_line(multi, 1), 1)
check("record_at_line first", csv.record_at_line(multi, 2), 2)
check("record_at_line inside quotes", csv.record_at_line(multi, 3), 2)
check("record_at_line after quotes", csv.record_at_line(multi, 4), 3)
check("record_at_line past the end", csv.record_at_line(multi, 99), 3)

print(string.format("ok: %d checks passed", passed))
