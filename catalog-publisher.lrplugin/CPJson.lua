-- Minimal JSON encoder/decoder (Lightroom ships none). Lua 5.1 compatible.
-- Tables encode as arrays when they have a positive length (or are
-- CPJson.array{}), otherwise as objects. JSON null decodes to nil.

CPJson = CPJson or {}

local arrayMark = {}

-- Mark a table so it encodes as a JSON array even when empty.
function CPJson.array(t)
	return setmetatable(t or {}, arrayMark)
end

local escapes = {
	['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
	['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function encodeString(s)
	return '"' .. s:gsub('[%c"\\]', function(c)
		return escapes[c] or string.format('\\u%04x', c:byte())
	end) .. '"'
end

local encode

local function encodeTable(t, out)
	if getmetatable(t) == arrayMark or #t > 0 then
		out[#out + 1] = '['
		for i = 1, #t do
			if i > 1 then out[#out + 1] = ',' end
			encode(t[i], out)
		end
		out[#out + 1] = ']'
	else
		local keys = {}
		for k in pairs(t) do keys[#keys + 1] = tostring(k) end
		table.sort(keys)
		out[#out + 1] = '{'
		for i, k in ipairs(keys) do
			if i > 1 then out[#out + 1] = ',' end
			out[#out + 1] = encodeString(k)
			out[#out + 1] = ':'
			encode(t[k], out)
		end
		out[#out + 1] = '}'
	end
end

encode = function(v, out)
	local tv = type(v)
	if tv == 'table' then
		encodeTable(v, out)
	elseif tv == 'string' then
		out[#out + 1] = encodeString(v)
	elseif tv == 'number' then
		if v ~= v or v == math.huge or v == -math.huge then
			error('cannot encode non-finite number')
		end
		if math.floor(v) == v and math.abs(v) < 2 ^ 53 then
			out[#out + 1] = string.format('%d', v)
		else
			out[#out + 1] = string.format('%.14g', v)
		end
	elseif tv == 'boolean' then
		out[#out + 1] = v and 'true' or 'false'
	elseif v == nil then
		out[#out + 1] = 'null'
	else
		error('cannot encode ' .. tv)
	end
end

function CPJson.encode(v)
	local out = {}
	encode(v, out)
	return table.concat(out)
end

-- decoding

local function utf8char(cp)
	if cp < 0x80 then return string.char(cp) end
	if cp < 0x800 then
		return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
	end
	if cp < 0x10000 then
		return string.char(0xE0 + math.floor(cp / 0x1000),
			0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
	end
	return string.char(0xF0 + math.floor(cp / 0x40000),
		0x80 + math.floor(cp / 0x1000) % 0x40,
		0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local unescapes = { b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }

local decodeValue

local function skipWs(s, i)
	return s:find('[^ \t\r\n]', i) or (#s + 1)
end

local function decodeError(s, i, msg)
	error(string.format('JSON decode error at %d: %s', i, msg))
end

local function decodeString(s, i)
	-- s:sub(i, i) == '"'
	local parts = {}
	local j = i + 1
	while true do
		local k = s:find('["\\]', j)
		if not k then decodeError(s, i, 'unterminated string') end
		parts[#parts + 1] = s:sub(j, k - 1)
		if s:sub(k, k) == '"' then
			return table.concat(parts), k + 1
		end
		local c = s:sub(k + 1, k + 1)
		if c == 'u' then
			local hex = s:sub(k + 2, k + 5)
			local cp = tonumber(hex, 16)
			if not cp or #hex ~= 4 then decodeError(s, k, 'bad \\u escape') end
			j = k + 6
			if cp >= 0xD800 and cp <= 0xDBFF and s:sub(j, j + 1) == '\\u' then
				local lo = tonumber(s:sub(j + 2, j + 5), 16)
				if lo and lo >= 0xDC00 and lo <= 0xDFFF then
					cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
					j = j + 6
				end
			end
			parts[#parts + 1] = utf8char(cp)
		else
			parts[#parts + 1] = unescapes[c] or c
			j = k + 2
		end
	end
end

local literals = { ['true'] = true, ['false'] = false }

decodeValue = function(s, i)
	i = skipWs(s, i)
	local c = s:sub(i, i)
	if c == '{' then
		local obj = {}
		i = skipWs(s, i + 1)
		if s:sub(i, i) == '}' then return obj, i + 1 end
		while true do
			if s:sub(i, i) ~= '"' then decodeError(s, i, 'expected key') end
			local key
			key, i = decodeString(s, i)
			i = skipWs(s, i)
			if s:sub(i, i) ~= ':' then decodeError(s, i, 'expected ":"') end
			obj[key], i = decodeValue(s, i + 1)
			i = skipWs(s, i)
			local d = s:sub(i, i)
			if d == '}' then return obj, i + 1 end
			if d ~= ',' then decodeError(s, i, 'expected "," or "}"') end
			i = skipWs(s, i + 1)
		end
	elseif c == '[' then
		local arr = CPJson.array()
		local n = 0
		i = skipWs(s, i + 1)
		if s:sub(i, i) == ']' then return arr, i + 1 end
		while true do
			n = n + 1
			arr[n], i = decodeValue(s, i)
			i = skipWs(s, i)
			local d = s:sub(i, i)
			if d == ']' then return arr, i + 1 end
			if d ~= ',' then decodeError(s, i, 'expected "," or "]"') end
			i = i + 1
		end
	elseif c == '"' then
		return decodeString(s, i)
	else
		local num = s:match('^-?%d+%.?%d*[eE]?[-+]?%d*', i)
		if num and num ~= '' and num ~= '-' then
			return tonumber(num), i + #num
		end
		for lit, v in pairs(literals) do
			if s:sub(i, i + #lit - 1) == lit then return v, i + #lit end
		end
		if s:sub(i, i + 3) == 'null' then return nil, i + 4 end
		decodeError(s, i, 'unexpected character')
	end
end

function CPJson.decode(s)
	if type(s) ~= 'string' then error('JSON decode: expected string') end
	local v, i = decodeValue(s, 1)
	i = skipWs(s, i)
	if i <= #s then decodeError(s, i, 'trailing data') end
	return v
end

return CPJson
