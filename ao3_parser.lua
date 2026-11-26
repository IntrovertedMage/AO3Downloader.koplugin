local T = require("ffi/util").template
local util = require("util")

local AO3WebParser = {}

local unescape_map = {
    ["lt"] = "<",
    ["gt"] = ">",
    ["amp"] = "&",
    ["quot"] = '"',
    ["apos"] = "'",
}

local function unescape(str)
    return (str:gsub("(&(#?)([%d%a]+);)", function(orig, n, s)
        if unescape_map[s] then
            return unescape_map[s]
        elseif n == "#" then -- decimal or hexadecimal code point
            local codepoint = s:sub(1, 1) == "x" and tonumber(s:sub(2), 16) or tonumber(s)
            return util.unicodeCodepointToUtf8(codepoint)
        end
        return orig
    end))
end

local function trim(str)
    return (str:gsub("^%s*(.-)%s*$", "%1"))
end

local function stripTags(str)
    return (str:gsub("<[^>]+>", ""))
end

-- HTML to plain text, keeping <br> and paragraph breaks.
local function htmlToText(str)
    return unescape(trim(stripTags(str:gsub("<br%s*/?>", "\n"):gsub("</p>", "\n\n"))))
end

-- Unescaped text of el without inner tags, or default when el is nil.
local function textOf(el, default)
    if not el then
        return default
    end
    return unescape(stripTags(el:getcontent()))
end

local function toNumber(text)
    return tonumber((text:gsub(",", "")), 10)
end

-- Unescaped texts of the elements matching selector inside each of containers (nil entries allowed).
local function linkTexts(containers, selector)
    local texts = {}
    for _, container in ipairs(containers) do
        for _, link in ipairs(container:select(selector)) do
            table.insert(texts, unescape(link:getcontent()))
        end
    end
    return texts
end

local function joinedOrNil(list)
    return #list > 0 and table.concat(list, ", ") or nil
end

-- Normalizes a comma-separated value to trimmed, non-empty items joined by ", ".
local function joinTrimmed(value)
    local items = {}
    for item in (value or ""):gmatch("[^,]+") do
        local trimmed = trim(item)
        if trimmed ~= "" then
            table.insert(items, trimmed)
        end
    end
    return table.concat(items, ", ")
end

-- Count in the first link matching selector whose text reads "<label> (<n>)".
local function countLink(root, selector, label)
    for _, link in ipairs(root:select(selector)) do
        local count = link:getcontent():match(label .. "%s*%((%d+)%)")
        if count then
            return tonumber(count)
        end
    end
end

local function attribute(el, name)
    return el and el.attributes and el.attributes[name]
end

local function addWorks(list, elements)
    for _, element in ipairs(elements) do
        local work = AO3WebParser.parseWorkElement(element)
        if work then
            table.insert(list, work)
        end
    end
end

-- Returns the text of a form's error box, or nil when there is none.
function AO3WebParser.parseFormError(root)
    local error_element = root:select("div.#error")[1]
    return error_element and textOf(error_element)
end

function AO3WebParser.parseWorkSearchResults(root)
    local works = {}

    local heading = root:select("#main > h3")[1]
    local total = heading and heading:getcontent():match("^%s*([%d,]+) Found")
    if not total then
        heading = root:select("#main > h2")[1]
        local text = heading and heading:getcontent() or ""
        total = text:match("of%s*([%d,]+)%s*Works") or text:match("^%s*([%d,]+)%s*Works")
    end
    works.total = total and toNumber(total)

    addWorks(works, root:select("li.work"))
    return works
end

function AO3WebParser.parseUserBookmarks(root)
    local bookmarks = {}
    for _, element in ipairs(root:select("li.bookmark")) do
        local deleted = element:select(".message")[1]
        if deleted and deleted:getcontent():find("This has been deleted, sorry!") then
            table.insert(bookmarks, { title = "Deleted Work", is_deleted = true })
        else
            addWorks(bookmarks, { element })
        end
    end
    return bookmarks
end

function AO3WebParser.parseAccountHistory(root)
    local works = AO3WebParser.parseWorkSearchResults(root)
    works.total = nil -- the history page has no reliable count
    return works
end

function AO3WebParser.parseUserSeriesPage(root)
    local series_list = {}
    for _, element in ipairs(root:select("li.series")) do
        local titleElement = element:select(".heading > a")[1]
        if titleElement then
            local summaryElement = element:select(".summary")[1]
            local wordCountElement = element:select("dd.words")[1]
            local workCountElement = element:select("dd.works")[1]
            local bookmarkCountElement = element:select("dd.bookmarks")[1]
            table.insert(series_list, {
                id = tonumber(titleElement.attributes.href:match("/series/(%d+)")),
                title = titleElement:getcontent(),
                author = textOf(element:select(".heading > a[rel='author']")[1]),
                date_posted = textOf(element:select(".datetime")[1], ""),
                fandoms = linkTexts({ element }, ".fandoms > a"),
                warnings = linkTexts({ element }, ".warnings > strong > a"),
                relationships = linkTexts({ element }, ".relationships > a"),
                characters = linkTexts({ element }, ".characters > a"),
                tags = linkTexts({ element }, ".freeforms > a"),
                summary = summaryElement and htmlToText(summaryElement:getcontent()),
                word_count = wordCountElement and toNumber(wordCountElement:getcontent()) or 0,
                work_count = workCountElement and toNumber(workCountElement:getcontent()) or 0,
                bookmark_count = bookmarkCountElement and toNumber(bookmarkCountElement:getcontent()) or 0,
            })
        end
    end
    return series_list
end

function AO3WebParser.parseUserCollectionsPage(root)
    local collection_list = {}
    for _, element in ipairs(root:select("li.collection")) do
        local titleElement = element:select(".heading > a:not([class])")[1]
        if titleElement then
            local authors = linkTexts({ element }, ".heading > a.owner")
            for _, mod in ipairs(linkTexts({ element }, ".heading > a.mod")) do
                table.insert(authors, mod)
            end

            local typeElement = element:select("p.type")[1]
            local type = typeElement and trim(typeElement:getcontent()) or ""
            local summaryElement = element:select(".summary")[1]
            local workCountElement = element:select("dd.works > a")[1]

            table.insert(collection_list, {
                id = titleElement.attributes.href:match("/collections/([%w_-]+)"),
                title = titleElement:getcontent(),
                author = joinedOrNil(authors),
                date_posted = textOf(element:select(".datetime")[1], ""),
                tags = linkTexts({ element }, ".tags > a.tag"),
                summary = (type ~= "" and type .. " " or "")
                    .. (summaryElement and htmlToText(summaryElement:getcontent()) or ""),
                work_count = workCountElement and toNumber(workCountElement:getcontent()) or 0,
            })
        end
    end
    return collection_list
end

function AO3WebParser.parseWorkElement(element)
    local titleElement = element:select("h4.heading > a")[1] or element:select("h4.heading")[1]
    if not titleElement then
        return nil
    end

    local href = titleElement.attributes.href or ""
    local summaryElement = element:select(".summary")[1]
    local tags = linkTexts(element:select(".tags > .freeforms"), "a")

    return {
        id = tonumber(href:match("/works/(%d+)")),
        title = trim(textOf(titleElement)),
        rating = attribute(element:select(".rating")[1], "title") or "N/A",
        category = attribute(element:select(".category")[1], "title") or "N/A",
        iswip = attribute(element:select(".iswip")[1], "title") or "N/A",
        author = joinedOrNil(linkTexts({ element }, ".heading > a[rel='author']")),
        gifted_to = joinedOrNil(linkTexts({ element }, ".heading > a[href$='/gifts']")),
        summary = summaryElement and htmlToText(summaryElement:getcontent()) or "No summary available",
        tags = tags,
        relationships = linkTexts(element:select(".tags > .relationships"), "a"),
        characters = linkTexts(element:select(".tags > .characters"), "a"),
        warnings = linkTexts(element:select(".tags > .warnings"), "strong > a"),
        fandoms = linkTexts({ element:select(".fandoms")[1] }, "a"),
        date = textOf(element:select(".datetime")[1], "N/A"),
        language = textOf(element:select("dd.language")[1], "N/A"),
        words = textOf(element:select("dd.words")[1], "N/A"),
        chapters = textOf(element:select("dd.chapters")[1], "N/A"),
        hits = textOf(element:select("dd.hits")[1], "0"),
        comments = textOf(element:select("dd.comments")[1], "0"),
        kudos = textOf(element:select("dd.kudos")[1], "0"),
        bookmarks = textOf(element:select("dd.bookmarks")[1], "0"),
        is_restricted = element:select("img[title='Restricted']")[1] ~= nil,
    }
end

function AO3WebParser.parseTagSearchResults(root)
    local tags = {}
    for _, element in ipairs(root:select("li > span > a.tag")) do
        local name = element:getcontent()
        -- the use count is the last parenthesised number in the parent span
        local uses = element.parent and element.parent:getcontent():match(".*%((%d+)%)$")
        if name and uses then
            table.insert(tags, { name = unescape(name), uses = tonumber(uses) })
        end
    end
    return tags
end

local function parseChapters(root)
    local chapters = {}
    for _, option in ipairs(root:select("#chapter_index > li > form > p > select > option")) do
        if option.attributes.value then
            table.insert(chapters, { id = option.attributes.value, name = option:getcontent() })
        end
    end
    if #chapters > 0 then
        return chapters
    end

    -- single-page works list chapters as headings instead of a select
    for _, heading in ipairs(root:select(".chapter.preface.group > h3.title")) do
        local content = heading:getcontent()
        local index = #chapters + 1
        local title = content:match("</a>:%s*(.+)") or ("Chapter " .. index)
        table.insert(chapters, { id = content:match("/chapters/(%d+)"), name = index .. ". " .. title })
    end
    return chapters
end

function AO3WebParser.parseWorkPage(root)
    local summaryElement = root:select(".summary > blockquote")[1]
    local tags = linkTexts({ root:select(".freeform > ul")[1] }, "li > a")

    local markedForLaterElement = root:select(".mark > form > button")[1]
    local subscriptionForm = root:select(".subscribe > form")[1]
    local bookmarkForm = root:select("#bookmark-form > form")[1]
    local subscriptionFormId = attribute(subscriptionForm, "id")
    local bookmarkFormAction = attribute(bookmarkForm, "action")

    local epub_href
    for _, link in ipairs(root:select(".download > .expandable > li > a")) do
        if unescape(link:getcontent()):lower() == "epub" then
            epub_href = link.attributes.href
            break
        end
    end

    local statusElement = root:select("dt.status")[1]
    local iswip = statusElement and statusElement:getcontent():gsub(":", "")
    if iswip == "Completed" then
        iswip = "Complete"
    elseif iswip == "Updated" then
        iswip = "Work in Progress"
    end

    local wordCountElement = root:select("dd.words")[1]
    local ratingElement = root:select(".rating > ul > li > a")[1]
    local categoryElement = root:select(".category > ul > li > a")[1]

    return {
        title = trim(textOf(root:select(".title")[1], "Unknown title")),
        author = table.concat(linkTexts({ root }, "a[rel='author']"), ", "),
        gifted_to = table.concat(linkTexts({ root }, ".associations > li > a[href$='/gifts']"), ", "),
        chapterData = parseChapters(root),
        summary = summaryElement and htmlToText(summaryElement:getcontent()) or "No summary available",
        tags = tags,
        relationships = linkTexts({ root:select(".relationship > ul")[1] }, "li > a"),
        characters = linkTexts({ root:select(".character > ul")[1] }, "li > a"),
        warnings = linkTexts({ root:select(".warning > ul")[1] }, "li > a"),
        fandoms = linkTexts({ root:select(".fandom > ul")[1] }, "li > a"),
        published = textOf(root:select("dd.published")[1], "Unknown date"),
        updated = textOf(root:select("dd.status")[1], "Unknown date"),
        wordcount = wordCountElement and wordCountElement:getcontent():gsub(",", "") or "unknown",
        chapters = textOf(root:select("dd.chapters")[1], "Unknown chapters"),
        language = textOf(root:select("dd.language")[1], "Unknown language"),
        epub_href = epub_href, -- site-relative; the client makes it absolute
        hits = textOf(root:select("dd.hits")[1], "0"),
        kudos = textOf(root:select("dd.kudos")[1], "0"),
        comments = textOf(root:select("dd.comments")[1], "0"),
        bookmarks = textOf(root:select("dd.bookmarks > a")[1], "0"),
        rating = ratingElement and ratingElement:getcontent(),
        category = categoryElement and categoryElement:getcontent(),
        iswip = iswip,
        markedForLater = markedForLaterElement ~= nil and unescape(markedForLaterElement:getcontent()) == "Mark as Read",
        subscriptionID = subscriptionFormId and subscriptionFormId:match("edit_subscription_(%d+)") or false,
        bookmarkID = bookmarkFormAction and bookmarkFormAction:match("/bookmarks/(%d+)") or false,
        bookmarkContent = AO3WebParser.parseUsersWorkBookmark(root),
    }
end

function AO3WebParser.parseAuthorName(name)
    if name:find("%(") and name:find("%)") then
        return name:match("%((.-)%)"), name:match("^(.-)%s*%(")
    end
    return name, name
end

function AO3WebParser.parseUserPage(root)
    local fandom_list = {}
    for _, fandom in ipairs(root:select("div #user-fandoms > ol > li")) do
        local link = fandom:select("a")[1]
        local count = fandom:getcontent():gsub("<a[^>]*>.-</a>", ""):match("%((%d+)%)")
        table.insert(fandom_list, {
            name = unescape(link:getcontent()),
            count = count and tonumber(count) or 0,
            id = link.attributes.href:match("fandom_id=(%d+)"),
        })
    end

    local heading = root:select("div.primary > h2.heading")[1]
    local author_full = heading and unescape(heading:getcontent()):gsub("%s+", "") or "Unknown User"

    local username, pseud = AO3WebParser.parseAuthorName(author_full)

    -- the logged-in header can repeat these links without a count, so countLink skips to one that has it
    return {
        username = username,
        pseud = pseud,
        fandoms = fandom_list,
        total_pseuds = countLink(root, T("a[href$='%1/pseuds']", username), "All Pseuds") or 1,
        total_works = countLink(root, T("[href$='%1/works']", pseud), "Works") or 0,
        total_series = countLink(root, T("[href$='%1/series']", pseud), "Series") or 0,
        total_bookmarks = countLink(root, T("[href$='%1/bookmarks']", pseud), "Bookmarks") or 0,
        total_collections = countLink(root, T("[href$='%1/collections']", username), "Collections") or 0,
        total_gifts = countLink(root, T("[href$='%1/gifts']", username), "Gifts") or 0,
    }
end

function AO3WebParser.parseUserPseuds(root)
    local pseuds = {}
    for _, element in ipairs(root:select("li.pseud")) do
        local pseudElement = element:select("h4.heading > a")[1]
        if pseudElement then
            local worksElement = element:select("h5.heading > a[href$='/works']")[1]
            local recsElement = element:select("h5.heading > a[href$='recs_only=true']")[1]
            table.insert(pseuds, {
                name = unescape(pseudElement:getcontent()),
                works_count = worksElement and toNumber(worksElement:getcontent():match("([%d,]+) work")) or 0,
                recs_count = recsElement and toNumber(recsElement:getcontent():match("([%d,]+) rec")) or 0,
            })
        end
    end
    return pseuds
end

-- Returns the account's pseud ID, or false when the edit form is missing.
function AO3WebParser.parseAccountPseudID(root)
    local id = attribute(root:select(".edit_pseud")[1], "id")
    return id and id:match("edit_pseud_(%d+)") or false
end

function AO3WebParser.parseUserSearchResults(root)
    local users = {}
    for _, element in ipairs(root:select("li.user")) do
        local names = element:select("h4.heading > a")
        local username, pseud
        if names[2] == nil then
            username = unescape(names[1]:getcontent())
            pseud = username
        else
            username = unescape(names[2]:getcontent())
            pseud = names[1]:getcontent()
        end

        local worksElement = element:select("h5.heading > a[href$='/works']")[1]
        local bookmarksElement = element:select("h5.heading > a[href$='/bookmarks']")[1]
        table.insert(users, {
            username = username,
            pseud = pseud,
            works_count = worksElement and toNumber(worksElement:getcontent():match("([%d,]+) works")) or 0,
            bookmarks_count = bookmarksElement and toNumber(bookmarksElement:getcontent():match("([%d,]+) bookmarks")) or 0,
        })
    end
    return users
end

function AO3WebParser.parseUsersWorkBookmark(root)
    local form = root:select("#bookmark-form > form")[1]
    if not form then
        return { notes = "", tags = "", collections = "", private = false, rec = false }
    end

    local notesElement = form:select("textarea#bookmark_notes")[1]
    return {
        notes = notesElement and htmlToText(notesElement:getcontent()) or "",
        -- tags and collections are comma-separated text inputs
        tags = joinTrimmed(attribute(form:select("input#bookmark_tag_string")[1], "value")),
        collections = joinTrimmed(attribute(form:select("input#bookmark_collection_names")[1], "value")),
        private = attribute(form:select("input#bookmark_private")[1], "checked") == "checked",
        rec = attribute(form:select("input#bookmark_rec")[1], "checked") == "checked",
    }
end

return AO3WebParser
