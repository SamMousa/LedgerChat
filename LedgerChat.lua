if (GetTime == nil) then
    package.path = "./libs/LibEventSourcing/?.lua;" .. package.path
    require "LibEventSourcing"
    require "libs/LibScrollingTable/Core"
    require "libs/LibSerialize/LibSerialize"
    require "libs/LibDeflate/LibDeflate"
    require "src/TextMessageEntry"
end

local LedgerChat, _ = LibStub:NewLibrary("LedgerChat", 1)
if not LedgerChat then
    return end

local state = {
    balances = {},
    weeks = {},
    messages = {}
}

local Profile = {}
function Profile:start(name)
    Profile[name] =  GetTime()
end

function Profile:stop(name)
    local elapsed =  GetTime() - Profile[name]
    print(string.format(name .. ": elapsed time: %.2f\n", elapsed))
end

local TextMessageEntry = LibStub("LedgerChat/TextMessageEntry")
local Util = LibStub("EventSourcing/Util")

local ScrollingTable = LibStub("ScrollingTable");

-- Allows defining fallbacks so we can test outside WoW
local function LibStubWithStub(library, fallback)
    local result, lib = pcall(LibStub, library)
    if result then
        return lib
    elseif type(fallback) == 'function' then
        return fallback()
    else
        return fallback
    end
end
local ledger

local function createTestData()
    ledger.reset()
    Profile:start('Creating data')

    for i = 1, 1 * 400 do

        local entry = TextMessageEntry.create(string.format("Message %d", i))
        -- today minus 4 weeks
        entry.t = Util.time() - math.random(604800 * 4)
        local copy = {}
        for k, v in pairs(entry) do
            copy[k] = v
        end
        ledger.submitEntry(copy)
        if i % 1000 == 0 then
            print('.')
        end
    end
    print('done')

    Profile:stop('Creating data')
end

local function launch()
    local AceComm = LibStubWithStub("AceComm-3.0", {
        RegisterComm = function()  end,
        SendCommMessage = function()  end
    })
    local LibSerialize = LibStubWithStub("LibSerialize", {})
    local LibDeflate = LibStubWithStub("LibDeflate", {})



    if LedgerChatData == nil then
        LedgerChatData = {}
    end
    print('reconstructing list from saved variables', #LedgerChatData)

    --local records = Database.RetrieveByKeys(data, searchResult)
    --
    --printtable(records);

    local function registerReceiveHandler(callback)
        print("Registering handler")
        AceComm:RegisterComm('LedgerChat', function(prefix, text, distribution, sender)
            local result, data = LibSerialize:Deserialize(
                LibDeflate:DecompressDeflate(LibDeflate:DecodeForWoWAddonChannel(text)))
            if result then
                callback(data, distribution, sender)
            else
                print("Failed to deserialize data", data)
            end
        end)
    end

    local function send(data, distribution, target, prio, callbackFn, callbackArg)
        local serialized = LibSerialize:Serialize(data)
--        print("Sending")
--        Util.DumpTable(data)
        local compressed = LibDeflate:EncodeForWoWAddonChannel(LibDeflate:CompressDeflate(serialized))

        AceComm:SendCommMessage('LedgerChat', compressed, distribution, target, prio, callbackFn, callbackArg)
    end

    ledger = LibStub("EventSourcing/LedgerFactory").createLedger(LedgerChatData, send, registerReceiveHandler, function() return true end)

    local listSync = ledger.getListSync()
    local sortedList = ledger.getSortedList()

    ledger.registerMutator(TextMessageEntry.class(), function(entry)
        local _, _, _, _, _, name, _ = GetPlayerInfoByGUID(Util.getGuidFromInteger(entry:creator()))
        table.insert(state.messages, {
            date("%m/%d/%y %H:%M:%S", entry:time()),
            name,
            entry:message(),
        })
    end)

    if (#LedgerChatData == 0) then
        --createTestData()
    end


    ledger.addStateRestartListener(function()
        Util.wipe(state.messages)
    end)


    local previousLag = 0
    local updateCounter = 0
    local scrollingTable
    if os == nil then
        scrollingTable = ScrollingTable:CreateST({
            {
                name="Timestamp",
                width=150
            },
            {
                name="Sender",
                width=100
            },
            {
                name="Message",
                width=300
            }
        })
        local display = scrollingTable.frame
        display:SetPoint("CENTER", UIParent)
        display:SetHeight(200)
        display:Show()
        display:RegisterForDrag("Leftbutton")
        display:EnableMouse(true)
        display:SetMovable(true)
        display:SetScript("OnDragStart", function(self) self:StartMoving() end)
        display:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
        scrollingTable:SetData(state.messages, true)
        SLASH_LEDGERCHAT1 = "/ledgerchat"
        SlashCmdList["LEDGERCHAT"] =function(message)
            local entry = TextMessageEntry.create(message)
            listSync:transmitViaGuild(entry)
            return sortedList:uniqueInsert(entry)
        end

    end
    ledger.addStateChangedListener(function(lag, uncommitted)
        updateCounter = updateCounter + 1

        if scrollingTable ~= nil then
            scrollingTable:SortData()
        else
            print(string.format("State changed, lag is now %d, there are %d entries not committed to the log", lag, uncommitted))
            if previousLag > 0 and lag == 0 then
                Util.DumpTable(state.messages)
                for k, _ in pairs(state.weeks) do
                    print(string.format("Week %d hash: %d", k, ledger.getListSync():weekHash(k)))
                end
            end
            previousLag = lag
        end
    end)

    ledger.enableSending()





end

if WOW_STUB then
    launch()

else
    local frame = CreateFrame("Frame")
    frame:RegisterEvent("ADDON_LOADED")
    frame:SetScript("OnEvent", function(data, event, addon)
        if addon == 'LedgerChat'then
            LedgerChatData = LedgerChatData or {}
            launch()
        end
    end)
end





-- event loop for C_Timer outside wow
if C_Timer.startEventLoop ~= nil then
C_Timer.startEventLoop()
end
