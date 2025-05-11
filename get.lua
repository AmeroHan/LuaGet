local is = rawequal
local type = type
local setmt = setmetatable
local unpack = table.unpack or unpack


local function gether(iter, ctx, st)
	local list = {}
	for _, v in iter, ctx, st do
		list[#list+1] = v
	end
	return list
end


local function flat_map_iter(ctx, st)
	local p_iter, p_ctx = ctx.p_iter, ctx.p_ctx
	local p_st, p_value = st.p_st, st.p_value
	if p_st == nil then return nil end
	if p_value == nil then
		p_st, p_value = p_iter(p_ctx, p_st)
		if p_st == nil then return nil end
	end

	local c_iter, c_ctx, c_st = st.c_iter, st.c_ctx, st.c_st
	if not c_iter then
		c_iter, c_ctx, c_st = ctx.mapper(p_value)
		if not c_iter then
			return flat_map_iter(ctx, { p_st = p_st })
		end
	end

	local next_c_st, c_value = c_iter(c_ctx, c_st)
	if next_c_st == nil then
		return flat_map_iter(ctx, { p_st = p_st })
	end

	return {
		p_st = p_st,
		p_value = p_value,
		c_iter = c_iter,
		c_ctx = c_ctx,
		c_st = next_c_st,
	}, c_value
end

local function flat_map(mapper, iter, ctx, init_st)
	return
		flat_map_iter,
		{ mapper = mapper, p_iter = iter, p_ctx = ctx },
		{ p_st = init_st }
end


local PARENT, ENTRY, ITER, CTX, INIT_ST = {}, {}, {}, {}, {}

local Getter_mt
local function Getter(parent, entry, iter, ctx, init_st)
	return setmt({
		[PARENT] = parent,
		[ENTRY] = entry,
		[ITER] = iter,
		[CTX] = ctx,
		[INIT_ST] = init_st,
	}, Getter_mt)
end


local methods = {}

methods.one = function (self)
	local st, value = self[ITER](self[CTX], self[INIT_ST])
	if st == nil then return nil end
	return value
end

local function method_iter(self)
	return self[ITER], self[CTX], self[INIT_ST]
end
methods.iter = method_iter

----

local function bfs_field_values_iter(root, st)
	if not st then
		if type(root) ~= 'table' then
			return {}, root
		end
		return { root }, root
	end

	local unvisited = st
	local visiting_node = unvisited[1]
	if not visiting_node then return nil end

	local visiting_iter, visiting_ctx, visiting_st = st.iter, st.ctx, st.st
	if not visiting_iter then
		visiting_iter, visiting_ctx, visiting_st = pairs(visiting_node)
	end
	local next_visiting_st, node = visiting_iter(visiting_ctx, visiting_st)

	if next_visiting_st == nil then
		return bfs_field_values_iter(root, { unpack(unvisited, 2) })
	end

	local new_st = {
		iter = visiting_iter,
		ctx = visiting_ctx,
		st = next_visiting_st,
		unpack(unvisited),
	}
	if type(node) == 'table' then
		new_st[#new_st+1] = node
	end

	return new_st, node
end

local function bfs_field_values(value)
	return bfs_field_values_iter, value, nil
end

local function method_any_depth(self)
	return Getter(
		self, method_any_depth, flat_map(bfs_field_values, method_iter(self))
	)
end
methods._ = method_any_depth

local function field_iter(ctx, st)
	local entry = ctx.entry
	for next_st, node in ctx.p_iter, ctx.p_ctx, st do
		if type(node) == 'table' then
			local value = node[entry]
			if value then
				return next_st, value
			end
		end
	end
	return nil
end
local function method_field(self, name)
	return Getter(
		self, name,
		field_iter,
		{ p_iter = self[ITER], p_ctx = self[CTX], entry = name },
		self[INIT_ST]
	)
end
methods.field = method_field

local function method_filter(self, predict)
	local p_iter, p_ctx, p_init_st = method_iter(self)
	return Getter(
		self, method_filter,
		function (ctx, st)
			for new_st, node in p_iter, ctx, st do
				if predict(node) then
					return new_st, node
				end
			end
			return nil
		end,
		p_ctx,
		p_init_st
	)
end
methods.filter = method_filter

local function safe_ipairs(x)
	if type(x) ~= 'table' then return nil end
	return ipairs(x)
end
local function method_items(self)
	return Getter(
		self, method_items, flat_map(safe_ipairs, method_iter(self))
	)
end
methods.items = method_items

local function safe_pairs(x)
	if type(x) ~= 'table' then return nil end
	return pairs(x)
end
local function method_values(self)
	return Getter(
		self, method_values, flat_map(safe_pairs, method_iter(self))
	)
end
methods.values = method_values


---@type metatable
Getter_mt = {
	__index = function (self, key)
		local key_type = type(key)
		if key_type == 'function' then
			return method_filter(method_items(self), key)
		end
		return method_field(self, key)
	end,
	__call = function (self, arg1, ...)
		-- e.g.
		-- local books = get(data).books
		-- local items = get(data).books.items
		-- local case1 = get(data).books.items()  -- is `items()`
		-- local case2 = get(data).books:items()  -- is `items(books)`

		-- `self` is `items`
		-- for case 2, `arg1` is `books`, i.e., self[PARENT]

		if not is(arg1, self[PARENT]) then  -- case 1
			return gether(method_iter(self))
		end

		-- case 2
		local method = methods[self[ENTRY]]
		assert(method)
		return method(arg1, ...)
	end,
}

local ipairs_iter = ipairs({})

local function get(data)
	return Getter(nil, nil, ipairs_iter, { data }, 0)
end

return setmt({}, {
	__call = function (_, ...)
		return get(...)
	end,
})
