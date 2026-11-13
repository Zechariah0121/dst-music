-- Pure timing/UTF-8 helpers: seconds throughout; no fabricated word timestamps.
local M = {}
function M.Characters(text)
    local result = {}
    for c in tostring(text or ""):gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        result[#result + 1] = c
    end
    return result
end
function M.FindLine(lines, position)
    -- Binary lookup keeps large lyric files cheap. Gaps remain silent.
    local lo, hi, found = 1, #lines, nil
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if (tonumber(lines[mid].start) or 0) <= position then found = mid; lo = mid + 1 else hi = mid - 1 end
    end
    if found then
        local finish = tonumber(lines[found]["end"]) or (lines[found + 1] and lines[found + 1].start) or math.huge
        if position < finish then return found end
    end
end
local function Codepoint(char)
    local a, b, c, d = char:byte(1, 4)
    if not a then return 0 end
    if a < 128 then return a end
    if a < 224 then return (a - 192) * 64 + (b or 128) - 128 end
    if a < 240 then return (a - 224) * 4096 + ((b or 128) - 128) * 64 + (c or 128) - 128 end
    return (a - 240) * 262144 + ((b or 128) - 128) * 4096 + ((c or 128) - 128) * 64 + (d or 128) - 128
end
local function Latin(char)
    local n = Codepoint(char)
    return char:match("[%w]") ~= nil or (n >= 192 and n <= 687 and n ~= 215 and n ~= 247)
end

-- Presentation times are deliberately separate from source start/finish/word.
-- YRC can split English into syllables: contiguous Latin letters pop together at
-- the first source timestamp, while CJK keeps the supplied per-character times.
-- LRC has no word timing. Its decorative fallback follows Dango's splitWords
-- (Latin tokens separated by whitespace; CJK in pairs), never fabricating words.
function M.Reveals(glyphs, precise, line, nextStart)
    local groups, group = {}, nil
    local function Add(g, new)
        if new or not group then
            group = {text = "", start = g.start, finish = g.finish, cjk = 0, latin = Latin(g.text)}
            groups[#groups + 1] = group
        end
        group.text = group.text .. g.text
        group.finish = math.max(group.finish, g.finish)
        g.revealWord = group
    end
    for i, g in ipairs(glyphs) do
        if g.breakBefore then group = nil end
        local space = g.space
        local previous, following = glyphs[i - 1], glyphs[i + 1]
        if space then
            group = nil
        elseif precise then
            local connector = (g.text == "'" or g.text == "’" or g.text == "-")
                and previous and following and Latin(previous.text) and Latin(following.text)
            local prevConnector = previous and (previous.text == "'" or previous.text == "’" or previous.text == "-")
            local join = (Latin(g.text) or connector) and previous
                and (Latin(previous.text) or prevConnector) and group
            local trailing = group and group.latin and (g.text:match("[%p]")
                or (Codepoint(g.text) >= 0x2000 and Codepoint(g.text) <= 0x206F))
            Add(g, not (join or trailing))
        else
            local cjk = Codepoint(g.text) >= 0x2E80
            Add(g, not group or (cjk and group.cjk == 0) or (not cjk and group.cjk > 0))
            if cjk then group.cjk = group.cjk + 1; if group.cjk >= 2 then group = nil end end
        end
    end
    local start = tonumber(line.start) or 0
    local duration = math.max(.3, (tonumber(nextStart) or tonumber(line["end"]) or start + 3) - start)
    local span = math.min(duration * .75, #groups * .33)
    for i, entry in ipairs(groups) do
        if not precise then entry.start = start + span * (i - 1) / math.max(1, #groups) end
    end
    local reveal = math.min(math.max(#glyphs * .055, .25), math.max(.4, duration) * .6)
    for i, g in ipairs(glyphs) do
        g.popStart = g.revealWord and g.revealWord.start or g.start
        g.fadeStart = start + (i - 1) / math.max(1, #glyphs) * reveal
    end
end

function M.Appearance(info, position, wordPop, suppressBefore)
    local at = wordPop and info.popStart or info.fadeStart
    local elapsed = position - at
    if elapsed < 0 or info.space then return false, 0, 1, 0 end
    -- Seeking or receiving lyrics late reveals the already elapsed tokens without
    -- replaying their entrance. Future tokens still use their normal schedule.
    if suppressBefore and at <= suppressBefore then return true, 1, 1, 0 end
    if wordPop then
        local t = elapsed / .16
        local back = math.max(0, 1 - t)
        local alpha = math.min(1, t * 3)
        return alpha > .02, alpha, 1 + .55 * back * back, 0
    end
    local alpha = math.min(1, elapsed / .18)
    alpha = alpha * alpha * (3 - 2 * alpha)
    return alpha > .02, alpha, 1, (1 - alpha) * 15
end

function M.Glyphs(line, timing, split, measure, nextStart)
    local glyphs, forcedBreak, pendingBreak = {}, nil, false
    local words = timing == "word" and line.words or nil
    local precise = words ~= nil and #words > 0
    local segments = precise and words or {{text = line.text or "", start = line.start, ["end"] = line["end"]}}
    for _, word in ipairs(segments) do
        for _, char in ipairs(M.Characters(word.text)) do
            if char == "\n" then
                if split and forcedBreak == nil then
                    forcedBreak, pendingBreak = #glyphs, true
                else char = " " end
            end
            if char ~= "\n" and #glyphs < 96 then
                glyphs[#glyphs + 1] = {text = char, space = char:match("%s") ~= nil,
                    start = tonumber(word.start) or tonumber(line.start) or 0,
                    finish = tonumber(word["end"]) or tonumber(line["end"]) or math.huge,
                    word = word, precise = precise, breakBefore = pendingBreak}
                pendingBreak = false
            end
        end
    end
    M.Reveals(glyphs, precise, line, nextStart)
    local total = 0
    for _, g in ipairs(glyphs) do
        g.advance = measure and measure(g.text) or (#g.text > 1 and 28 or (g.text == " " and 7 or 14))
        g.advance = math.max(0, g.advance)
        total = total + g.advance
    end
    local boundary = split and forcedBreak or nil
    if split and not boundary and total > 480 then
        local prefix, score = 0, math.huge
        for i = 1, #glyphs - 1 do
            local g, nextg = glyphs[i], glyphs[i + 1]
            prefix = prefix + g.advance
            -- Latin syllables retain one row even when word timestamps split them.
            -- Spaces and CJK glyph boundaries are valid wrap points.
            local canBreak = g.space or (#g.text > 1 and #nextg.text > 1)
            if canBreak and math.abs(prefix - total / 2) < score then
                boundary, score = i, math.abs(prefix - total / 2)
            end
        end
    end
    local widths, row = {[0] = 0, [1] = 0}, 0
    for i, g in ipairs(glyphs) do
        row = boundary and i > boundary and 1 or 0
        g.row, g.x = row, widths[row] + g.advance / 2
        widths[row] = widths[row] + g.advance
    end
    for _, g in ipairs(glyphs) do g.x = g.x - widths[g.row] / 2; g.y = -g.row * 36 end
    return glyphs, precise, row, math.max(widths[0], widths[1])
end
return M
