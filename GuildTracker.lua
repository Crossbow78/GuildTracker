GuildTracker = LibStub("AceAddon-3.0"):NewAddon("GuildTracker", "AceBucket-3.0", "AceEvent-3.0", "AceConsole-3.0", "AceTimer-3.0")


local ICON_DELETE = "|TInterface\\Buttons\\UI-GroupLoot-Pass-Up:16:16:0:0:16:16:0:16:0:16|t"
local ICON_CHAT = "|TInterface\\ChatFrame\\UI-ChatWhisperIcon:16:16:0:0:16:16:0:16:0:16|t"
local ICON_TIMESTAMP = "|TInterface\\HelpFrame\\HelpIcon-ReportLag:16:16:0:0:16:16:0:16:0:16|t"
local ICON_TOGGLE = "|TInterface\\Buttons\\UI-%sButton-Up:18:18:1:0|t"

local CLR_YELLOW = "|cffffd200"
local CLR_GRAY = "|cffaaaaaa"

local ROSTER_REFRESH_THROTTLE = 10
local ROSTER_REFRESH_TIMER = 30

local LDB = LibStub("LibDataBroker-1.1")
local LibQTip = LibStub:GetLibrary("LibQTip-1.0")
local LDBIcon = LibStub("LibDBIcon-1.0")

--- Some local helper functions
local tinsert = table.insert
local tremove = table.remove
local tsort = table.sort
local function tcopy(t)
  local u = { }
  if type(t) == 'table' then
  	for k, v in pairs(t) do
  		u[k] = v
  	end
  end
  return setmetatable(u, getmetatable(t))
end
local function tfind(list, val)
   for k,v in pairs(list) do
      if v == val then
         return k
      end
   end
   return nil
end
local function tchelper(first, rest)
  return first:upper()..rest:lower()
end
local function toproper(str)
	return str:gsub("(%a)([%w']*)", tchelper):gsub("_"," ")
end
local function RGB2HEX(red, green, blue)
	return ("|cff%02x%02x%02x"):format(red * 255, green * 255, blue * 255)
end
local RAID_CLASS_COLORS_hex = {}
for k, v in pairs(RAID_CLASS_COLORS) do
	RAID_CLASS_COLORS_hex[k] = ("|cff%02x%02x%02x"):format(v.r * 255, v.g * 255, v.b * 255)
end
local function pluralize(amount, singular, plural)
	if amount == 1 then
		return singular or ""
	else
		return plural or "s"
	end
end


--- DataBroker events -----
local function do_OnEnter(frame)
	local tooltip = LibQTip:Acquire("GuildTrackerTip")
	tooltip:SmartAnchorTo(frame)
	tooltip:SetAutoHideDelay(0.2, frame)
	tooltip:EnableMouse(true)

	GuildTracker:UpdateTooltip()
	tooltip:Show()
end

local function do_OnLeave()
end

local function do_OnClick(frame, button)
	--print(button)
	if button == "RightButton" then
		InterfaceOptionsFrame_OpenToCategory(GuildTracker.optionsFrame)		
	else
		GuildTracker:Refresh()
	end
end

--- Player table cache
local tablecache = {}
local function recycleplayertable(t)
	while #t > 0 do
		tinsert(tablecache, tremove(t))
	end
	return t
end
local function getplayertable(...)
	local t
	if #tablecache > 0 then
		t = tremove(tablecache)
	else
		t = {}
	end
	for i = 1, select('#', ...) do
		t[i] = select(i, ...)
	end
	return t
end

-- The available chat types
local ChatType = { "SAY", "YELL", "GUILD", "OFFICER", "PARTY", "RAID" }
local ChatFormat = { [1] = "Short", [2] = "Long", [3] = "Full" }
local TimeFormat = { [1] = "Absolute", [2] = "Relative", [3] = "Intuitive", [4] = "Small" }

-- The guild information fields we store
local Field = {
	Name = 1,
	Rank = 2,
	Class = 3,
	Level = 4,
	Note = 5,
	OfficerNote = 6,
	LastOnline = 7,
	SoR = 8,
}

-- The types of tracked changes
local State = {
	Unchanged = 0,
	GuildLeave = 1,
	GuildJoin = 2,
	RankDown = 3,
	RankUp = 4,
	AccountDisabled = 5,
	AccountEnabled = 6,
	Inactive = 7,
	Active = 8,
	LevelChange = 9,
	NoteChange = 10,
	NameChange = 11,
}

local StateInfo = {
	[State.Unchanged] = {
		color = RGB2HEX(1,1,1),
		category = "None",
		shorttext = "Unchanged",
		longtext = "is unchanged",
		template = "is unchanged",
	},
	[State.GuildJoin] = {
		color = RGB2HEX(0.6,1,0.6),
		category = "Member",
		shorttext = "Member joined",
		longtext = "has joined the guild",
		template = "has joined the guild (note: '%s')",
	},
	[State.GuildLeave] = {
		color = RGB2HEX(0.95,0.5,0.5),
		category = "Member",
		shorttext = "Member left",
		longtext = "has left the guild",
		template = "has left the guild (note: '%s')",
	},
	[State.RankUp] = {
		color = RGB2HEX(0.55,1,1),
		category = "Rank",
		shorttext = "Rank up",
		longtext = "has gone up in rank",
		template = "got promoted from '%s' to '%s'",
	},
	[State.RankDown] = {
		color = RGB2HEX(0.15,0.65,0.65),
		category = "Rank",
		shorttext = "Rank down",
		longtext = "has gone down in rank",
		template = "got demoted from '%s' to '%s'",
	},
	[State.AccountEnabled] = {
		color = RGB2HEX(1,0.65,1),
		category = "Account",
		shorttext = "Activated account",
		longtext = "activated their account (or received a SoR)",
		template = "activated their account (or received a SoR)",
	},
	[State.AccountDisabled] = {
		color = RGB2HEX(0.7,0.3,0.7),
		category = "Account",
		shorttext = "Deactivated account",
		longtext = "deactivated their account (or let their SoR expire)",
		template = "deactivated their account (or let their SoR expire)",
	},
	[State.Active] = {
		color = RGB2HEX(0.6,0.6,1),
		category = "Activity",
		shorttext = "Active",
		longtext = "has returned from inactivity",
		template = "has logged on after %s of inactivity",
	},
	[State.Inactive] = {
		color = RGB2HEX(0.35,0.35,0.8),
		category = "Activity",		
		shorttext = "Inactive",
		longtext = "has been marked inactive",
		template = "has not logged on for more than %d days",
	},
	[State.LevelChange] = {
		color = RGB2HEX(1,0.95,0.4),
		category = "Level",
		shorttext = "Level up",
		longtext = "has gained one or more levels",
		template = "has gone up %d level%s and is now %d",
	},
	[State.NoteChange] = {
		color = RGB2HEX(0.75,0.55,0.55),
		category = "Note",
		shorttext = "Note change",
		longtext = "got a new guild note",
		template = "note changed from \"%s\" to \"%s\"",
	},
	[State.NameChange] = {
		color = RGB2HEX(0.3,0.75,0.3),
		category = "Name",
		shorttext = "Name change",
		longtext = "had a name change",
		template = "changed name to \"%s\"",
	},	
}

local sorts = {
	["Name"] = function(a, b)
				local aInfo = (a.type ~= State.GuildLeave) and a.newinfo or a.oldinfo
				local bInfo = (b.type ~= State.GuildLeave) and b.newinfo or b.oldinfo
				if GuildTracker.db.profile.options.tooltip.sort_ascending then
					return aInfo[Field.Name] < bInfo[Field.Name]
				end
				return aInfo[Field.Name] > bInfo[Field.Name]
		 end,
	["Level"] = function(a, b)
				local aInfo = (a.type ~= State.GuildLeave) and a.newinfo or a.oldinfo
				local bInfo = (b.type ~= State.GuildLeave) and b.newinfo or b.oldinfo
				if aInfo[Field.Level] ~= bInfo[Field.Level] then
					if GuildTracker.db.profile.options.tooltip.sort_ascending then
						return aInfo[Field.Level] < bInfo[Field.Level]
					end
					return aInfo[Field.Level] > bInfo[Field.Level]
				else
					if a.timestamp ~= b.timestamp then
						if GuildTracker.db.profile.options.tooltip.sort_ascending then
							return a.timestamp < b.timestamp
						end
						return a.timestamp > b.timestamp
					else
						if GuildTracker.db.profile.options.tooltip.sort_ascending then
							return aInfo[Field.Name] < bInfo[Field.Name]
						end
						return aInfo[Field.Name] > bInfo[Field.Name]				
					end
				end
		 end,
	["Rank"] = function(a, b)
				local aInfo = (a.type ~= State.GuildLeave) and a.newinfo or a.oldinfo
				local bInfo = (b.type ~= State.GuildLeave) and b.newinfo or b.oldinfo
				if aInfo[Field.Rank] ~= bInfo[Field.Rank] then
					if GuildTracker.db.profile.options.tooltip.sort_ascending then
						return aInfo[Field.Rank] < bInfo[Field.Rank]
					end
					return aInfo[Field.Rank] > bInfo[Field.Rank]
				else
					if a.timestamp ~= b.timestamp then
						if GuildTracker.db.profile.options.tooltip.sort_ascending then
							return a.timestamp < b.timestamp
						end
						return a.timestamp > b.timestamp
					else
						if GuildTracker.db.profile.options.tooltip.sort_ascending then
							return aInfo[Field.Name] < bInfo[Field.Name]
						end
						return aInfo[Field.Name] > bInfo[Field.Name]				
					end
				end
		 end,		 		 
	["Type"] = function(a, b)
				if a.type ~= b.type then
					if GuildTracker.db.profile.options.tooltip.sort_ascending then
						return a.type < b.type
					end
					return a.type > b.type
				else
					if a.timestamp ~= b.timestamp then
						if GuildTracker.db.profile.options.tooltip.sort_ascending then
							return a.timestamp < b.timestamp
						end
						return a.timestamp > b.timestamp
					else
						local aInfo = (a.type ~= State.GuildLeave) and a.newinfo or a.oldinfo
						local bInfo = (b.type ~= State.GuildLeave) and b.newinfo or b.oldinfo
						if GuildTracker.db.profile.options.tooltip.sort_ascending then
							return aInfo[Field.Name] < bInfo[Field.Name]
						end
						return aInfo[Field.Name] > bInfo[Field.Name]				
					end

				end
		 end,	
	["Offline"] = function(a, b)
				local aInfo = (a.type ~= State.GuildLeave) and a.newinfo or a.oldinfo
				local bInfo = (b.type ~= State.GuildLeave) and b.newinfo or b.oldinfo
				if aInfo[Field.LastOnline] ~= bInfo[Field.LastOnline] then
					if GuildTracker.db.profile.options.tooltip.sort_ascending then
						return aInfo[Field.LastOnline] < bInfo[Field.LastOnline]
					end
					return aInfo[Field.LastOnline] > bInfo[Field.LastOnline]
				else
					if a.timestamp ~= b.timestamp then
						if GuildTracker.db.profile.options.tooltip.sort_ascending then
							return a.timestamp < b.timestamp
						end
						return a.timestamp > b.timestamp
					else
						if GuildTracker.db.profile.options.tooltip.sort_ascending then
							return aInfo[Field.Name] < bInfo[Field.Name]
						end
						return aInfo[Field.Name] > bInfo[Field.Name]				
					end
				end
		 end,		 	 
	["Timestamp"] = function(a, b)
				if a.timestamp ~= b.timestamp then
					if GuildTracker.db.profile.options.tooltip.sort_ascending then
						return a.timestamp < b.timestamp
					end
					return a.timestamp > b.timestamp
				else
					local aInfo = (a.type ~= State.GuildLeave) and a.newinfo or a.oldinfo
					local bInfo = (b.type ~= State.GuildLeave) and b.newinfo or b.oldinfo
					if GuildTracker.db.profile.options.tooltip.sort_ascending then
						return aInfo[Field.Name] < bInfo[Field.Name]
					end
					return aInfo[Field.Name] > bInfo[Field.Name]				
				end
		 end,
}

StaticPopupDialogs["GUILDTRACKER_REMOVEALL"] = {
	preferredIndex = 3,  -- avoid some UI taint, see http://www.wowace.com/announcements/how-to-avoid-some-ui-taint/
  text = "Are you sure you want to remove all changes?",
  button1 = "Yes",
  button2 = "No",
  OnAccept = function()
      GuildTracker:RemoveAllChanges()
  end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
}


--------------------------------------------------------------------------------
function GuildTracker:OnInitialize()
--------------------------------------------------------------------------------	
	self.db = LibStub("AceDB-3.0"):New("GuildTrackerDB", self:GetDefaults(), true)
	
	self.options = self:GetOptions()
	self.options.args.Profiles = LibStub("AceDBOptions-3.0"):GetOptionsTable(self.db)
	self.options.args.Profiles.disabled = function() return not self.db.profile.enabled end
	
	self:GenerateStateOptions()
	
	self.dbo = LDB:NewDataObject("GuildTracker", {
			type = "data source",
			text = "...",
			icon = [[Interface\Addons\GuildTracker\GuildTracker]],
			OnEnter = do_OnEnter,
			OnLeave = do_OnLeave,
			OnClick = do_OnClick,
		})	
		
	LDBIcon:Register("GuildTrackerIcon", self.dbo, self.db.profile.options.minimap)		
	
	LibStub("AceConfig-3.0"):RegisterOptionsTable("GuildTracker", self.options)
	
	self.optionsFrame = LibStub("AceConfigDialog-3.0"):AddToBlizOptions("GuildTracker", "Guild Tracker")
	self.GuildRoster = {}
	self.ChangesPerState = {}
	self.LastRosterUpdate = 0
	
	self:Print("Initialized")
end

--------------------------------------------------------------------------------
function GuildTracker:OnEnable()
--------------------------------------------------------------------------------
	self:RegisterEvent("PLAYER_LOGOUT")
	self:RegisterEvent("PLAYER_GUILD_UPDATE")
	self:PLAYER_GUILD_UPDATE()
	self:Debug("Enabled")
end


--------------------------------------------------------------------------------
function GuildTracker:OnDisable()
--------------------------------------------------------------------------------	
	self:Debug("Disabled")
	self:UnregisterEvent("PLAYER_LOGOUT")
	self:UnregisterEvent("PLAYER_GUILD_UPDATE")
end

--------------------------------------------------------------------------------	
function GuildTracker:Toggle()
--------------------------------------------------------------------------------	
	if not self:IsEnabled() then
		self:Enable()
	else
		self:Disable()
	end
end


--------------------------------------------------------------------------------	
function GuildTracker:Refresh()
--------------------------------------------------------------------------------	
	if time() - self.LastRosterUpdate > ROSTER_REFRESH_THROTTLE then
		self:Debug("Refresh requested")
		GuildRoster()
	else
		self:Debug("Refresh requested, but throttled")
	end
end


--------------------------------------------------------------------------------
function GuildTracker:StartUpdateTimer()
--------------------------------------------------------------------------------
	if self.timerGuildUpdate == nil then
		self:Debug("Starting update timer")
		self.timerGuildUpdate = self:ScheduleRepeatingTimer("Refresh", ROSTER_REFRESH_TIMER)		
	end
end


--------------------------------------------------------------------------------
function GuildTracker:StopUpdateTimer()
--------------------------------------------------------------------------------
	if self.timerGuildUpdate then
		self:Debug("Cancelling update timer")
		self:CancelTimer(self.timerGuildUpdate)
		self.timerGuildUpdate = nil
	end
end


--------------------------------------------------------------------------------
function GuildTracker:PLAYER_LOGOUT()
--------------------------------------------------------------------------------
	if self.db.profile.options.autoreset then
		self:RemoveAllChanges()
	end
end

--------------------------------------------------------------------------------
function GuildTracker:PLAYER_GUILD_UPDATE(event, unit)
--------------------------------------------------------------------------------
	self:Debug("PLAYER_GUILD_UPDATE " .. (unit or "(nil)"))
	if unit and unit ~= "player" then return end
	
	if IsInGuild() then
		if not self.bucket_GUILD_ROSTER_UPDATE then
			self.bucket_GUILD_ROSTER_UPDATE = self:RegisterBucketEvent("GUILD_ROSTER_UPDATE", 1)
		end
		
		if self.db.profile.options.autorefresh then
			self:StartUpdateTimer()
		else
			self:StopUpdateTimer()
		end
	
		-- We can't load the database here yet, because the guildname is unknown at this point during login
		-- so wait for the guild roster update event
		self:Refresh()
	else
		-- This will unload the database
		self:Debug("Not in guild, unloading database")
		self.GuildDB = nil
		self.GuildName = nil
		self:UpdateLDB()
		self:StopUpdateTimer()

		if self.bucket_GUILD_ROSTER_UPDATE then
			self:UnregisterBucket(self.bucket_GUILD_ROSTER_UPDATE)
		end
	end
end

--------------------------------------------------------------------------------
function GuildTracker:GUILD_ROSTER_UPDATE()
--------------------------------------------------------------------------------
	self:Debug("GUILD_ROSTER_UPDATE")
	self.LastRosterUpdate = time()
	
	self.GuildName = GetGuildInfo("player")
	if self.GuildName == nil then
		self:Debug("WARNING: no guildname available!")
		return
	end
	
	-- Switch to our current guild database, and initialize if needed
	self:InitGuildDatabase()
	
	-- Load current guild roster into self.GuildRoster
	self:UpdateGuildRoster()
	
	-- Find changes between the saved roster and the current guild roster
	self:UpdateGuildChanges()
	
	-- Save the current guild roster
	self:SaveGuildRoster()
	
	-- Alerts for any new changes
	self:ReportNewChanges()
	
	-- Update text and tooltips
	self:UpdateLDB()
end


-- PRE: IsInGuild() == true and self.GuildName ~= nil
--------------------------------------------------------------------------------
function GuildTracker:InitGuildDatabase()
--------------------------------------------------------------------------------	
	local guildname = self.GuildName

	-- If necessary, initialize guild database for first use
	if self.db.realm.guild[guildname] == nil then
		self:Print(string.format("Creating new database for guild '%s'", guildname))
		self.db.realm.guild[guildname] = {
			updated = time(),
			roster = {},
			changes = {}
		}
	else
		self:Debug(string.format("Using existing database for guild '%s'", guildname))
	end
	
	self.GuildDB = self.db.realm.guild[guildname]
end

--------------------------------------------------------------------------------
function GuildTracker:UpdateGuildRoster()
--------------------------------------------------------------------------------
	local numGuildMembers = GetNumGuildMembers()
	local name, rank, rankIndex, level, class, zone, note, officernote, online, status, classconst, achievementPoints, achievementRank, isMobile, canSoR
	local hours, days, months, years, lastOnline
	
	local players = recycleplayertable(self.GuildRoster)
	
	self:Debug(string.format("Scanning %d guild members", numGuildMembers))
	
	for i = 1, numGuildMembers, 1 do
		name, rank, rankIndex, level, class, zone, note, officernote, online, status, classconst, achievementPoints, achievementRank, isMobile, canSoR = GetGuildRosterInfo(i)
		years, months, days, hours = GetGuildRosterLastOnline(i)
		
		lastOnline = online and 0 or (years * 365 + months * 30.417 + days + hours/24)
		
		tinsert(players, getplayertable(name, rankIndex, classconst, level, note, officernote, lastOnline, canSoR))
	end
	
	self.GuildRoster = players
end

--------------------------------------------------------------------------------
function GuildTracker:UpdateGuildChanges()
--------------------------------------------------------------------------------
	if self.GuildDB == nil then
		return
	end
	
	local oldRoster = self.GuildDB.roster
	
	-- If there's no saved roster data available, we can't determine any changes yet
	-- This happens when the first time we scan a guild 
	if oldRoster == nil or #oldRoster == 0 then
		return
	end
	
	self:Debug("Detecting guild changes")
	
	-- First update the existing entries of our SavedRoster
	for i = 1, #oldRoster do
		local info = oldRoster[i]
		local newPlayerInfo = self:FindPlayerByName(self.GuildRoster, info[Field.Name])
		
		if newPlayerInfo == nil then
			self:AddGuildChange(State.GuildLeave, info, nil)
		else
			if newPlayerInfo[Field.Rank] < info[Field.Rank] then
				self:AddGuildChange(State.RankUp, info, newPlayerInfo)
			elseif newPlayerInfo[Field.Rank] > info[Field.Rank] then
				self:AddGuildChange(State.RankDown, info, newPlayerInfo)
			elseif newPlayerInfo[Field.SoR] and not info[Field.SoR] then
				self:AddGuildChange(State.AccountDisabled, info, newPlayerInfo)
			elseif not newPlayerInfo[Field.SoR] and info[Field.SoR] then
				self:AddGuildChange(State.AccountEnabled, info, newPlayerInfo)
			elseif newPlayerInfo[Field.LastOnline] >= self.db.profile.options.inactive and info[Field.LastOnline] < self.db.profile.options.inactive then				
				self:AddGuildChange(State.Inactive, info, newPlayerInfo)
			elseif newPlayerInfo[Field.LastOnline] < self.db.profile.options.inactive and info[Field.LastOnline] >= self.db.profile.options.inactive then				
				self:AddGuildChange(State.Active, info, newPlayerInfo)
			elseif newPlayerInfo[Field.Level] ~= info[Field.Level] then
				self:AddGuildChange(State.LevelChange, info, newPlayerInfo)
			elseif newPlayerInfo[Field.Note] ~= info[Field.Note] then
				self:AddGuildChange(State.NoteChange, info, newPlayerInfo)
			end
			
		end
	end
	
	-- Then add any new entries
	for i = 1, #self.GuildRoster do
		local info = self.GuildRoster[i]
		local oldPlayerInfo = self:FindPlayerByName(oldRoster, info[Field.Name])
		if oldPlayerInfo == nil then
			self:AddGuildChange(State.GuildJoin, nil, info)
		end
	end

	self:SortAndGroupChanges()
	self:DetectNameChanges()
end


--------------------------------------------------------------------------------	
function GuildTracker:SortAndGroupChanges()
--------------------------------------------------------------------------------	
	-- Remove 'unchanged' entries
	local lastUsedIdx = 1
	for i = 1, #self.GuildDB.changes do
		self.GuildDB.changes[lastUsedIdx] = self.GuildDB.changes[i]
		if self.GuildDB.changes[i].type ~= State.Unchanged then
			lastUsedIdx = lastUsedIdx + 1
		end
	end
	for i = lastUsedIdx, #self.GuildDB.changes do
		self.GuildDB.changes[i] = nil
	end

	-- Apply sorting	
	local sort_func = sorts[self.db.profile.options.tooltip.sorting]
	if sort_func ~= nil then
		tsort(self.GuildDB.changes, sort_func)
	end
	
	-- Apply grouping per state
	local groupChanges = {}
	for key, val in pairs(State) do
		groupChanges[val] = {}
	end
	for idx,change in ipairs(self.GuildDB.changes) do
		tinsert(groupChanges[change.type], idx)
	end
	
	self.ChangesPerState = groupChanges
end
	
--------------------------------------------------------------------------------
function GuildTracker:DetectNameChanges()
--------------------------------------------------------------------------------
	local foundNameChanges = false
	local joins = self.ChangesPerState[State.GuildJoin]
	local quits = self.ChangesPerState[State.GuildLeave]
	
	if joins and quits and #joins > 0 and #quits > 0 then
		for _, joinIdx in ipairs(joins) do
			local changeJoin = self.GuildDB.changes[joinIdx]
			
			for _, quitIdx in ipairs(quits) do
				local changeQuit = self.GuildDB.changes[quitIdx]
				
				if self:IsNameChange(changeJoin, changeQuit) then
					self:Debug(format("Merging '%s quit' and '%s joined' into name change", changeQuit.oldinfo[Field.Name], changeJoin.newinfo[Field.Name]))
					changeJoin.type = State.NameChange
					changeJoin.oldinfo = changeQuit.oldinfo
					changeQuit.type = State.Unchanged
					foundNameChanges = true
					break
				end
				
			end
		end
	end
	
	if foundNameChanges then
		-- This will clean up our table, and re-group the name change entries
		self:SortAndGroupChanges()
	end
end	

--------------------------------------------------------------------------------
function GuildTracker:IsNameChange(changeJoin, changeQuit)
--------------------------------------------------------------------------------
	local infoJoin = changeJoin.newinfo
	local infoQuit = changeQuit.oldinfo
	
	return changeJoin.timestamp == changeQuit.timestamp
			and infoJoin[Field.Class] == infoQuit[Field.Class]
			and infoJoin[Field.Rank] == infoQuit[Field.Rank]
			and infoJoin[Field.Level] == infoQuit[Field.Level]
			and infoJoin[Field.Note] == infoQuit[Field.Note]
end
	
--------------------------------------------------------------------------------	
function GuildTracker:AddGuildChange(state, oldInfo, newInfo)
--------------------------------------------------------------------------------
	if not self.db.profile.options.filter[state] then
		self:Debug("Ignoring guild change of type " .. state)
		return
	end
	
	self:Debug("Adding guild change of type " .. state)
	
	local newchange = {}
	
	newchange.timestamp = self.LastRosterUpdate
	newchange.oldinfo = tcopy(oldInfo)
	newchange.newinfo = tcopy(newInfo)
	newchange.type = state
	
	tinsert(self.GuildDB.changes, newchange)
end
	
--------------------------------------------------------------------------------
function GuildTracker:GetAlertMessage(change, msgFormat, makelink)
--------------------------------------------------------------------------------
	local state = change.type
	local info = (state == State.GuildLeave or state == State.NameChange) and change.oldinfo or change.newinfo
	local name = info[Field.Name]
	local coloredName = "[" .. RAID_CLASS_COLORS_hex[info[Field.Class]] .. name .. "|r" .. "]"
	local nameText = makelink and format("|Hplayer:%s|h%s|h", name, coloredName) or coloredName

	if msgFormat == 1 then -- Short
	
		local stateColor, stateText, _, _ = self:GetStateText(state)
		return string.format("%s%s|r: %s", stateColor, stateText, nameText)
		
	elseif msgFormat == 2 then -- Long
	
		local stateColor, stateText, longText, _ = self:GetStateText(state)
		return string.format("Player %s: %s", longText, nameText)
		
	else -- if msgFormat == 3 then -- Full
	
		local stateColor, stateText, _, fullText, category = self:GetChangeText(change)
		return string.format("%s%s|r: %s %s", stateColor, category, nameText, fullText)
		
	end
end
	
--------------------------------------------------------------------------------
function GuildTracker:SaveGuildRoster()
--------------------------------------------------------------------------------
	self:Debug("Storing guild roster")
	
	local updated, added, removed = 0, 0, 0
	local lastusedIdx = 1
	
	-- Update the saved roster entries, and remove the ones that no longer exist
	for idx = 1, #self.GuildDB.roster  do
		local info = self.GuildDB.roster[idx]
		self.GuildDB.roster[lastusedIdx] = info
		
		local newPlayerInfo = self:FindPlayerByName(self.GuildRoster, info[Field.Name])	
		if newPlayerInfo ~= nil then
			lastusedIdx = lastusedIdx + 1
			updated = updated + 1
			
			for _, key in pairs(Field) do
				info[key] = newPlayerInfo[key]
			end
		end
	end
	for idx = lastusedIdx, #self.GuildDB.roster do
		self.GuildDB.roster[idx] = nil
	end
	
	-- Add any new roster entries
	for idx = 1, #self.GuildRoster do
		local info = self.GuildRoster[idx]
		local oldPlayerInfo = self:FindPlayerByName(self.GuildDB.roster, info[Field.Name])
		if oldPlayerInfo == nil then
			added = added + 1
			local newInfo = tcopy(info)
			tinsert(self.GuildDB.roster, newInfo)
		end
	end
	
	self.GuildDB.updated = self.LastRosterUpdate
	
	self:Debug(string.format("Roster: %d added, %d removed, %d updated", added, removed, updated))
end

--------------------------------------------------------------------------------
function GuildTracker:ReportNewChanges()
--------------------------------------------------------------------------------
	local newChanges = false
	
	for _,changeList in pairs(self.ChangesPerState) do
		for _,changeIdx in ipairs(changeList) do
		
			local change = self.GuildDB.changes[changeIdx]
			
			-- Only report new changes
			if change.timestamp >= self.LastRosterUpdate then
				newChanges = true
				-- Chat alert
				if self.db.profile.options.alerts.chatmessage then
					local msg = self:GetAlertMessage(change, self.db.profile.options.alerts.messageformat, true)
					self:Print(msg)
				end
			end
			
		end
	end
	
	if newChanges then
		-- Sound alert
		if self.db.profile.options.alerts.sound then
			PlaySoundFile("Sound\\Interface\\AlarmClockWarning1.wav")
		end
	end
end

--------------------------------------------------------------------------------
function GuildTracker:FindPlayerByName(list, name)
--------------------------------------------------------------------------------
	for i = 1, #list do
		local info = list[i]
		if info[Field.Name] == name then
			return info
		end
	end
	return nil
end

--------------------------------------------------------------------------------
function GuildTracker:RemoveChange(idx)
--------------------------------------------------------------------------------
	self:Debug("Removing change " .. idx)
	if self.GuildDB ~= nil then
		tremove(self.GuildDB.changes, idx)
	end
	self:SortAndGroupChanges()
	self:UpdateLDB()
end

--------------------------------------------------------------------------------
function GuildTracker:RemoveAllChanges()
--------------------------------------------------------------------------------
	self:Debug("Clearing all guild changes")
	if self.GuildDB ~= nil then
		self.GuildDB.changes = {}
		self.ChangesPerState = {}
		self:UpdateLDB()
	end
end

--------------------------------------------------------------------------------
function GuildTracker:ClearGuild()
--------------------------------------------------------------------------------
	self:Debug("Clearing all guild data")
	if self.GuildDB ~= nil then
		self.GuildDB.roster = {}
		self.GuildDB.changes = {}
		self.GuildRoster = {}
		self.ChangesPerState = {}
		self:UpdateLDB()
	end
end

--------------------------------------------------------------------------------
function GuildTracker:HandleSortCommand(sortkey)
--------------------------------------------------------------------------------
	local currentsort = self.db.profile.options.tooltip.sorting
	local currentdirection = self.db.profile.options.tooltip.sort_ascending
	
	self.db.profile.options.tooltip.sorting = sortkey
	
	if currentsort ~= sortkey then
		self.db.profile.options.tooltip.sort_ascending = true
	else
		self.db.profile.options.tooltip.sort_ascending = not currentdirection
	end

	self:SortAndGroupChanges()
	self:UpdateTooltip()
end


--------------------------------------------------------------------------------
function GuildTracker:AnnounceAllChanges()
--------------------------------------------------------------------------------
	if self.GuildDB ~= nil then
		for idx = 1, math.min(#self.GuildDB.changes, 10) do
			self:AnnounceChange(idx, true)
		end	
	end
end

--------------------------------------------------------------------------------
function GuildTracker:AnnounceChange(idx, sendDirectly)
--------------------------------------------------------------------------------
	if self.GuildDB == nil then
		return
	end
	
	local change = self.GuildDB.changes[idx]
	local item = (change.type == State.GuildLeave or change.type == State.NameChange) and change.oldinfo or change.newinfo
	
	local _, _, longText, changeText = self:GetChangeText(change)
	
	local msg = string.format("%s (%d %s) %s", item[Field.Name], item[Field.Level], toproper(item[Field.Class]), changeText)
	
	if self.db.profile.output.timestamp then
		local txtTimestamp

		if self.db.profile.output.overridetimeformat then
			txtTimestamp = date("%d-%m-%y %H:%M", change.timestamp)
		else
			txtTimestamp = self:GetFormattedTimestamp(change.timestamp) 
		end
		
		msg = string.format("[%s] %s", txtTimestamp , msg)
	end

	-- Insert text to edit box
	if sendDirectly then
	
		-- Send straight to chat channel
		for chat, state in pairs(self.db.profile.output.chat) do
			if state then
				if (chat ~= "RAID" or IsInRaid()) and
					 (chat ~= "PARTY" or IsInGroup()) and
					 (chat ~= "RAID_WARNING" or UnitIsRaidOfficer("player") or UnitIsRaidLeader("player")) then
					SendChatMessage(msg, chat)
				end
			end
		end
		
		for channel, state in pairs(self.db.profile.output.channel) do
			if state then
				local chanNr = GetChannelName(channel)
				if chanNr then
					SendChatMessage(msg, "CHANNEL", nil, chanNr)
				end
			end
		end
		
	else -- not sendDirectly
	
		-- Just place it in the chat edit box
		if IsShiftKeyDown() or ChatFrame1EditBox:IsVisible() then
			ChatFrame1EditBox:Show()
			ChatFrame1EditBox:SetFocus()
			ChatFrame1EditBox:SetText(msg)
		end
	end
end


--------------------------------------------------------------------------------
function GuildTracker:GetStateText(state)
--------------------------------------------------------------------------------
	local info = StateInfo[state]
	if info ~= nil then
		return info.color, info.shorttext, info.longtext, info.template, info.category
	else
		return RGB2HEX(0.5,0.5,0.5), "Other", "has an unknown state", "??", "Unknown"
	end
end

--------------------------------------------------------------------------------
function GuildTracker:GetChangeText(change)
--------------------------------------------------------------------------------
	local state = change.type
	local stateColor, shortText, longText, template, category = self:GetStateText(state)
	
	if state == State.GuildJoin or state == State.GuildLeave then
		local note = ((state == State.GuildJoin) and change.newinfo[Field.Note] or change.oldinfo[Field.Note]) or ""
		template = string.format(template, note)	
	elseif state == State.RankUp or state == State.RankDown then
		local oldRank = GuildControlGetRankName(change.oldinfo[Field.Rank]+1)
		local newRank = GuildControlGetRankName(change.newinfo[Field.Rank]+1)
		template = string.format(template, oldRank, newRank)
	elseif state == State.Active then
		local days = self:GetFormattedLastOnline(change.oldinfo[Field.LastOnline])
		template = string.format(template, days)
	elseif state == State.Inactive then
		local days = self.db.profile.options.inactive
		template = string.format(template, days)
	elseif state == State.LevelChange then
		local level = change.newinfo[Field.Level]
		local diff = level - change.oldinfo[Field.Level]
		template = string.format(template, diff, pluralize(diff), level)
	elseif state == State.NoteChange then
		local oldNote = change.oldinfo[Field.Note]
		local newNote = change.newinfo[Field.Note]
		template = string.format(template, oldNote, newNote)
	elseif state == State.NameChange then
		local oldName = change.oldinfo[Field.Name]
		local newName = change.newinfo[Field.Name]
		template = string.format(template, newName)
	end

	return stateColor, shortText, longText, template, category
end


--------------------------------------------------------------------------------
function GuildTracker:UpdateLDB()
--------------------------------------------------------------------------------
	self:UpdateText()
	self:UpdateTooltip()
end

--------------------------------------------------------------------------------
function GuildTracker:UpdateText()
--------------------------------------------------------------------------------
	self:Debug("Updating text")
	
	local clr = CLR_GRAY
	local text = "n/a"
	
	if self.GuildDB then
		local changeCount = #self.GuildDB.changes
		--local rosterCount = #self.GuildDB.roster
		
		if changeCount > 0 then
			clr = RGB2HEX(0.5,1,0.5)
		else
			clr = RGB2HEX(1,1,1)
		end
		text = string.format("%d", changeCount)
	end
	
	self.dbo.text = clr .. text
end

local function OnToggleButton(_, idx, button)
	if idx ~= nil then
		GuildTracker.db.profile.options.tooltip.panel[idx] = not GuildTracker.db.profile.options.tooltip.panel[idx]
	else
		local visible = not GuildTracker:HasVisiblePanel()
		for key, val in pairs(State) do
			GuildTracker.db.profile.options.tooltip.panel[val] = visible
		end
	end
	GuildTracker:UpdateTooltip()
end

local function OnChatButton(_, idx, button)
	if idx ~= nil then
		local sendDirectly = not IsShiftKeyDown()	
		GuildTracker:AnnounceChange(idx, sendDirectly)
	else
		GuildTracker:AnnounceAllChanges()
	end
end

local function OnDeleteButton(_, idx, button)
	if idx ~= nil then
		GuildTracker:RemoveChange(idx)
	else
		--GuildTracker:RemoveAllChanges()
		if LibQTip:IsAcquired("GuildTrackerTip") then
			local tooltip = LibQTip:Acquire("GuildTrackerTip")
			tooltip:Hide()
		end
		StaticPopup_Show("GUILDTRACKER_REMOVEALL")
	end
end

local function OnSortHeader(_, sortkey, button)
	GuildTracker:HandleSortCommand(sortkey)
end

local function ShowSimpleTooltip(cell, text)
    GameTooltip:SetClampedToScreen(true)
    GameTooltip:SetOwner(cell, "ANCHOR_TOPLEFT", -10, -2)
    GameTooltip:SetFrameLevel(cell:GetFrameLevel() + 1)
    if ( type(text) == "table" ) then
        GameTooltip:SetText(text[1])
        GameTooltip:AddLine(text[2], 1.0, 1.0, 1.0)
        GuildTracker:SetTooltipContent(GameTooltip, select(3, unpack(text)))
    elseif ( text:find("|H") ) then
        GuildTracker:SetHyperlink(GameTooltip, text)
    else
        GameTooltip:SetText(text)
    end
    GameTooltip:Show()
end

local function HideSimpleTooltip(cell)
    GameTooltip:Hide()
end

--------------------------------------------------------------------------------
function GuildTracker:SetTooltipContent(tooltip, ...)
--------------------------------------------------------------------------------
    for i = 1, select("#", ...) do
        tooltip:AddLine(select(i, ...), GREEN_FONT_COLOR.r, GREEN_FONT_COLOR.g, GREEN_FONT_COLOR.b, 1);
    end
end

--------------------------------------------------------------------------------
function GuildTracker:HasVisiblePanel()
--------------------------------------------------------------------------------
	for key, val in pairs(State) do
		if self.db.profile.options.tooltip.panel[val] then
			return true
		end
	end
	return false
end

--------------------------------------------------------------------------------
function GuildTracker:UpdateTooltip()
--------------------------------------------------------------------------------
	if not LibQTip:IsAcquired("GuildTrackerTip") then
		return
	end
	self:Debug("Updating tooltip")
	
	local tooltip = LibQTip:Acquire("GuildTrackerTip")
	local padding = 10
	local columns = 10
	local lineNum, colNum
	
	tooltip:Clear()
	
	local lineNum, colNum
	tooltip:SetColumnLayout(columns, "LEFT", "LEFT", "LEFT", "CENTER", "LEFT", "CENTER", "LEFT", "RIGHT", "LEFT", "LEFT")
	
	lineNum = tooltip:AddHeader()
	tooltip:SetCell(lineNum, 1, "|cfffed100Guild Tracker", tooltip:GetHeaderFont(), "CENTER", tooltip:GetColumnCount())
	lineNum = tooltip:AddLine(" ")

	lineNum = tooltip:AddLine()
	
	lineNum = tooltip:AddLine()
	
	if self.db.profile.options.tooltip.grouping then
	
		colNum = 1
		lineNum, colNum = tooltip:SetCell(lineNum, colNum, string.format(ICON_TOGGLE, (not self:HasVisiblePanel()) and "Plus" or "Minus"))
		tooltip:SetCellScript(lineNum, colNum-1, "OnMouseDown", OnToggleButton)
	
	else
	
		colNum = 2
		
	end

	lineNum, colNum = tooltip:SetCell(lineNum, colNum, "|cffffd200".."Type", nil, nil, nil, nil, 0, padding, nil, 75)
	lineNum, colNum = tooltip:SetCell(lineNum, colNum, "|cffffd200".."Name", nil, nil, nil, nil, 0, padding, nil, 75)
	lineNum, colNum = tooltip:SetCell(lineNum, colNum, "|cffffd200".."Level", nil, "CENTER", nil, nil, 0, padding, nil, 35)
	lineNum, colNum = tooltip:SetCell(lineNum, colNum, "|cffffd200".."Rank", nil, nil, nil, nil, 0, padding, nil, 75)
	lineNum, colNum = tooltip:SetCell(lineNum, colNum, "|cffffd200".."Offline", nil, "RIGHT", nil, nil, 0, padding, nil, 60)
	lineNum, colNum = tooltip:SetCell(lineNum, colNum, "|cffffd200".."Note", nil, nil, nil, nil, 0, padding, 250, 150)
	lineNum, colNum = tooltip:SetCell(lineNum, colNum, (self.db.profile.options.timeformat == 4) and ICON_TIMESTAMP or "|cffffd200".."Timestamp")

	
	tooltip:SetCellScript(lineNum, 2, "OnMouseUp", OnSortHeader, "Type")
	tooltip:SetCellScript(lineNum, 2, "OnEnter", ShowSimpleTooltip, "Sort by Type")
	tooltip:SetCellScript(lineNum, 2, "OnLeave", HideSimpleTooltip)
	
	tooltip:SetCellScript(lineNum, 3, "OnMouseUp", OnSortHeader, "Name")
	tooltip:SetCellScript(lineNum, 3, "OnEnter", ShowSimpleTooltip, "Sort by Name")
	tooltip:SetCellScript(lineNum, 3, "OnLeave", HideSimpleTooltip)

	tooltip:SetCellScript(lineNum, 4, "OnMouseUp", OnSortHeader, "Level")
	tooltip:SetCellScript(lineNum, 4, "OnEnter", ShowSimpleTooltip, "Sort by Level")
	tooltip:SetCellScript(lineNum, 4, "OnLeave", HideSimpleTooltip)

	tooltip:SetCellScript(lineNum, 5, "OnMouseUp", OnSortHeader, "Rank")
	tooltip:SetCellScript(lineNum, 5, "OnEnter", ShowSimpleTooltip, "Sort by Rank")
	tooltip:SetCellScript(lineNum, 5, "OnLeave", HideSimpleTooltip)
	
	tooltip:SetCellScript(lineNum, 6, "OnMouseUp", OnSortHeader, "Offline")
	tooltip:SetCellScript(lineNum, 6, "OnEnter", ShowSimpleTooltip, "Sort by last online time")
	tooltip:SetCellScript(lineNum, 6, "OnLeave", HideSimpleTooltip)
	
	tooltip:SetCellScript(lineNum, 8, "OnMouseUp", OnSortHeader, "Timestamp")
	tooltip:SetCellScript(lineNum, 8, "OnEnter", ShowSimpleTooltip, "Sort by Timestamp")
	tooltip:SetCellScript(lineNum, 8, "OnLeave", HideSimpleTooltip)
	
	
	lineNum, colNum = tooltip:SetCell(lineNum, colNum, ICON_CHAT)
	tooltip:SetCellScript(lineNum, tooltip:GetColumnCount()-1, "OnMouseUp", OnChatButton)	
	tooltip:SetCellScript(lineNum, tooltip:GetColumnCount()-1, "OnEnter", ShowSimpleTooltip, "Click to broadcast all changes to configured channel (limited to first 10)")
	tooltip:SetCellScript(lineNum, tooltip:GetColumnCount()-1, "OnLeave", HideSimpleTooltip)
	
	lineNum, colNum = tooltip:SetCell(lineNum, colNum, ICON_DELETE)
	tooltip:SetCellScript(lineNum, tooltip:GetColumnCount(), "OnMouseUp", OnDeleteButton)
	tooltip:SetCellScript(lineNum, tooltip:GetColumnCount(), "OnEnter", ShowSimpleTooltip, "Click to delete all changes")
	tooltip:SetCellScript(lineNum, tooltip:GetColumnCount(), "OnLeave", HideSimpleTooltip)
	
	lineNum = tooltip:AddSeparator(2)
	local curLine = lineNum
	
	if self.GuildDB == nil then
		self:AddMessageToTooltip("You are not in a guild", tooltip, 1)
		return
	end

	if self.db.profile.options.tooltip.grouping then
	
		for stateidx,changeList in pairs(self.ChangesPerState) do
			if #changeList > 0 then
				local headerLineNum = lineNum + 1
	
				local groupColor, groupCaption = self:GetStateText(stateidx)
				if #changeList > 0 then
					groupCaption = groupCaption .. string.format("|r (%d)", #changeList)
				end
			
				if not self.db.profile.options.tooltip.panel[stateidx] then
				
					lineNum = self:AddMessageToTooltip(groupColor .. groupCaption, tooltip, 2)
					
				else
				
					if self.db.profile.options.tooltip.panel[stateidx] then
						for _,changeIdx in ipairs(changeList) do
							local change = self.GuildDB.changes[changeIdx]
							lineNum = self:AddChangeItemToTooltip(change, tooltip, changeIdx)
						end
					end
					
				end
				
				tooltip:SetCell(headerLineNum, 1, string.format(ICON_TOGGLE, (not self.db.profile.options.tooltip.panel[stateidx]) and "Plus" or "Minus"), "LEFT")
				tooltip:SetLineScript(headerLineNum, "OnMouseDown", OnToggleButton, stateidx)
			end
		end
		
	else
	
		for idx,change in ipairs(self.GuildDB.changes) do
			lineNum = self:AddChangeItemToTooltip(change, tooltip, idx)
		end
		
	end
	
	if curLine == lineNum then
		self:AddMessageToTooltip("No guild changes detected", tooltip, 1)
	end
	
	if #self.GuildDB.changes > 0 then
		tooltip:UpdateScrolling()
	end
end

--------------------------------------------------------------------------------
function GuildTracker:AddMessageToTooltip(msg, tooltip, startColumn)
--------------------------------------------------------------------------------
	lineNum = tooltip:AddLine()
	tooltip:SetCell(lineNum, startColumn, msg, nil, "LEFT", tooltip:GetColumnCount() - startColumn)
	return lineNum
end

--------------------------------------------------------------------------------
function GuildTracker:AddChangeItemToTooltip(changeItem, tooltip, itemIdx)
--------------------------------------------------------------------------------
	local lineNum, colNum
	local item = changeItem.newinfo
	
	local changeType = changeItem.type
	
	if changeType == State.GuildLeave then
		item = changeItem.oldinfo
	end

	local clrChange, txtChange = self:GetStateText(changeType)
	local txtName = RAID_CLASS_COLORS_hex[item[Field.Class]] .. item[Field.Name]
	local txtLevel = item[Field.Level]
	local txtRank = GuildControlGetRankName(item[Field.Rank]+1)
	local txtNote = item[Field.Note]
	local txtOffline = self:GetFormattedLastOnline(item[Field.LastOnline])
	local txtTimestamp, fullTimestamp = self:GetFormattedTimestamp(changeItem.timestamp)

	-- Override special case
	if self.db.profile.options.timeformat == 4 then
		txtTimestamp = ICON_TIMESTAMP
	end

	local oldName = nil
	local oldLevel = nil
	local oldRank = nil
	local oldNote = nil
	local oldOffline = nil
	
	if changeType == State.RankUp or changeType == State.RankDown then
		oldRank = GuildControlGetRankName(changeItem.oldinfo[Field.Rank]+1)
		txtRank = CLR_YELLOW .. txtRank
	elseif changeType == State.Active or changeType == State.Inactive then
		oldOffline = self:GetFormattedLastOnline(changeItem.oldinfo[Field.LastOnline])
		txtOffline = CLR_YELLOW .. txtOffline
	elseif changeType == State.LevelChange then
		oldLevel = changeItem.oldinfo[Field.Level] .. string.format(CLR_GRAY .. " (%s%d)", (item[Field.Level] > changeItem.oldinfo[Field.Level]) and "+" or "-", math.abs(item[Field.Level] - changeItem.oldinfo[Field.Level]))
		txtLevel = CLR_YELLOW .. txtLevel
	elseif changeType == State.NoteChange then
		oldNote = changeItem.oldinfo[Field.Note]
		txtNote = CLR_YELLOW .. txtNote
	elseif changeType == State.NameChange then
		oldName = changeItem.oldinfo[Field.Name]
	end

	lineNum = tooltip:AddLine()
	colNum = 2
	
	lineNum, colNum = tooltip:SetCell(lineNum, colNum, clrChange .. txtChange)
	lineNum, colNum = tooltip:SetCell(lineNum, colNum, txtName)
	if oldName then
		tooltip:SetCellScript(lineNum, colNum-1, "OnEnter", ShowSimpleTooltip, {"Previous name:", oldName})
		tooltip:SetCellScript(lineNum, colNum-1, "OnLeave", HideSimpleTooltip)
	end
	lineNum, colNum = tooltip:SetCell(lineNum, colNum, txtLevel)
	if oldLevel then
		tooltip:SetCellScript(lineNum, colNum-1, "OnEnter", ShowSimpleTooltip, {"Previous level:", oldLevel})
		tooltip:SetCellScript(lineNum, colNum-1, "OnLeave", HideSimpleTooltip)
	end
	lineNum, colNum = tooltip:SetCell(lineNum, colNum, txtRank)
	if oldRank then
		tooltip:SetCellScript(lineNum, colNum-1, "OnEnter", ShowSimpleTooltip, {"Previous rank: ", oldRank})
		tooltip:SetCellScript(lineNum, colNum-1, "OnLeave", HideSimpleTooltip)
	end
	
	lineNum, colNum = tooltip:SetCell(lineNum, colNum, txtOffline)
	if oldOffline then
		tooltip:SetCellScript(lineNum, colNum-1, "OnEnter", ShowSimpleTooltip, {"Previously offline: ", oldOffline})
		tooltip:SetCellScript(lineNum, colNum-1, "OnLeave", HideSimpleTooltip)
	end
	
	lineNum, colNum = tooltip:SetCell(lineNum, colNum, txtNote)
	if oldNote then
		tooltip:SetCellScript(lineNum, colNum-1, "OnEnter", ShowSimpleTooltip, {"Previous note: ", oldNote})
		tooltip:SetCellScript(lineNum, colNum-1, "OnLeave", HideSimpleTooltip)
	end
	
	lineNum, colNum = tooltip:SetCell(lineNum, colNum, txtTimestamp)
	if self.db.profile.options.timeformat > 1 then
		tooltip:SetCellScript(lineNum, colNum-1, "OnEnter", ShowSimpleTooltip, {"Change was detected on: ", fullTimestamp})
		tooltip:SetCellScript(lineNum, colNum-1, "OnLeave", HideSimpleTooltip)
	end
	
	lineNum, colNum = tooltip:SetCell(lineNum, colNum, ICON_CHAT)
	tooltip:SetCellScript(lineNum, tooltip:GetColumnCount()-1, "OnMouseUp", OnChatButton, itemIdx)
	tooltip:SetCellScript(lineNum, tooltip:GetColumnCount()-1, "OnEnter", ShowSimpleTooltip, "Click to broadcast to configured channel, hold Shift to paste into chat edit box")
	tooltip:SetCellScript(lineNum, tooltip:GetColumnCount()-1, "OnLeave", HideSimpleTooltip)
	
	lineNum, colNum = tooltip:SetCell(lineNum, colNum, ICON_DELETE)
	tooltip:SetCellScript(lineNum, tooltip:GetColumnCount(), "OnMouseUp", OnDeleteButton, itemIdx)
	tooltip:SetCellScript(lineNum, tooltip:GetColumnCount(), "OnEnter", ShowSimpleTooltip, "Click to delete this entry")
	tooltip:SetCellScript(lineNum, tooltip:GetColumnCount(), "OnLeave", HideSimpleTooltip)
	
	
	return lineNum

end



--------------------------------------------------------------------------------
function GuildTracker:GetFormattedLastOnline(days)
--------------------------------------------------------------------------------
	if days == nil or days == 0 then
		return "--"
	else
		return string.format("%.1f days", days)
	end
end


--------------------------------------------------------------------------------
function GuildTracker:GetFormattedTimestamp(timestamp)
--------------------------------------------------------------------------------
	local fullTimestamp, diffText, smartText, dateText = self:CalculateTimestampFormats(timestamp)
	
	local txtTimestamp
	local timeFormat = self.db.profile.options.timeformat
	if timeFormat == 1 then
		txtTimestamp = fullTimestamp
	elseif timeFormat == 2 then
		txtTimestamp = diffText
	elseif timeFormat == 3 then
		txtTimestamp = smartText
	elseif timeFormat == 4 then
		txtTimestamp = dateText
	end
	
	return txtTimestamp, fullTimestamp
end

--------------------------------------------------------------------------------
function GuildTracker:CalculateTimestampFormats(timestamp)
--------------------------------------------------------------------------------
	local fullTimestamp = date("%d-%m-%y %H:%M:%S", timestamp)
	local diffText
	local smartText
	
	local diff = time() - timestamp
	local datepart = date("%d-%m-%y", timestamp)
	
	if diff > 31536000 then
		local years = math.floor(diff / 31536000)
		diffText = string.format("%d year%s ago", years, pluralize(years))
	elseif diff > 2628029 then
		local months = math.floor(diff / 2628029)
		diffText = string.format("%d month%s ago", months, pluralize(months))
	elseif diff > 86400 then
		local days = math.floor(diff / 86400)
		diffText = string.format("%d day%s ago", days, pluralize(days))
	elseif diff > 3600 then
		local hours = math.floor(diff / 3600)
		diffText = string.format("%d hour%s ago", hours, pluralize(hours))
	elseif diff > 60 then
		local minutes = math.floor(diff / 60)
		diffText = string.format("%s minute%s ago", minutes, pluralize(minutes))
	else
		diffText = "< 1 minute ago"
	end
	
	if datepart == date("%d-%m-%y", time()) then -- Today
		smartText = date("Today %H:%M", timestamp)
	elseif datepart == date("%d-%m-%y", time() - 86400) then -- Yesterday
		smartText = date("Yesterday %H:%M", timestamp)
	elseif diff < 604800 then
		smartText = "Last week"
	else
		smartText  = "Over a week ago"
	end
	
	return fullTimestamp, diffText, smartText, datepart
end


--------------------------------------------------------------------------------
function GuildTracker:GenerateChange(state)
--------------------------------------------------------------------------------
	local MyNewInfo = {
		[Field.Name] = UnitName("player"),
		[Field.Rank] = 1,
		[Field.Class] = select(2, UnitClass("player")),
		[Field.Level] = math.max(UnitLevel("player"), 3),
		[Field.Note] = "Wooly bear",
		[Field.LastOnline] = 15.1,
		[Field.SoR] = false,
	}
	local MyOldInfo = {
		[Field.Name] = MyNewInfo[Field.Name],
		[Field.Rank] = MyNewInfo[Field.Rank] + 1,
		[Field.Class] = MyNewInfo[Field.Class],
		[Field.Level] = MyNewInfo[Field.Level] - 2,		
		[Field.Note] = "Vicious cat",
		[Field.LastOnline] = 10.0,
		[Field.SoR] = true,
	}
	local change = {
		oldinfo = MyOldInfo,
		newinfo = MyNewInfo,
		timestamp = time(),
		type = state,
	}
	return change
end


----- DEBUGGING
--------------------------------------------------------------------------------
function GuildTracker:Debug(msg)
--------------------------------------------------------------------------------
	if self.db.profile.debug then
		self:Print("[DEBUG] "..msg.."|r")
	end
end

--------------------------------------------------------------------------------
function GuildTracker:ApplyTest()
--------------------------------------------------------------------------------
	self.LastRosterUpdate = time()
	
	local testitem1 = self:FindPlayerByName(self.GuildRoster, "Crossbow")
	testitem1[Field.Rank] = 8
	
	local testitem2 = self:FindPlayerByName(self.GuildRoster, "Boozie")
	testitem2[Field.LastOnline] = 65

	local testitem3 = self:FindPlayerByName(self.GuildRoster, "Aloryna")
	testitem3[Field.Level] = 15

	local testitem4 = self:FindPlayerByName(self.GuildRoster, "Atuad")
	testitem4[Field.Note] = "Test note"
	
	local testitem5 = self:FindPlayerByName(self.GuildRoster, "Ironica")
	testitem5[Field.Name] = "Orinaci"
	
	tremove(self.GuildRoster, 1)
	
	self:UpdateGuildChanges()
	self:SaveGuildRoster()
	self:ReportNewChanges()
	self:UpdateLDB()
end

----- CONFIG
--------------------------------------------------------------------------------
function GuildTracker:GetDefaults()
--------------------------------------------------------------------------------	
	-- declare defaults to be used in the DB
	return {
		realm = {
			guild = {
			}
		},
		profile = {
			debug = false,
			enabled = true,
			options = {
				autoreset = false,
				autorefresh = true,
				expiredays = 3,
				inactive = 30,
				timeformat = 2,
				minimap = {
					hide = true,
				},
				alerts = {
					sound = true,
					chatmessage = true,
					messageformat = 3,
				},
				filter = {
					[1] = true,
					[2] = true,
					[3] = true,
					[4] = true,
					[5] = true,
					[6] = true,
					[7] = true,
					[8] = true,
					[9] = true,
					[10] = true,
					[11] = true,
				},				
				tooltip = {
					grouping = false,
					sorting = "Timestamp",
					sort_ascending = true,
					panel = {}
				},
			},
			output = {
				timestamp = true,
				overridetimeformat = true,
				chat = {
					SAY = false,
					SHOUT = false,
					PARTY = false,
					GUILD = true,
					RAID = false,
					RAID_WARNING = false,
				},
				channel = {
				},
			},
		}
	}
end

--------------------------------------------------------------------------------
function GuildTracker:GetOptions()
--------------------------------------------------------------------------------	
	return {
		name = "Guild Tracker",
		type = "group",
		args = {
			enabled = {
				name = "Enabled",
				desc = "Enable or disable the addon",
				type = "toggle",
				order = 1,
				disabled = true,
				get = function(key) return self.db.profile.enabled end,
				set = function(key, value)
					self.db.profile.enabled = value
					if self.db.profile.enabled then
						self:Enable()
					else
						self:Disable()
					end
				end,
			},
			debug = {
				name = "Debug",
				desc = "Enable or disable debug output",
				type = "toggle",
				order = 2,
				get = function(key) return self.db.profile.debug end,
				set = function(key, value) self.db.profile.debug = value end,
			},
			options = {
				name = "Options",
				desc = "Control general options",
				type = "group",
				args = {
					autoreset = {
						name = CLR_YELLOW .. "Auto-clear changes",
						desc = "Automatically clear all changes on logout or UI reload",
						descStyle = "inline",
						type = "toggle",
						width = "full",						
						order = 1,
						get = function(key) return self.db.profile.options.autoreset end,
						set = function(key, value) self.db.profile.options.autoreset = value end,
					},
				 	autorefresh = {
						name = CLR_YELLOW .. "Auto-refresh roster",
						desc = "Periodically scan guild roster for faster updates",
						descStyle = "inline",
						type = "toggle",
						width = "full",						
						order = 3,
						get = function(key) return self.db.profile.options.autorefresh	end,
						set = function(key, value)
							self.db.profile.options.autorefresh = value
							self:PLAYER_GUILD_UPDATE()
						end,
				 	},
					grouping = {
						name = CLR_YELLOW .. "Group changes by type",
						desc = "Create collapsible group panels in the tooltip",
						descStyle = "inline",
						type = "toggle",
						width = "full",
						order = 4,
						get = function(key) return self.db.profile.options.tooltip.grouping end,
						set = function(key, value) self.db.profile.options.tooltip.grouping = value end,
					},
					minimap = {
						name = CLR_YELLOW .. "Minimap icon",
						desc = "Display a separate minimap icon",
						descStyle = "inline",
						type = "toggle",
						width = "full",
						order = 5,
						get = function(key) return not self.db.profile.options.minimap.hide end,
						set = function(key, value)
							self.db.profile.options.minimap.hide = not value
							self:UpdateMinimapIcon()
						end,
					},
					timeformat = {
						name = CLR_YELLOW .. "Timestamp format",
						desc = function()
							local f11,f12,f13,f14 = self:CalculateTimestampFormats(time() - 12000)
							local f21,f22,f23,f24 = self:CalculateTimestampFormats(time() - 420000)
							return "Controls the formatting of the timestamp in the tooltip and chat messages\n\n"..
								CLR_YELLOW..TimeFormat[1].."|r\n"..f11.."\n"..f21.."\n\n"..
								CLR_YELLOW..TimeFormat[2].."|r\n"..f12.."\n"..f22.."\n\n"..
								CLR_YELLOW..TimeFormat[3].."|r\n"..f13.."\n"..f23.."\n\n"..
								CLR_YELLOW..TimeFormat[4].."|r\n"..ICON_TIMESTAMP .. CLR_GRAY .. " or|r " .. f14 .. "\n".. ICON_TIMESTAMP .. CLR_GRAY .. " or|r " .. f24
						end,
						type = "select",
						order = 6,
						values = function() return self:GetTableValues(TimeFormat) end,
						get = function(key) return self.db.profile.options.timeformat end,
						set = function(key, value) self.db.profile.options.timeformat = value end,
					},
					filter = {
						name = "Filter",
						desc = "Control which types of changes are tracked",
						type = "group",
						order = 2,
						get = function(key) return self.db.profile.options.filter[key.arg] end,
						set = function(key, value) self.db.profile.options.filter[key.arg] = value end,
						args = {
							-- Checkboxes are dynamically injected here
							header = {
								name = "",
								order = 20,
								type = "header",
							},
							inactive = {
								name = "Inactivity threshold",
								desc = "Set the amount of offline days before a player is marked inactive",
								type = "range",
								order = 21,
								min = 1,
								softMax = 365,
								step = 1,
								bigStep = 5,
								get = function(key) return self.db.profile.options.inactive end,
								set = function(key, value) self.db.profile.options.inactive = value end,
							},							
						},
					},
					alerts = {
						name = "Alerts",
						desc = "Control the local alerts when guild changes are detected",
						type = "group",
						order = 3,
						args = {
							sound = {
								name = CLR_YELLOW .. "Play sound",
								desc = "Play a sound when a guild change is detected",
								descStyle = "inline",
								type = "toggle",
								width = "full",
								order = 1,
								get = function(key) return self.db.profile.options.alerts.sound end,
								set = function(key, value) self.db.profile.options.alerts.sound = value end,
							},	
							chatmessage = {
								name = CLR_YELLOW .. "Show chat message",
								desc = "Display a message in the chat frame when a guild change is detected",
								descStyle = "inline",
								type = "toggle",
								width = "full",
								order = 2,
								get = function(key) return self.db.profile.options.alerts.chatmessage end,
								set = function(key, value) self.db.profile.options.alerts.chatmessage = value end,
							},
							messageformat = {
								name = "Message format",
								desc = function()
									local change1 = self:GenerateChange(State.GuildJoin)
									local change2 = self:GenerateChange(State.LevelChange)
									local f11,f21 = self:GetAlertMessage(change1, 1), self:GetAlertMessage(change2, 1)
									local f12,f22 = self:GetAlertMessage(change1, 2), self:GetAlertMessage(change2, 2)
									local f13,f23 = self:GetAlertMessage(change1, 3), self:GetAlertMessage(change2, 3)
									return "Controls the format of the alert message\n\n"..
										CLR_YELLOW..ChatFormat[1].."|r\n"..f11.."\n"..f21.."\n\n"..
										CLR_YELLOW..ChatFormat[2].."|r\n"..f12.."\n"..f22.."\n\n"..
										CLR_YELLOW..ChatFormat[3].."|r\n"..f13.."\n"..f23
								end,
								type = "select",
								disabled = function() return not self.db.profile.options.alerts.chatmessage end,
								order = 3,
								values = function() return self:GetTableValues(ChatFormat) end,
								get = function(key) return self.db.profile.options.alerts.messageformat end,
								set = function(key, value) self.db.profile.options.alerts.messageformat = value end,
							},
						
						}
					},
					output = {
						name = "Output",
						desc = "Control the destination and formatting of the outgoing chat messages",
						type = "group",
						order = 4,
						disabled = function() return not self.db.profile.enabled end,
						args = {
							channel = {
								name = "Default chat types",
								desc = "Send messages to default chat channel",
								type = "multiselect",
								order = 1,
								values = function() return self:GetTableValues(ChatType) end,
								get = function(info, idx) return self:IsChatTypeEnabled(ChatType[idx]) end,
								set = function(info, idx, value) self:EnableChatType(ChatType[idx], value) end,
							},
							custom = {
								name = "Custom channel",
								order = 2,
								type = "multiselect",
								width = "full",
								values = function()
									return self:GetCustomChannelList()
								end,
								get = function(info, nr)
									local _,name = GetChannelName(nr)
									return self:IsCustomChannelEnabled(name)
								end,
								set = function(info, nr, value)
									local _,name = GetChannelName(nr)
									self:EnableCustomChannel(name, value)
								end,
							},
							timestamp = {
								name = CLR_YELLOW .. "Include timestamp",
								desc = "Include the timestamp in the chat message",
								descStyle = "inline",
								type = "toggle",
								width = "full",
								order = 3,
								get = function(key) return self.db.profile.output.timestamp end,
								set = function(key, value) self.db.profile.output.timestamp = value end,
							},				
							overridetimeformat = {
								name = function()
									return (self.db.profile.output.timestamp and CLR_YELLOW or "").. "Override timestamp format"
								end,
								desc = "Always use fixed-width timestamp for chat messages",
								descStyle = "inline",
								type = "toggle",
								width = "full",
								disabled = function() return not self.db.profile.output.timestamp end,
								order = 4,
								get = function(key) return self.db.profile.output.overridetimeformat end,
								set = function(key, value) self.db.profile.output.overridetimeformat = value end,
							},								
						},
					},					
				}
			},
	 	}
	}
end

--------------------------------------------------------------------------------
function GuildTracker:GetTableValues(mytable)
--------------------------------------------------------------------------------
	local out = {}
	for i = 1, table.getn(mytable) do
		out[i] = toproper(mytable[i])
	end
	return out
end

function GuildTracker:GetCustomChannelList()
	local channels = { GetChannelList() }
	local out = {}
	for i = 1, table.getn(channels), 2 do
		out[channels[i]] = channels[i] .. ". " .. channels[i+1]
	end
	return out
end

function GuildTracker:IsCustomChannelEnabled(name)
	return self.db.profile.output.channel[name]
end
function GuildTracker:IsChatTypeEnabled(name)
	return self.db.profile.output.chat[name]
end

function GuildTracker:UpdateMinimapIcon()
	if self.db.profile.options.minimap.hide then
		LDBIcon:Hide("GuildTrackerIcon")
	else
		LDBIcon:Show("GuildTrackerIcon")
	end
end

function GuildTracker:EnableCustomChannel(name, value)
	if value and not self.db.profile.output.channel[name] then
		self.db.profile.output.channel[name] = true
	elseif not value and self.db.profile.output.channel[name] then
		self.db.profile.output.channel[name] = false
	end
end
function GuildTracker:EnableChatType(name, value)
	if value and not self.db.profile.output.chat[name] then
		self.db.profile.output.chat[name] = true
	elseif not value and self.db.profile.output.chat[name] then
		self.db.profile.output.chat[name] = false
	end
end



function GuildTracker:GenerateStateOptions()
	for _,v in pairs(State) do
		if v ~= State.Unchanged then
			self.options.args.options.args.filter.args[tostring(v)] = self:GenerateStateOption(v)
		end
	end
end

function GuildTracker:GenerateStateOption(stateIdx)
	local stateColor, stateText, longText = self:GetStateText(stateIdx)
	return {
			name = stateColor .. stateText,
			desc = string.format("Player %s", longText),
			descStyle = "inline",
			type = "toggle",
			order = stateIdx,
			arg = stateIdx,
	}
end