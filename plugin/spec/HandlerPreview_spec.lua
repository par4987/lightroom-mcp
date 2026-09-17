local helper = require 'spec_helper'

-- HandlerPreview renders a JPEG through photo:requestJpegThumbnail (async
-- callback), writes it under the previews dir and flags it for the MCP
-- server to inline. The spec fakes the filesystem (io.open + LrFileUtils)
-- and drives the callback synchronously so no polling is needed.
local function setup(opts)
    opts = opts or {}
    local catalog = helper.fakeCatalog(opts)

    local writtenFiles = {}
    local createdDirs = {}
    local directoryContents = opts.directoryContents or {}

    -- Keeps what was written so the handler's read-back size check (it reports
    -- bytes on disk, not buffer length) runs against something real.
    local fileData = {}
    local realOpen = io.open
    io.open = function(path, mode)
        if mode == "wb" then
            fileData[path] = ""
            return {
                write = function(_, data)
                    fileData[path] = fileData[path] .. data
                    table.insert(writtenFiles, { path = path, data = data })
                    return true
                end,
                close = function() return true end,
            }
        end
        if mode == "rb" and fileData[path] then
            local content = fileData[path]
            return {
                seek = function(_, whence)
                    if whence == "end" then return #content end
                    return 0
                end,
                close = function() return true end,
            }
        end
        return realOpen(path, mode)
    end

    helper.installImport({
        LrApplication = { activeCatalog = function() return catalog end },
        LrLogger = helper.defaultLrLogger(),
        LrTasks = { sleep = function() end },
        LrPathUtils = {
            child = function(parent, name)
                if parent == "HOME" then return name end
                return parent .. "/" .. name
            end,
            getStandardFilePath = function() return "HOME" end,
        },
        LrFileUtils = {
            createAllDirectories = function(path) table.insert(createdDirs, path) end,
            directoryEntries = function(_) return directoryContents end,
            delete = function() end,
        },
    })
    package.loaded.HandlerPreview = nil
    local Handler = require 'HandlerPreview'

    return {
        handler = Handler,
        catalog = catalog,
        writtenFiles = writtenFiles,
        createdDirs = createdDirs,
        restore = function() io.open = realOpen end,
    }
end

-- A real-enough JPEG: SOI, an SOF0 frame header carrying the dimensions, then
-- EOI. The handler both rejects non-JPEG buffers and READS these dimensions
-- back to tell a usable rendition from a stale cached thumbnail, so a fixture
-- without a frame header cannot exercise it.
--
-- Lightroom serves preview-pyramid levels rather than exact sizes, so the
-- defaults mirror a real 3:2 photo rendered one pyramid step above the
-- request (a 640px request comes back as 960x640).
local function jpegBytes(width, height, padding)
    width = width or 960
    height = height or 640
    local function u16(v)
        return string.char(math.floor(v / 256) % 256, v % 256)
    end
    local sof = "\255\192" .. u16(11) .. "\8" .. u16(height) .. u16(width)
        .. "\1" .. "\1\17\0"
    return "\255\216" .. sof .. (padding or "") .. "\255\217"
end

-- `renditions` models the SDK's real behaviour: requestJpegThumbnail invokes
-- its callback once PER RENDITION, improving as the render completes, and can
-- interleave a transient error. Default: a single good render.
local function previewPhoto(meta, renditions)
    meta = meta or {}
    meta.id = meta.id or 77
    meta.localIdentifier = meta.id
    meta.path = meta.path or "C:/photos/sunset.cr2"
    meta.fileName = meta.fileName or "sunset.cr2"
    local photo = helper.fakePhoto(meta)
    -- requestJpegThumbnail is not a metadata key: attach the mock method
    -- directly on the photo object (the handler calls it with a colon).
    photo.requestJpegThumbnail = function(_, _w, _h, callback)
        for _, rendition in ipairs(renditions or { { data = jpegBytes() } }) do
            callback(rendition.data, rendition.err)
        end
    end
    return photo, photo.localIdentifier
end

describe("HandlerPreview.getPhotoPreview", function()
    after_each(function()
        -- io.open is process-global; every test that stubbed it restores it.
    end)

    it("renders a medium preview and flags it for inline attachment", function()
        local photo, pid = previewPhoto({})
        local ctx = setup({ photos = { photo } })

        local r = ctx.handler.getPhotoPreview({ photo_id = pid })

        assert.is_true(r.success)
        assert.are.equal("image/jpeg", r.mime_type)
        assert.is_true(r.image_attached_by_server)
        assert.are.equal(640, r.size_px)
        assert.are.equal(#jpegBytes(), r.size_bytes)
        assert.are.equal(1, #ctx.writtenFiles)
        assert.are.equal(jpegBytes(), ctx.writtenFiles[1].data)
        assert.is_nil(r.warning)
        assert.is_not_nil(ctx.writtenFiles[1].path:find("preview_p77_640px_%d+%.jpg"))
        assert.are.same({ ".config/lightroom-mcp/previews" }, ctx.createdDirs)
        ctx.restore()
    end)

    it("accepts named and pixel sizes within bounds", function()
        local photo, pid = previewPhoto({})
        local ctx = setup({ photos = { photo } })

        local r = ctx.handler.getPhotoPreview({ photo_id = pid, size = "large" })
        assert.are.equal(1024, r.size_px)

        r = ctx.handler.getPhotoPreview({ photo_id = pid, size = 320 })
        assert.are.equal(320, r.size_px)
        ctx.restore()
    end)

    it("rejects unknown sizes and out-of-range pixels", function()
        local photo, pid = previewPhoto({})
        local ctx = setup({ photos = { photo } })

        assert.has_error(function()
            ctx.handler.getPhotoPreview({ photo_id = pid, size = "enormous" })
        end, "size must be 'small', 'medium', 'large' or a number of pixels")
        assert.has_error(function()
            ctx.handler.getPhotoPreview({ photo_id = pid, size = 16 })
        end, "size must be between 32 and 2048 pixels")
        ctx.restore()
    end)

    it("requires photo_id and errors when the photo is unknown", function()
        local photo = previewPhoto({})
        local ctx = setup({ photos = { photo } })

        assert.has_error(function() ctx.handler.getPhotoPreview({}) end,
            "photo_id is required")
        assert.has_error(function()
            ctx.handler.getPhotoPreview({ photo_id = 404 })
        end, "No photo matched photo_id")
        ctx.restore()
    end)

    it("surfaces render errors from Lightroom honestly", function()
        local photo, pid = previewPhoto({}, { { err = "render engine busy" } })
        local ctx = setup({ photos = { photo } })

        local ok, err = pcall(function()
            ctx.handler.getPhotoPreview({ photo_id = pid })
        end)
        ctx.restore()
        assert.is_false(ok)
        assert.is_not_nil(tostring(err):find("render engine busy", 1, true))
        -- The message carries what actually arrived, so a live failure is
        -- diagnosable instead of a bare string.
        assert.is_not_nil(tostring(err):find("callback(s) received", 1, true))
    end)

    -- The bug this file exists to prevent: requestJpegThumbnail fires more
    -- than once, and the first callback is NOT the final image.
    it("keeps the final rendition when a placeholder arrives first", function()
        local placeholder = jpegBytes(320, 213)
        local real = jpegBytes(960, 640, string.rep("x", 200))
        local photo, pid = previewPhoto({}, {
            { data = placeholder },
            { data = real },
        })
        local ctx = setup({ photos = { photo } })

        local r = ctx.handler.getPhotoPreview({ photo_id = pid })
        ctx.restore()

        assert.is_true(r.success)
        assert.are.equal(2, r.renditions_received)
        assert.are.equal(real, ctx.writtenFiles[#ctx.writtenFiles].data)
        assert.are.equal(#real, r.size_bytes)
    end)

    it("recovers when a transient error precedes the real render", function()
        local real = jpegBytes(960, 640)
        local photo, pid = previewPhoto({}, {
            { err = "error loading thumb" },
            { data = real },
        })
        local ctx = setup({ photos = { photo } })

        local r = ctx.handler.getPhotoPreview({ photo_id = pid })
        ctx.restore()

        -- The old handler threw on that first errorMsg and discarded the
        -- render that was still on its way.
        assert.is_true(r.success)
        assert.are.equal(real, ctx.writtenFiles[1].data)
    end)

    it("refuses to write a buffer that is not a complete JPEG", function()
        local photo, pid = previewPhoto({}, { { data = "not a jpeg at all" } })
        local ctx = setup({ photos = { photo } })

        local ok, err = pcall(function()
            ctx.handler.getPhotoPreview({ photo_id = pid })
        end)
        ctx.restore()
        assert.is_false(ok)
        assert.is_not_nil(tostring(err):find("no complete JPEG", 1, true))
        assert.are.equal(0, #ctx.writtenFiles)
    end)

    -- A failed render is not always a photo that cannot render: Lightroom says
    -- "error loading thumb" while it is rebuilding previews too. Measured on a
    -- photo whose preview pyramid a develop change had invalidated, where the
    -- same request succeeded a moment later.
    it("retries once when the first attempt errors, and succeeds", function()
        local attempts = 0
        local photo = helper.fakePhoto({
            id = 77, localIdentifier = 77,
            path = "C:/photos/sunset.cr2", fileName = "sunset.cr2",
        })
        photo.requestJpegThumbnail = function(_, _w, _h, callback)
            attempts = attempts + 1
            if attempts == 1 then
                callback(nil, "error loading thumb")
            else
                callback(jpegBytes(), nil)
            end
        end
        local ctx = setup({ photos = { photo } })

        local r = ctx.handler.getPhotoPreview({ photo_id = 77 })
        ctx.restore()

        assert.is_true(r.success)
        assert.are.equal(2, attempts)
    end)

    it("names the stale preview cache and the remedy when both attempts fail", function()
        local attempts = 0
        local photo = helper.fakePhoto({
            id = 77, localIdentifier = 77,
            path = "C:/photos/sunset.cr2", fileName = "sunset.cr2",
        })
        photo.requestJpegThumbnail = function(_, _w, _h, callback)
            attempts = attempts + 1
            callback(nil, "error loading thumb")
        end
        local ctx = setup({ photos = { photo } })

        local ok, err = pcall(function()
            ctx.handler.getPhotoPreview({ photo_id = 77 })
        end)
        ctx.restore()

        assert.is_false(ok)
        assert.are.equal(2, attempts)
        local message = tostring(err)
        -- The remedy, spelled out: this error sent a real session hunting
        -- through processes and restarts before the cause was found.
        assert.is_not_nil(message:find("Build Standard-Sized Previews", 1, true))
        assert.is_not_nil(message:find("Already retried once", 1, true))
    end)

    -- A different failure with a different fix: nothing came back at all.
    it("says a timeout means a blocked render, not a dead plugin", function()
        local photo, pid = previewPhoto({}, {})
        local ctx = setup({ photos = { photo } })
        local ok, err = pcall(function()
            ctx.handler.getPhotoPreview({ photo_id = pid })
        end)
        ctx.restore()
        assert.is_false(ok)
        assert.is_not_nil(tostring(err):find("NOT a dead", 1, true))
    end)

    it("times out when the callback never fires", function()
        local photo, pid = previewPhoto({}, {})
        local ctx = setup({ photos = { photo } })

        local ok, err = pcall(function()
            ctx.handler.getPhotoPreview({ photo_id = pid })
        end)
        ctx.restore()
        assert.is_false(ok)
        assert.is_not_nil(tostring(err):find("Timed out", 1, true))
    end)

    -- The two ways Lightroom hands back something other than what was asked
    -- for. Both were silent before; both are now on the response.
    it("warns when Lightroom serves a cached thumbnail smaller than requested", function()
        -- Measured live: after a develop change, a 640px request came back as
        -- the same 320x213 thumbnail as every other size — a render made
        -- BEFORE the edit.
        local photo, pid = previewPhoto({}, { { data = jpegBytes(320, 213) } })
        local ctx = setup({ photos = { photo } })

        local r = ctx.handler.getPhotoPreview({ photo_id = pid, size = "medium" })
        ctx.restore()

        assert.is_true(r.success)
        assert.is_false(r.size_usable)
        assert.are.equal(320, r.rendered_width)
        assert.is_not_nil(r.warning:find("SMALLER than", 1, true))
        assert.is_not_nil(r.warning:find("BEFORE", 1, true))
    end)

    it("warns when Lightroom falls back to the full-resolution original", function()
        -- Measured live: a 240px request came back as the full 6000x4000
        -- image at 705 KB, which is what rendered as a blank frame.
        local photo, pid = previewPhoto({}, { { data = jpegBytes(6000, 4000) } })
        local ctx = setup({ photos = { photo } })

        local r = ctx.handler.getPhotoPreview({ photo_id = pid, size = "small" })
        ctx.restore()

        assert.is_true(r.success)
        assert.is_false(r.size_usable)
        assert.are.equal(6000, r.rendered_width)
        assert.is_not_nil(r.warning:find("far larger", 1, true))
    end)

    it("reports a usable rendition without a warning", function()
        local photo, pid = previewPhoto({}, { { data = jpegBytes(960, 640) } })
        local ctx = setup({ photos = { photo } })

        local r = ctx.handler.getPhotoPreview({ photo_id = pid, size = "medium" })
        ctx.restore()

        assert.is_true(r.size_usable)
        assert.is_nil(r.warning)
        assert.are.equal(960, r.rendered_width)
        assert.are.equal(640, r.rendered_height)
    end)

    it("prunes old previews past the retention cap (best-effort)", function()
        local photo, pid = previewPhoto({})
        local stale = {}
        for i = 1, 80 do
            table.insert(stale, string.format("preview_p%d_640px_%010d.jpg", i, i))
        end
        local ctx = setup({
            photos = { photo },
            directoryContents = stale,
        })

        ctx.handler.getPhotoPreview({ photo_id = pid })
        ctx.restore()
        -- No crash and one new file written is the contract; the deletion
        -- itself is pcall-guarded in the handler.
        assert.are.equal(1, #ctx.writtenFiles)
    end)
end)
