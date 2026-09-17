local Paging = {}

-- =====================================================================
-- Shared limit/offset slicing
-- =====================================================================
--
-- Only 4 of the tools paginated, and the ones that did not were the ones
-- most able to hurt: list_keywords took no arguments at all and returned the
-- whole top-level keyword set, and list_folders walked every folder (with
-- include_subfolders, the entire tree) in one response. On a large catalog
-- either can bury a caller's context in a single call.
--
-- The three handlers that already paginate each did it inline, and reported
-- the outcome differently — some returned has_more, some did not. This is
-- that same arithmetic in one place, so every paginated tool answers the two
-- questions a caller actually has: how many are there in total, and is there
-- another page.

local DEFAULT_LIMIT = 100

-- limit = 0 is legal and means "tell me the total, send no items" — a cheap
-- way to size a catalog before deciding how to walk it.
function Paging.slice(items, args)
    args = args or {}
    items = items or {}

    local total = #items
    local limit = tonumber(args.limit)
    if limit == nil then limit = DEFAULT_LIMIT end
    if limit < 0 then limit = 0 end
    local offset = tonumber(args.offset) or 0
    if offset < 0 then offset = 0 end

    local page = {}
    for i = offset + 1, math.min(offset + limit, total) do
        table.insert(page, items[i])
    end

    return page, {
        count = #page,
        total = total,
        offset = offset,
        limit = limit,
        has_more = (offset + #page) < total,
    }
end

return Paging
