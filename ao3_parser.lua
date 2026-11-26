local logger = require("logger")
local T = require("ffi/util").template
local Config = require("fanfic_config")
local encodeHelper = require("ao3_http").encodeHelper

local function getAO3URL()
    return Config:readSetting("AO3_domain")
end

local AO3WebParser = {}

function AO3WebParser:parseWorkSearchResults(root)
    local works = {}
    local elements = root:select("li.work")

    local count = 1

    local resultsCountElement = root:select("#main > h3")[1]
    if resultsCountElement then
        local resultsText = resultsCountElement:getcontent()
        local totalWorks = resultsText:match("^%s*([%d,]+) Found")
        if totalWorks then
            totalWorks = tonumber(totalWorks:gsub(",", ""), 10)
            works["total"] = totalWorks
        end
    end

    if not works["total"] then
        local resultsCountElement = root:select("#main > h2")[1]
        if resultsCountElement then
            local resultsText = resultsCountElement:getcontent()
            local totalWorks = resultsText:match("of%s*([%d,]+)%s*Works")
            if not totalWorks then
                totalWorks = resultsText:match("^%s*([%d,]+)%s*Works")
            end
            if totalWorks then
                totalWorks = totalWorks:gsub(",", "")
                works["total"] = tonumber(totalWorks)
            end
        end
    end


    for _, element in ipairs(elements) do
        local work = self:parseWorkElement(element)
        if work then
            table.insert(works, count, work)
            count = count + 1
        end
    end

    return works
end

function AO3WebParser:parseUserBookmarks(root)
    local bookmarks = {}
    local elements = root:select("li.bookmark")

    local count = 1

    for _, element in ipairs(elements) do
        -- Check if bookmark is for deleted fic, if so, set title accordingly
        local deletedElement = element:select(".message")[1]
        if deletedElement and deletedElement:getcontent():find("This has been deleted, sorry!") then
            local work = {}
            work.title = "Deleted Work"
            work.id = nil
            work.is_deleted = true
            table.insert(bookmarks, count, work)
            count = count + 1

        else
            local work = self:parseWorkElement(element)
            if work then
                table.insert(bookmarks, count, work)
                count = count + 1
            end
        end
    end

    return bookmarks

end

function AO3WebParser:parseUserSeriesPage(root)
    local series_list = {}
    local elements = root:select("li.series")

    local count = 1

    for _, element in ipairs(elements) do
        local titleElement = element:select(".heading > a")[1]
        if titleElement then
            local href = titleElement.attributes.href
            local id = tonumber(href:match("/series/(%d+)"))
            local title = titleElement:getcontent()

            local authorElement = element:select(".heading > a[rel='author']")[1]
            local author = authorElement and encodeHelper:parseToCodepoints(authorElement:getcontent()) or nil

            local dateElement = element:select(".datetime")[1]

            local date_posted = dateElement and encodeHelper:parseToCodepoints(dateElement:getcontent()) or ""

            local fandomElements = element:select(".fandoms > a")
            local fandoms = {}
            for _, fandomElement in pairs(fandomElements) do
                local content = fandomElement:getcontent()
                if content then
                    table.insert(fandoms, encodeHelper:parseToCodepoints(content))
                end
            end

            local warningElements = element:select(".warnings > strong > a")

            local warnings = {}

            for _, warningElement in pairs(warningElements) do
                local content = warningElement:getcontent()
                if content then
                    table.insert(warnings, encodeHelper:parseToCodepoints(content))
                end
            end

            local relationshipsElements = element:select(".relationships > a")
            local relationships = {}
            for _, relationshipElement in pairs(relationshipsElements) do
                local content = relationshipElement:getcontent()
                if content then
                    table.insert(relationships, encodeHelper:parseToCodepoints(content))
                end
            end

            local charactersElements = element:select(".characters > a")
            local characters = {}

            for _, characterElement in pairs(charactersElements) do
                local content = characterElement:getcontent()
                if content then
                    table.insert(characters, encodeHelper:parseToCodepoints(content))
                end
            end

            local otherTagsElements = element:select(".freeforms > a")
            local other_tags = {}

            for _, otherTagElement in pairs(otherTagsElements) do
                local content = otherTagElement:getcontent()
                if content then
                    table.insert(other_tags, encodeHelper:parseToCodepoints(content))
                end
            end

            local summaryElement = element:select(".summary")[1]
            local summary = summaryElement and encodeHelper:parseFromHTML(summaryElement:getcontent())

            local wordCountElement = element:select("dd.words")[1]
            logger.dbg(wordCountElement and wordCountElement:getcontent():gsub(",", "") or "No word count element found")
            local word_count = wordCountElement and tonumber(wordCountElement:getcontent():gsub(",", ""), 10) or 0

            local workCountElement = element:select("dd.works")[1]
            local work_count = workCountElement and tonumber(workCountElement:getcontent():gsub(",", ""), 10) or 0

            local bookmark_countElement = element:select("dd.bookmarks")[1]
            local bookmark_count = bookmark_countElement and tonumber(bookmark_countElement:getcontent():gsub(",", ""), 10) or 0

            local series = {
                id = id,
                title = title,
                author = author,
                date_posted = date_posted,
                fandoms = fandoms,
                warnings = warnings,
                relationships = relationships,
                characters = characters,
                tags = other_tags,
                summary = summary,
                word_count = word_count,
                work_count = work_count,
                bookmark_count = bookmark_count,
            }

            table.insert(series_list, count, series)
            count = count + 1
        end
    end

    return series_list
end

function AO3WebParser:parseUserCollectionsPage(root)
    local collection_list = {}
    local elements = root:select("li.collection")

    local count = 1

    for _, element in ipairs(elements) do
        local titleElement = element:select(".heading > a:not([class])")[1]
        if titleElement then

            --works
            --bookmarked items
            --prompts
            --challenges/subcollections

            local href = titleElement.attributes.href
            local id = href:match("/collections/([%w_-]+)")
            local title = titleElement:getcontent()

            local authorElements = element:select(".heading > a.owner")
            local author_table = {}
            for _, author in pairs(authorElements) do
                table.insert(author_table, encodeHelper:parseToCodepoints(author:getcontent()))
            end
            authorElements = element:select(".heading > a.mod")
            for _, author in pairs(authorElements) do
                table.insert(author_table, encodeHelper:parseToCodepoints(author:getcontent()))
            end
            local author = #author_table > 0 and table.concat(author_table, ", ") or nil

            local dateElement = element:select(".datetime")[1]

            local date_posted = dateElement and encodeHelper:parseToCodepoints(dateElement:getcontent()) or ""

            local tagElements = element:select(".tags > a.tag")
            local tags = {}

            for _, tagElement in pairs(tagElements) do
                local content = tagElement:getcontent()
                if content then
                    table.insert(tags, encodeHelper:parseToCodepoints(content))
                end
            end

            local typeElement = element:select("p.type")[1]
            local type = typeElement:getcontent():gsub("^%s*(.-)%s*$", "%1")

            local summaryElement = element:select(".summary")[1]
            local summary = (type and (type.." ") or "") .. (summaryElement and encodeHelper:parseToCodepoints(summaryElement:getcontent()
                :gsub("<br%s*/?>", "\n") -- Replace <br> tags with new lines
                :gsub("</p>", "\n\n") -- Add double new lines for paragraph breaks
                :gsub("<[^>]+>", "") -- Remove other HTML tags
                :gsub("^%s*(.-)%s*$", "%1") -- Trim whitespace) or ""
            ))

            local workCountElement = element:select("dd.works > a")[1]
            local work_count = workCountElement and tonumber(workCountElement:getcontent():gsub(",", ""), 10) or 0

            local collection = {
                id = id,
                title = title,
                author = author,
                date_posted = date_posted,
                tags = tags,
                summary = summary,
                work_count = work_count,
            }

            table.insert(collection_list, count, collection)
            count = count + 1
        end
    end

    return collection_list
end

function AO3WebParser:parseAccountHistory(root)
    local works = {}
    local elements = root:select("li.work")

    local count = 1

    for _, element in ipairs(elements) do
        local work = self:parseWorkElement(element)
        if work then
            table.insert(works, count, work)
            count = count + 1
        end
    end

    works["total"] = -1

    return works
end

function AO3WebParser:parseWorkElement(element)
    local titleElement = element:select("h4.heading > a")[1] or element:select("h4.heading")[1]
    local restrictedElement = element:select("img[title='Restricted']")[1]
    local authorElements = element:select(".heading > a[rel='author']")
    local giftElements = element:select(".heading > a[href$='/gifts']")
    local summaryElement = element:select(".summary")[1]
    local tagsElement = element:select(".tags > .freeforms")
    local relationshipsElement = element:select(".tags > .relationships")
    local charactersElement = element:select(".tags > .characters")
    local warningsElement = element:select(".tags > .warnings")
    local fandomsElement = element:select(".fandoms")[1]
    local dateElement = element:select(".datetime")[1]
    local languageElement = element:select("dd.language")[1]
    local wordsElement = element:select("dd.words")[1]
    local chaptersElement = element:select("dd.chapters")[1]
    local hitsElement = element:select("dd.hits")[1]
    local commentsElement = element:select("dd.comments")[1]
    local kudosElement = element:select("dd.kudos")[1]
    local bookmarksElement = element:select("dd.bookmarks")[1]
    local ratingElement = element:select(".rating")[1]
    local categoryElement = element:select(".category")[1]
    local iswipElement = element:select(".iswip")[1]

    if titleElement then
        -- Extract the work ID from the href attribute
        local href = titleElement.attributes.href or ""
        local id = tonumber(href:match("/works/(%d+)")) -- Extract the numeric ID and convert to number
        local isRestricted = restrictedElement and true or false -- Set to true if restrictedElement exists, otherwise false

        -- Extract and clean tags
        local tags = {}
        if tagsElement then
            for __, tagset in ipairs(tagsElement) do
                for _, tag in ipairs(tagset:select("a")) do
                    local content = encodeHelper:parseToCodepoints(tag:getcontent())
                    if content then
                        table.insert(tags, content)
                    end
                end
            end
        end

        -- Extract and clean relationships
        local relationships = {}
        if relationshipsElement then
            for __, relationshipset in ipairs(relationshipsElement) do
                for _, relationship in ipairs(relationshipset:select("a")) do
                    local content = encodeHelper:parseToCodepoints(relationship:getcontent())
                    if content then
                        table.insert(relationships, content)
                    end
                end
            end
        end

        -- Extract and clean characters
        local characters = {}
        if charactersElement then
            for __, characterset in ipairs(charactersElement) do
                for _, character in ipairs(characterset:select("a")) do
                    local content = encodeHelper:parseToCodepoints(character:getcontent())
                    if content then
                        table.insert(characters, content)
                    end
                end
            end
        end

        -- Extract and clean warnings
        local warnings = {}
        if warningsElement then
            for __, warningset in ipairs(warningsElement) do
                for _, warning in ipairs(warningset:select("strong > a")) do
                    local content = encodeHelper:parseToCodepoints(warning:getcontent())
                    if content then
                        table.insert(warnings, content)
                    end
                end
            end
        end

        -- Extract and clean fandoms
        local fandoms = {}
        if fandomsElement then
            for _, fandom in ipairs(fandomsElement:select("a")) do
                local content = encodeHelper:parseToCodepoints(fandom:getcontent())
                if content then
                    table.insert(fandoms, content)
                end
            end
        end

        -- Extract additional metadata
        local date = dateElement and encodeHelper:parseToCodepoints(dateElement:getcontent()) or "N/A"
        local language = languageElement and encodeHelper:parseToCodepoints(languageElement:getcontent()) or "N/A"
        local words = wordsElement and encodeHelper:parseToCodepoints(wordsElement:getcontent()) or "N/A"
        local chapters = chaptersElement and encodeHelper:parseToCodepoints(chaptersElement:getcontent():gsub("<[^>]+>", ""))
            or "N/A"
        local hits = hitsElement and encodeHelper:parseToCodepoints(hitsElement:getcontent():gsub("<[^>]+>", "")) or "0"
        local comments = commentsElement and encodeHelper:parseToCodepoints(commentsElement:getcontent():gsub("<[^>]+>", ""))
            or "0"
        local kudos = kudosElement and encodeHelper:parseToCodepoints(kudosElement:getcontent():gsub("<[^>]+>", "")) or "0"
        local bookmarks = bookmarksElement and encodeHelper:parseToCodepoints(bookmarksElement:getcontent():gsub("<[^>]+>", ""))
            or "0"
        local rating = ratingElement and ratingElement.attributes["title"] or "N/A"
        local category = categoryElement and categoryElement.attributes["title"] or "N/A"
        local iswip = iswipElement and iswipElement.attributes["title"] or "N/A"
        local author_table = {}
        for _, author in pairs(authorElements) do
            table.insert(author_table, encodeHelper:parseToCodepoints(author:getcontent()))
        end

        local author = #authorElements > 0 and table.concat(author_table, ", ") or nil

        local giftedTo_table = {}
        for _, gift in pairs(giftElements) do
            table.insert(giftedTo_table, encodeHelper:parseToCodepoints(gift:getcontent()))
        end

        local gifted_to = #giftElements > 0 and table.concat(giftedTo_table, ", ") or nil
        local tags = #tags > 0 and table.concat(tags, ", ") or "N/A"

        -- Remove HTML formatting, replace <br> with new lines, and preserve paragraph formatting
        local summary = summaryElement
            and encodeHelper:parseFromHTML(summaryElement:getcontent())
            or "No summary available"

        -- Remove leading and trailing whitespace from the title
        local title = titleElement
            and encodeHelper:parseToCodepoints(titleElement:getcontent():gsub("<[^>]+>", ""):gsub("^%s*(.-)%s*$", "%1"))
            or "Unknown title" -- Trim whitespace and remove internal tags

        -- Create the work object
        local work = {
            id = id,
            title = title,
            rating = rating,
            category = category,
            iswip = iswip,
            link = getAO3URL() .. href,
            author = author,
            gifted_to = gifted_to,
            summary = summary,
            tags = tags,
            relationships = relationships or {},
            characters = characters or {},
            warnings = warnings or {},
            fandoms = fandoms or {},
            date = date,
            language = language,
            words = words,
            chapters = chapters,
            hits = hits,
            comments = comments,
            kudos = kudos,
            bookmarks = bookmarks,
            is_restricted = isRestricted, -- Add the restricted status
        }

        return work
    end
    return nil
end

function AO3WebParser:parseTagSearchResults(root)
    local fandom_elements = root:select("li > span > a.tag") -- Adjust the selector based on AO3's HTML structure
--
    local fandoms = {}
    for _, element in ipairs(fandom_elements) do
        -- Extract the fandom name
        local fandom_name = element:getcontent()

        -- Extract the number of uses from the parent `<span>` element
        local parent_span = element.parent
        if parent_span then
            -- Remove the fandom name from the parent span content
            local parent_content = parent_span:getcontent()
            -- Extract the last set of parentheses
            local uses_text = parent_content:match(".*%((%d+)%)$") -- Match the last number in parentheses

            if fandom_name and uses_text then
                table.insert(fandoms, {
                    name = encodeHelper:parseToCodepoints(fandom_name),
                    uses = tonumber(uses_text),
                })
            end
        end
    end

    return fandoms
end

function AO3WebParser:parseWorkPage(root)
    -- Extract metadata
    local titleElement = root:select(".title")[1]
    local authorElements = root:select("a[rel='author']")
    local giftElements = root:select(".associations > li > a[href$='/gifts']")
    local summaryElement = root:select(".summary > blockquote")[1]
    local tagsElement = root:select(".freeform > ul")[1]
    local relationshipsElement = root:select(".relationship > ul")[1]
    local charactersElement = root:select(".character > ul")[1]
    local warningsElement = root:select(".warning > ul")[1]
    local epubElement = root:select(".download > .expandable > li > a")
    local ratingElement = root:select(".rating > ul > li > a")[1]
    local categoryElement = root:select(".category > ul > li > a")[1]
    local iswipElement = root:select("dt.status")[1]

    -- Extract logged in metadata
    local markedForLaterElement = root:select(".mark > form > button")[1]
    local subscriptionFormElement = root:select(".subscribe > form")[1]
    local bookmarkFormElement = root:select("#bookmark-form > form")[1]

    -- Extract additional metadata
    local fandomElement = root:select(".fandom > ul")[1]
    local publishedElement = root:select("dd.published")[1]
    local updatedElement = root:select("dd.status")[1]
    local chaptersElement = root:select("dd.chapters")[1]
    local languageElement = root:select("dd.language")[1]

    -- Extract stats
    local hitsElement = root:select("dd.hits")[1]
    local kudosElement = root:select("dd.kudos")[1]
    local commentsElement = root:select("dd.comments")[1]
    local bookmarksElement = root:select("dd.bookmarks > a")[1]
    local wordCountElement = root:select("dd.words")[1]
    local chapterIDElements = root:select("#chapter_index > li > form > p > select > option")

    -- Extract metadata values
    local title = titleElement
        and encodeHelper:parseToCodepoints(titleElement:getcontent():gsub("<[^>]+>", ""):gsub("^%s*(.-)%s*$", "%1"))
        or "Unknown title"


    local author_table = {}
    for _, author in pairs(authorElements) do
        table.insert(author_table, encodeHelper:parseToCodepoints(author:getcontent()))
    end

    local author = authorElements and table.concat(author_table, ", ") or "Anonymous"

    local giftedTo_table = {}
    for _, gift in pairs(giftElements) do
        table.insert(giftedTo_table, encodeHelper:parseToCodepoints(gift:getcontent()))
    end

    local gifted_to = giftElements and table.concat(giftedTo_table, ", ") or nil

    local summary = summaryElement
        and encodeHelper:parseFromHTML(summaryElement:getcontent())
        or "No summary available"

    local chapterData = {}
    if chapterIDElements then
        for __, option in pairs(chapterIDElements) do
            if option.attributes.value then
                table.insert(
                    chapterData,
                    { id = option.attributes.value, #chapterData + 1, name = option:getcontent() }
                )
            end
        end
    end

    if #chapterData == 0 then
        local chapter_title_elements = root:select(".chapter.preface.group > h3.title")
        for _, chapter_title_element in pairs(chapter_title_elements) do
            local content = chapter_title_element:getcontent()
            local chapter_title = string.match(content, "</a>:%s*(.+)") or ("Chapter " .. (#chapterData + 1))
            local chapter_id = string.match(content, "/chapters/(%d+)")
            table.insert(chapterData, { id = chapter_id, #chapterData + 1, name = tostring(#chapterData + 1) .. ". " .. chapter_title })
        end
    end

    local tags = {}
    if tagsElement then
        for _, tag in ipairs(tagsElement:select("li > a")) do
            local content = encodeHelper:parseToCodepoints(tag:getcontent())
            if content then
                table.insert(tags, content)
            end
        end
    end

    local relationships = {}
    if relationshipsElement then
        for _, relationship in ipairs(relationshipsElement:select("li > a")) do
            local content = encodeHelper:parseToCodepoints(relationship:getcontent())
            if content then
                table.insert(relationships, content)
            end
        end
    end

    local characters = {}
    if charactersElement then
        for _, character in ipairs(charactersElement:select("li > a")) do
            local content = encodeHelper:parseToCodepoints(character:getcontent())
            if content then
                table.insert(characters, content)
            end
        end
    end

    local warnings = {}
    if warningsElement then
        for _, warning in ipairs(warningsElement:select("li > a")) do
            local content = encodeHelper:parseToCodepoints(warning:getcontent())
            if content then
                table.insert(warnings, content)
            end
        end
    end

    -- Extract additional metadata values
    local fandoms = {}
    if fandomElement then
        for _, fandom in ipairs(fandomElement:select("li > a")) do
            local content = encodeHelper:parseToCodepoints(fandom:getcontent())
            if content then
                table.insert(fandoms, content)
            end
        end
    end

    local publishedDate = publishedElement and encodeHelper:parseToCodepoints(publishedElement:getcontent()) or "Unknown date"
    local updatedDate = updatedElement and encodeHelper:parseToCodepoints(updatedElement:getcontent()) or "Unknown date"
    local chapters = chaptersElement and encodeHelper:parseToCodepoints(chaptersElement:getcontent():gsub("<[^>]+>", ""))
        or "Unknown chapters"
    local language = languageElement and encodeHelper:parseToCodepoints(languageElement:getcontent()) or "Unknown language"

    -- Extract logged in metadata values
    local markedForLater = markedForLaterElement ~= nil and encodeHelper:parseToCodepoints(markedForLaterElement:getcontent()) == "Mark as Read"
    local subscriptionID = subscriptionFormElement and subscriptionFormElement.attributes and subscriptionFormElement.attributes.id:match("edit_subscription_(%d+)") or false
    local bookmarkID = bookmarkFormElement and bookmarkFormElement.attributes and bookmarkFormElement.attributes.action:match("/bookmarks/(%d+)") or false

    local bookmarkContent = {}

    local bookmarkNotesElement = root:select("#bookmark_notes")[1]
    bookmarkContent.notes = bookmarkNotesElement and encodeHelper:parseFromHTML(bookmarkNotesElement:getcontent()) or ""

    local bookmarkTagElement = root:select("#bookmark_tag_string")[1]
    bookmarkContent.tags = bookmarkTagElement and bookmarkTagElement.attributes and bookmarkTagElement.attributes.value or ""

    local bookmarkCollectionElement = root:select("#bookmark_collection_names")[1]
    bookmarkContent.collections = bookmarkCollectionElement and bookmarkCollectionElement.attributes and bookmarkCollectionElement.attributes.value or ""

    local bookmarkPrivElement = root:select("#bookmark_private")[1]
    bookmarkContent.private = bookmarkPrivElement and bookmarkPrivElement.attributes and bookmarkPrivElement.attributes.checked=="checked" or false

    local bookmarkRecElement = root:select("#bookmark_rec")[1]
    bookmarkContent.rec = bookmarkRecElement and bookmarkRecElement.attributes and bookmarkRecElement.attributes.checked=="checked" or false

    -- Extract EPUB link
    local epub_link = nil
    for _, e in ipairs(epubElement) do
        if encodeHelper:parseToCodepoints(e:getcontent()):lower() == "epub" then
            epub_link = getAO3URL() .. e.attributes.href
            break
        end
    end

    -- Extract stats values
    local hits = hitsElement and encodeHelper:parseToCodepoints(hitsElement:getcontent():gsub("<[^>]+>", "")) or "0"
    local kudos = kudosElement and encodeHelper:parseToCodepoints(kudosElement:getcontent():gsub("<[^>]+>", "")) or "0"
    local comments = commentsElement and encodeHelper:parseToCodepoints(commentsElement:getcontent():gsub("<[^>]+>", "")) or "0"
    local bookmarks = bookmarksElement and encodeHelper:parseToCodepoints(bookmarksElement:getcontent():gsub("<[^>]+>", "")) or "0"
    local wordcount = wordCountElement and wordCountElement:getcontent():gsub(",", "") or "unknown"

    local iswip = iswipElement and iswipElement:getcontent():gsub(":", "") -- Remove colon
    if iswip == "Completed" then
        iswip = "Complete"
    elseif iswip == "Updated" then
        iswip = "Work in Progress"
    end

    -- Return metadata as a table
    local work = {
        title = title,
        author = author,
        gifted_to = gifted_to,
        chapterData = chapterData,
        summary = summary,
        tags = #tags > 0 and table.concat(tags, ", ") or "No tags available",
        relationships = relationships or {},
        characters = characters or {},
        warnings = warnings or {},
        fandoms = fandoms or {},
        published = publishedDate,
        updated = updatedDate,
        wordcount = wordcount,
        chapters = chapters,
        language = language,
        epub_link = epub_link or nil,
        hits = hits,
        kudos = kudos,
        comments = comments,
        bookmarks = bookmarks,
        rating = ratingElement and ratingElement:getcontent(),
        category = categoryElement and categoryElement:getcontent(),
        iswip = iswip,
        markedForLater = markedForLater,
        subscriptionID = subscriptionID,
        bookmarkID = bookmarkID,
        bookmarkContent = bookmarkContent
    }

    return work
end

function AO3WebParser:parseUserPage(root)
    -- Implementation for parsing user page goes here
    local user_fandoms = root:select("div #user-fandoms > ol > li")


    local fandom_list = {}

    for _, fandom in pairs(user_fandoms) do
        local name = encodeHelper:parseToCodepoints(fandom:select("a")[1]:getcontent())
        local count = fandom:getcontent():gsub("<a[^>]*>.-</a>", ""):match("%((%d+)%)")
        local fandom_id = fandom:select("a")[1].attributes.href:match("fandom_id=(%d+)")
        if name then
            table.insert(fandom_list, {name = name, count = count and tonumber(count) or 0, id = fandom_id})
        end
    end

    local username_element = root:select("div.primary > h2.heading")[1]
    local author_full = username_element and encodeHelper:parseToCodepoints(username_element:getcontent())
    author_full = author_full and author_full:gsub("%s+","") or "Unknown User"

    local username, pseud
    if string.find(author_full, "%(") and string.find(author_full, "%)") then
        username = string.match(author_full, "%((.-)%)")
        pseud = string.match(author_full, "^(.-)%s*%(")
    else
        username = author_full
        pseud = author_full
    end

    local total_pseuds_search = T("a[href$='%1/pseuds']", username)
    local total_pseuds_element = root:select(total_pseuds_search)[1]

    local total_pseuds = nil
    if total_pseuds_element then
        local total_pseuds_text = total_pseuds_element:getcontent()
        total_pseuds = total_pseuds_text:match("All Pseuds%s*%((%d+)%)")

        total_pseuds = tonumber(total_pseuds)
    end

    local total_works_search = T("[href$='%1/works']", pseud)
    local total_works_element = root:select(total_works_search)[1]

    local total_works = nil
    if total_works_element then
        local total_works_text = total_works_element:getcontent()
        total_works = total_works_text:match("Works%s*%((%d+)%)")

        total_works = tonumber(total_works)
    end

    local total_series_search = T("[href$='%1/series']", pseud)
    local total_series_element = root:select(total_series_search)[1]

    local total_series = nil

    if total_series_element then
        local total_series_text = total_series_element:getcontent()
        total_series = total_series_text:match("Series%s*%((%d+)%)")
        logger.dbg("AO3Downloader.koplugin: Found total series text: " .. tostring(total_series_text) .. ", extracted total series: " .. tostring(total_series))

        total_series = tonumber(total_series)
    end

    local total_bookmarks_search = T("[href$='%1/bookmarks']", pseud)
    local total_bookmarks_element = root:select(total_bookmarks_search)[1]
    local total_bookmarks = nil

    if total_bookmarks_element then
        local total_bookmarks_text = total_bookmarks_element:getcontent()
        total_bookmarks = total_bookmarks_text:match("Bookmarks%s*%((%d+)%)")

        -- Handle skipping the "My Bookmarks" element that appears in the header if the user is logged in
        if not total_bookmarks then
            total_bookmarks_element = root:select(total_bookmarks_search)[2]
            total_bookmarks_text = total_bookmarks_element:getcontent()
            total_bookmarks = total_bookmarks_text:match("Bookmarks%s*%((%d+)%)")
        end

        total_bookmarks = tonumber(total_bookmarks)
    end

    local total_collections_search = T("[href$='%1/collections']", username)
    local total_collections_element = root:select(total_collections_search)[1]
    local total_collections = nil

    if total_collections_element then
        local total_collections_text = total_collections_element:getcontent()
        total_collections = total_collections_text:match("Collections%s*%((%d+)%)")

        total_collections = tonumber(total_collections)
    end

    local total_gifts_search = T("[href$='%1/gifts']", username)
    local total_gifts_element = root:select(total_gifts_search)[1]
    local total_gifts = nil

    if total_gifts_element then
        local total_gifts_text = total_gifts_element:getcontent()
        total_gifts = total_gifts_text:match("Gifts%s*%((%d+)%)")

        total_gifts = tonumber(total_gifts)
    end

    return {
        username = username,
        pseud = pseud,
        fandoms = fandom_list,
        total_pseuds = total_pseuds or 1,
        total_works = total_works or 0,
        total_series = total_series or 0,
        total_bookmarks = total_bookmarks or 0,
        total_collections = total_collections or 0,
        total_gifts = total_gifts or 0,
    }
end

function AO3WebParser:parseUserPseuds(root)
    local pseuds = {}
    local elements = root:select("li.pseud")

    local count = 1

    for _, element in ipairs(elements) do
        local pseudElement = element:select("h4.heading > a")[1]
        if pseudElement then
            local pseud_name = encodeHelper:parseToCodepoints(pseudElement:getcontent())

            local worksElement = element:select("h5.heading > a[href$='/works']")[1]
            local recsElement = element:select("h5.heading > a[href$='recs_only=true']")[1]

            local work_count = nil
            local rec_count = nil

            if worksElement then
                local works_text = worksElement:getcontent()
                work_count = tonumber(works_text:match("([%d,]+) work"):gsub(",", ""), 10)
            end

            if recsElement then
                local recs_text = recsElement:getcontent()
                rec_count = tonumber(recs_text:match("([%d,]+) rec"):gsub(",", ""), 10)
            end

            local pseud = {
                name = pseud_name,
                works_count = work_count or 0,
                recs_count = rec_count or 0,
            }

            table.insert(pseuds, count, pseud)
            count = count + 1
        end
    end

    return pseuds
end

function AO3WebParser:parseAccountPseudID(root)

    local element = root:select(".edit_pseud")[1]

    local pseud_id = element and element.attributes and element.attributes.id:match("edit_pseud_(%d+)") or false

    return pseud_id
end

function AO3WebParser:parseUserSearchResults(root)
    local users = {}
    local elements = root:select("li.user")

    local count = 1

    for _, element in ipairs(elements) do
        local usernameElements = element:select("h4.heading > a")
        if usernameElements then
            local username = nil
            local pseud = nil
            local work_count = nil
            local bookmark_count = nil

            if usernameElements[2] == nil then
                username = encodeHelper:parseToCodepoints(usernameElements[1]:getcontent())
                pseud = username
            else
                username = encodeHelper:parseToCodepoints(usernameElements[2]:getcontent())
                pseud = usernameElements[1]:getcontent()
            end

            local worksElement = element:select("h5.heading > a[href$='/works']")[1]
            local bookmarksElement = element:select("h5.heading > a[href$='/bookmarks']")[1]

            if worksElement then
                local works_text = worksElement:getcontent()
                work_count = tonumber(works_text:match("([%d,]+) works"):gsub(",", ""), 10)
            end

            if bookmarksElement then
                local bookmarks_text = bookmarksElement:getcontent()
                bookmark_count = tonumber(bookmarks_text:match("([%d,]+) bookmarks"):gsub(",", ""), 10)
            end





            local user = {
                username = username,
                pseud = pseud,
                works_count = work_count or 0,
                bookmarks_count = bookmark_count or 0,
            }

            table.insert(users, count, user)
            count = count + 1
        end
    end

    return users
end

function AO3WebParser:parseUsersWorkBookmark(root)
    local bookmark_details = {
        notes = "",
        tags = "",
        collections = "",
        private = false,
        rec = false,
    }

    local bookmarkForm = root:select("#bookmark-form > form")[1]


    if not bookmarkForm then
        return bookmark_details
    end

    bookmark_details.notes = bookmarkForm:select("textarea#bookmark_notes")[1] and encodeHelper:parseFromHTML(root:select("textarea#bookmark_notes")[1]:getcontent()) or ""

    -- Tags are stored in a text input field as comma-separated values
    local tags_input = bookmarkForm:select("input#bookmark_tag_string")[1]
    if tags_input and tags_input.attributes and tags_input.attributes.value then
        local tags_string = tags_input.attributes.value
        -- Split by comma and trim whitespace
        for tag in tags_string:gmatch("([^,]+)") do
            tag = tag:match("^%s*(.-)%s*$") -- trim whitespace
            if tag and tag ~= "" then
                bookmark_details.tags = bookmark_details.tags .. (bookmark_details.tags ~= "" and ", " or "") .. tag
            end
        end
    end

    -- Collections are stored in a text input field, not as li.added.tag elements
    local collections_input = bookmarkForm:select("input#bookmark_collection_names")[1]
    if collections_input and collections_input.attributes and collections_input.attributes.value then
        local collections_string = collections_input.attributes.value
        -- Split by comma and trim whitespace
        for collection in collections_string:gmatch("([^,]+)") do
            collection = collection:match("^%s*(.-)%s*$") -- trim whitespace
            if collection and collection ~= "" then
                bookmark_details.collections = bookmark_details.collections .. (bookmark_details.collections ~= "" and ", " or "") .. collection
            end
        end
    end

    bookmark_details.private = bookmarkForm:select("input#bookmark_private")[1] and bookmarkForm:select("input#bookmark_private")[1].attributes.checked == "checked" or false

    bookmark_details.rec = bookmarkForm:select("input#bookmark_rec")[1] and bookmarkForm:select("input#bookmark_rec")[1].attributes.checked == "checked" or false

    return bookmark_details
end

return AO3WebParser
