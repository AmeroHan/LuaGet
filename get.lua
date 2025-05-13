local is = rawequal
local type = type
local setmt = setmetatable
local unpack = table.unpack or unpack


---@alias IterFunc<CTX, ST, V> fun(ctx: CTX, st: ST): ST | nil, V?

---@generic CTX, ST, V
---@param iter IterFunc<CTX, ST, V>
---@param ctx CTX
---@param st ST
---@return V[]
local function gether(iter, ctx, st)
	local list = {}
	for _, v in iter, ctx, st do
		list[#list+1] = v
	end
	return list
end

---@alias FlatMapCtx<P_CTX, P_ST, P_V, C_V> {
---   mapper: (fun(x: P_V): C_V),
---   p_iter: IterFunc<P_CTX, P_ST, P_V>,
---   p_ctx: P_CTX,
---}

---@alias FlatMapSt<P_ST, P_V, C_CTX, C_ST, C_V> {
---   p_st: any | nil,
---   p_value?: any,
---   c_iter?: IterFunc,
---   c_ctx?: any,
---   c_st?: any,
---}

---@generic P_CTX, P_ST, P_V, C_CTX, C_ST, C_V
---@type IterFunc<FlatMapCtx<P_CTX, P_ST, P_V>, FlatMapSt<P_ST, P_V, C_CTX, C_ST, C_V>, C_V>
local function flat_map_iter(ctx, st)
	local p_iter, p_ctx = ctx.p_iter, ctx.p_ctx
	local p_st, p_value = st.p_st, st.p_value
	if p_value == nil then
		p_st, p_value = p_iter(p_ctx, p_st)
		if p_st == nil then return nil end
	end

	local c_iter, c_ctx, c_st = st.c_iter, st.c_ctx, st.c_st
	if not c_iter then
		c_iter, c_ctx, c_st = ctx.mapper(p_value)
		if not c_iter then
			if p_st == nil then return nil end
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

---@generic P_CTX, P_ST, P_V, C_CTX, C_ST, C_V
---@param mapper (fun(x: P_V): C_V)
---@param iter IterFunc<P_CTX, P_ST, P_V>
---@param ctx P_CTX
---@param init_st P_ST
local function flat_map(mapper, iter, ctx, init_st)
	return
		flat_map_iter,
		{ mapper = mapper, p_iter = iter, p_ctx = ctx },
		{ p_st = init_st }
end

---@class (exact) Symbol
---@type Symbol, Symbol, Symbol, Symbol, Symbol
local PARENT, ENTRY, ITER, CTX, INIT_ST = {}, {}, {}, {}, {}

---@class Getter

local Getter_mt  ---@type metatable

---@return Getter
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


local List_mt = {
	__index = table,
}
local method_all = function (self)
	return setmt(gether(self[ITER], self[CTX], self[INIT_ST]), List_mt)
end
methods.all = method_all


methods.unpack = function (self)
	return unpack(method_all(self))
end

-- chainable methods:

---@generic CTX, ST, V
---@param f fun(self: Getter, ...): IterFunc<CTX, ST, V>, CTX, ST
local function chainable_method(f)
	local function method(self, ...)
		local iter, ctx, init_st = f(self, ...)
		return Getter(self, method, iter, ctx, init_st), ctx, init_st
	end
	return method
end

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

local function method_field(self, key)
	local ctx = { p_iter = self[ITER], p_ctx = self[CTX], entry = key }
	local init_st = self[INIT_ST]
	return Getter(self, key, field_iter, ctx, init_st), ctx, init_st
end
methods.field = method_field


local function bfs_values_iter(root, st)
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
		return bfs_values_iter(root, { unpack(unvisited, 2) })
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
	return bfs_values_iter, value, nil
end

local method_bfs_values = chainable_method(function (self)
	return flat_map(bfs_field_values, method_iter(self))
end)
-- no need to be added to `methods`

local method_filter = chainable_method(function (self, predict)
	local p_iter, p_ctx, p_init_st = method_iter(self)
	return
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
end)
methods.filter = method_filter


local function safe_ipairs(x)
	if type(x) ~= 'table' then return nil end
	return ipairs(x)
end

local method_items = chainable_method(function (self)
	return flat_map(safe_ipairs, method_iter(self))
end)
methods.items = method_items


methods.map = chainable_method(function (self, mapper)
	local p_iter, p_ctx, p_init_st = method_iter(self)
	return
		function (ctx, st)
			local next_st, value = p_iter(ctx, st)
			if next_st == nil then return nil end
			return next_st, mapper(value)
		end,
		p_ctx,
		p_init_st
end)


local function safe_pairs(x)
	if type(x) ~= 'table' then return nil end
	return pairs(x)
end

methods.values = chainable_method(function (self)
	return flat_map(safe_pairs, method_iter(self))
end)


local keys_to_ignore = {
	[PARENT] = true, [ENTRY] = true, [ITER] = true, [CTX] = true, [INIT_ST] = true,
}
Getter_mt = {
	__index = function (self, key)
		if keys_to_ignore[key] then return nil end
		if key == '_' then
			---@diagnostic disable-next-line: redundant-return-value
			return method_bfs_values(self)
		end

		local key_type = type(key)
		if key_type == 'function' then
			---@diagnostic disable-next-line: redundant-return-value
			return method_filter(method_items(self), key)
		end
		---@diagnostic disable-next-line: redundant-return-value
		return method_field(self, key)
	end,
	-- Example:
	-- ```
	-- local books = get(data).books
	-- local items = get(data).books.items
	--
	-- -- case 1: gether values
	-- local case1 = get(data).books.items()  -- is `items()`
	--
	-- -- case 2: call methods
	-- local case2 = get(data).books:items()  -- is `items(books)`
	--
	-- -- case 3: use as an iterator function
	-- for _, book in get(data).books:items() do
	--    -- this will call `case2(ctx, init_st)` and `case2(ctx, st)`
	-- end
	-- for _, book in case2 do
	--    -- this will call `case2(nil, nil)` and `case2(nil, st)`
	-- end
	-- ```
	__call = function (self, ...)
		-- this judgement must take place before `arg_len` check,
		-- as `arg_len` can also be 2 here:
		if ... == self[PARENT] then  -- case 2, `self` is `items` in example
			local method = methods[self[ENTRY]]  -- `self[ENTRY]` is 'items'
			assert(method)
			return method(...)
		end

		local arg_len = select('#', ...)
		if arg_len == 2 then  -- case 3, `self` is `case2` in example
			local iter = self[ITER]
			local ctx, st = ...
			if ctx == nil then
				ctx = self[CTX]
				if st == nil then
					st = self[INIT_ST]
				end
			end
			return iter(ctx, st)
		end
		-- case 1, `self` is `items` in example
		assert(arg_len ~= 0, 'LuaGet对象函数调用收到了意外的参数')
		return method_all(self)
	end,
}

local next = next
local function get(data)
	return Getter(nil, nil, next, { data }, nil)
end

return setmt({}, {
	__call = function (_, ...)
		return get(...)
	end,
})
