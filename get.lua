local is = rawequal
local setmt = setmetatable
local unpack = unpack or table.unpack

local iter_ipairs = ipairs({})
local iter_pairs = pairs({})

local function gether(iter, ctx, st)
	local list = {}
	for _, v in iter, ctx, st do
		list[#list+1] = v
	end
	return list
end


local function mapped_iter(ctx, st)
	local p_iter, p_ctx = ctx.p_iter, ctx.p_ctx
	local p_st, p_value = st.p_st, st.p_value
	if p_st == nil then return nil end
	if p_value == nil then
		p_st, p_value = p_iter(p_ctx, p_st)
		if p_st == nil then return nil end
	end

	local c_iter, c_ctx, c_st = st.c_iter, st.c_ctx, st.c_st
	if not c_iter then
		c_iter, c_ctx, c_st = ctx.map(p_value)
	end

	local next_c_st, c_value = c_iter(c_ctx, c_st)
	if next_c_st == nil then
		local next_p_st, new_p_value = p_iter(p_ctx, p_st)
		return mapped_iter(ctx, { p_st = next_p_st, p_value = new_p_value })
	end

	return {
		p_st = p_st,
		p_value = p_value,
		c_iter = c_iter,
		c_ctx = c_ctx,
		c_st = next_c_st,
	}, c_value
end

local function flat_map(map, iter, ctx, init_st)
	return
		mapped_iter,
		{ map = map, p_iter = iter, p_ctx = ctx },
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

local function iter_values_bfs(root, st)
	if not st then
		if type(root) ~= 'table' then
			return { unvisited = {} }, root
		end
		return { unvisited = { root } }, root
	end

	local unvisited = st.unvisited
	local visiting = unvisited[1]
	if not visiting then return nil end

	local next_visiting_st, node = iter_pairs(visiting, st.st)

	if next_visiting_st == nil then
		return iter_values_bfs(root, { unvisited = { unpack(unvisited, 2) } })
	end

	local new_unvisited = { unpack(unvisited) }
	if type(node) == 'table' then
		new_unvisited[#new_unvisited+1] = node
	end

	return { unvisited = new_unvisited, st = next_visiting_st }, node
end

local function method_any_depth(self)
	return Getter(
		self, method_any_depth,
		flat_map(function (value)
			return iter_values_bfs, value, nil
		end, self[ITER], self[CTX], self[INIT_ST])
	)
end
methods._ = method_any_depth

local function iter_field(ctx, st)
	local parent, entry = ctx[1], ctx[2]
	for next_st, node in parent[ITER], parent[CTX], st do
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
	return Getter(self, name, iter_field, { self, name }, self[INIT_ST])
end
methods.field = method_field

local function method_filter(self, predict)
	local p_iter, p_ctx, p_init_st = self[ITER], self[CTX], self[INIT_ST]
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

local function method_items(self)
	return Getter(
		self, method_items, flat_map(ipairs, self[ITER], self[CTX], self[INIT_ST])
	)
end
methods.items = method_items

----

methods.one = function (self)
	local st, value = self[ITER](self[CTX], self[INIT_ST])
	if st == nil then return nil end
	return value
end

methods.iter = function (self)
	return self[ITER], self[CTX], self[INIT_ST]
end


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
			return gether(self[ITER], self[CTX], self[INIT_ST])
		end

		-- case 2
		local method = methods[self[ENTRY]]
		assert(method)
		return method(arg1, ...)
	end,
}

local function get(data)
	return Getter(nil, nil, iter_ipairs, { data }, 0)
end

return setmt({}, {
	__call = function (_, ...)
		return get(...)
	end,
})
