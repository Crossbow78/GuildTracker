GuildTracker = LibStub("AceAddon-3.0"):NewAddon("GuildTracker", "AceEvent-3.0", "AceConsole-3.0", "AceTimer-3.0")

local DB_VERSION = 4

local ICON_DELETE = "|TInterface\\Buttons\\UI-GroupLoot-Pass-Up:16:16:0:0:16:16:0:16:0:16|t"
local ICON_CHAT = "|TInterface\\ChatFrame\\UI-ChatWhisperIcon:16:16:0:0:16:16:0:16:0:16|t"
local ICON_TIMESTAMP = "|TInterface\\HelpFrame\\HelpIcon-ReportLag:16:16:0:0:16:16:0:16:0:16|t"
local ICON_TOGGLE = "|TInterface\\Buttons\\UI-%sButton-Up:18:18:1:0|t"

local CLR_YELLOW = "|cffffd200"
local CLR_DARKYELLOW = "|caaaa9000"
local CLR_GRAY = "|cff909090"

local ROSTER_REFRESH_THROTTLE = 10
local ROSTER_REFRESH_TIMER = 30
local CHANGE_LIMIT = 50

local LDB = LibStub("LibDataBroker-1.1")
local LibQTip = LibStub:GetLibrary("LibQTip-1.0")
local LDBIcon = LibStub("LibDBIcon-1.0")

--- Some local helper functions
local _G = _G
local tinsert, tremove, tsort, twipe = _G.table.insert, _G.table.remove, _G.table.sort, _G.table.wipe
local pairs, ipairs = _G.pairs, _G.ipairs

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
	tooltip:SetAutoHideDelay(0.1, frame)
	tooltip:EnableMouse(true)

	GuildTracker:UpdateTooltip()
	tooltip:Show()
end

local function do_OnLeave()
end

local function do_OnClick(frame, button)
	--print(button)
	if button == "RightButton" then
		SettingsInbound.OpenToCategory("Guild Tracker")
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

local function sanitizeName(name)
	local hyphen = strfind(name, "-")
	if hyphen ~= nil then
	  if strsub(name, hyphen + 1) == GetRealmName() then
			name = strsub(name, 1, hyphen - 1)
		end
	end
	return name
end


-- The available chat types
local ChatType = { "SAY", "YELL", "GUILD", "OFFICER", "PARTY", "RAID", "INSTANCE_CHAT" }
local ChatFormat = { [1] = "Short", [2] = "Long", [3] = "Full" }
local TimeFormat = { [1] = "Absolute", [2] = "Relative", [3] = "Intuitive", [4] = "Small" }

-- These are name lookup lists
local GuildRoster_reverse = {}
local SavedRoster_reverse = {}

-- The guild information fields we store
local Field = {
	Name = 1,
	Rank = 2,
	Class = 3,
	Level = 4,
	Note = 5,
	OfficerNote = 6,
	LastOnline = 7,
	Points = 8,
	SoR = 9,
	RepStanding = 10,
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
	OfficerNoteChange = 9,	
	NoteChange = 10,
	LevelChange = 11,
	PointsChange = 12,
	NameChange = 13,
	RepChange = 14,
}

local ComboState = {
	[State.RankUp] = State.RankDown,
	[State.RankDown] = State.RankUp,
	[State.AccountDisabled] = State.AccountEnabled,
	[State.AccountEnabled] = State.AccountDisabled,
	[State.GuildJoin] = State.GuildLeave,
	[State.GuildLeave] = State.GuildJoin,
	[State.Inactive] = State.Active,
	[State.Active] = State.Inactive
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
		color = RGB2HEX(1,0.95,0.45),
		category = "Level",
		shorttext = "Level up",
		longtext = "has gained one or more levels",
		template = "is now level %d (gained %d)",
	},
	[State.NoteChange] = {
		color = RGB2HEX(0.79,0.58,0.58),
		category = "Note",
		shorttext = "Note change",
		longtext = "got a new guild note",
		template = "note changed from \"%s\" to \"%s\"",
	},
	[State.OfficerNoteChange] = {
		color = RGB2HEX(0.65,0.45,0.45),
		category = "Note",
		shorttext = "Officer note change",
		longtext = "got a new officer note",
		template = "officer note changed from \"%s\" to \"%s\"",
	},	
	[State.PointsChange] = {
		color = RGB2HEX(1.0,0.72,0.22),
		category = "Points",
		shorttext = "Achievement points",
		longtext = "gained one or more achievements",
		template = "has now %d achievement points (gained %d)",
	},
	[State.NameChange] = {
		color = RGB2HEX(0.15,0.65,0.15),
		category = "Name",
		shorttext = "Name change",
		longtext = "had a name change",
		template = "changed name to \"%s\"",
	},	
	[State.RepChange] = {
		color = RGB2HEX(0.35,0.82,0.48),
		category = "Reputation",
		shorttext = "Guild reputation",
		longtext = "has gone up in guild reputation standing",
		template = "has become %s with the guild",
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
	["Points"] = function(a, b)
				local aInfo = (a.type ~= State.GuildLeave) and a.newinfo or a.oldinfo
				local bInfo = (b.type ~= State.GuildLeave) and b.newinfo or b.oldinfo
				if aInfo[Field.Points] and bInfo[Field.Points] and aInfo[Field.Points] ~= bInfo[Field.Points] then
					if GuildTracker.db.profile.options.tooltip.sort_ascending then
						return aInfo[Field.Points] < bInfo[Field.Points]
					end
					return aInfo[Field.Points] > bInfo[Field.Points]
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
	preferredIndex = STATICPOPUP_NUMDIALOGS,  -- avoid some UI taint, see http://www.wowace.com/announcements/how-to-avoid-some-ui-taint/
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

	self:RegisterAddonCompartment()

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
		C_GuildInfo.GuildRoster()
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
	-- Weird things happen during logout, profile options may have been already cleaned up
	if self.db and self.db.profile and self.db.profile.options and self.db.profile.options.autoreset then
		self:RemoveAllChanges()
	end
end

--------------------------------------------------------------------------------
function GuildTracker:PLAYER_GUILD_UPDATE(event, unit)
--------------------------------------------------------------------------------
	self:Debug("PLAYER_GUILD_UPDATE " .. (unit or "(nil)"))
	if unit and unit ~= "player" then return end
	
	if IsInGuild() then
		self:RegisterEvent("GUILD_ROSTER_UPDATE")
		
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

		self:UnregisterEvent("GUILD_ROSTER_UPDATE")
	end
end

--------------------------------------------------------------------------------
function GuildTracker:GUILD_ROSTER_UPDATE()
--------------------------------------------------------------------------------
	self:Debug("GUILD_ROSTER_UPDATE")

	if self.LastRosterUpdate and time() - self.LastRosterUpdate <= ROSTER_REFRESH_THROTTLE then
		self:Debug("Recently scanned, event ignored")
		return
	end

	if InCombatLockdown() and not self.db.profile.options.scanincombat then
		self:Debug("Not scanning in combat")
		return
	end
	
	self.GuildName, _, _, self.GuildRealm = GetGuildInfo("player")
	if self.GuildName == nil then
		self:Debug("No guildname available yet, event ignored")
		return
	end

	if self.GuildRealm == nil then
		self.GuildRealm = GetRealmName()
	end	

	self.LastRosterUpdate = time()

	-- Load current guild roster into self.GuildRoster
	self:UpdateGuildRoster()

	if #self.GuildRoster == 0 then
		self:Debug("Guild roster still incomplete, event ignored")
		self.LastRosterUpdate = nil
		return
	end

	-- Switch to our current guild database, and initialize if needed
	self:InitGuildDatabase()

	-- Find changes between the saved roster and the current guild roster
	self:UpdateGuildChanges()
	
	-- Save the current guild roster
	self:SaveGuildRoster()
	
	-- Alerts for any new changes
	self:ReportNewChanges()

	-- Merge any similar changes
	self:MergeChanges()
	
	-- Auto expire changes
	self:AutoExpireChanges()
	
	-- Update text and tooltips
	self:UpdateLDB()
end


-- PRE: IsInGuild() == true and self.GuildName ~= nil
--------------------------------------------------------------------------------
function GuildTracker:InitGuildDatabase()
--------------------------------------------------------------------------------	
	local guildname = self.GuildName
	local guildrealm = self.GuildRealm

	-- If necessary, initialize guild database for first use
	if self.db.global.guild == nil then
		self.db.global.guild = {}
	end
	if self.db.global.guild[guildrealm] == nil then
		self.db.global.guild[guildrealm] = {}
	end
	if self.db.global.guild[guildrealm][guildname] == nil then
		-- See if we can migrate realm data
		if (self.db.realm.guild ~= nil and self.db.realm.guild[guildname] ~= nil) then
			self:Print(string.format("Migrating existing database for guild '%s' at realm '%s'", guildname, guildrealm))
			self.db.global.guild[guildrealm][guildname] = tcopy(self.db.realm.guild[guildname])
			self.db.realm.guild[guildname] = nil
		else
			self:Print(string.format("Creating new database for guild '%s' at realm '%s'", guildname, guildrealm))
			self.db.global.guild[guildrealm][guildname] = {
				updated = time(),
				version = DB_VERSION,
				roster = {},
				changes = {}
			}
		end
	else
		self:Debug(string.format("Using existing database for guild '%s' at realm '%s'", guildname, guildrealm))
	end

	self.GuildDB = self.db.global.guild[guildrealm][guildname]

	self:UpgradeGuildDatabase()
end

--------------------------------------------------------------------------------	
function GuildTracker:UpgradeGuildDatabase()
--------------------------------------------------------------------------------	
	if self.GuildDB.version == nil then
		self:Debug("Upgrading database to version 1")
		self.GuildDB.version = 1
		self.GuildDB.isOfficer = C_GuildInfo:CanViewOfficerNote()
	end
	
	if self.GuildDB.version == 1 then
		self:Debug("Upgrading database to version 2")
		self.GuildDB.version = 2
		for i = 1, #self.GuildDB.roster do
			local info = self.GuildDB.roster[i]
			info[Field.SoR] = info[Field.Points]
			info[Field.Points] = nil
		end
		for i = 1, #self.GuildDB.changes do
			local change = self.GuildDB.changes[i]
			if change.type == State.PointsChange then 
				change.type = State.NameChange -- 12 -> 13
			elseif change.type == State.LevelChange then
				change.type = State.OfficerNoteChange -- 11 -> 9
			elseif change.type == State.OfficerNoteChange then
				change.type = State.LevelChange -- 9 -> 11
			end
			if change.oldinfo then
				change.oldinfo[Field.SoR] = change.oldinfo[Field.Points]
				change.oldinfo[Field.Points] = nil
			end
			if change.newinfo then
				change.newinfo[Field.SoR] = change.newinfo[Field.Points]
				change.newinfo[Field.Points] = nil
			end
		end
	end
	
	if self.GuildDB.version == 2 then
		self:Debug("Upgrading database to version 3")
		self.GuildDB.version = 3
		for i = 1, #self.GuildDB.roster do
			local info = self.GuildDB.roster[i]
			info[Field.Name] = sanitizeName(info[Field.Name])
		end
	end

	if self.GuildDB.version == 3 then
		self:Debug("Upgrading database to version 4")
		self.GuildDB.version = 4
		local homeRealm = GetRealmName()

		local function FixName(name)
			if strfind(name, "-") == nil then
				return name .. "-" .. homeRealm
			end
			return name
		end

		for i = 1, #self.GuildDB.roster do
			local info = self.GuildDB.roster[i]
			info[Field.Name] = FixName(info[Field.Name])
		end
		for i = 1, #self.GuildDB.changes do
			local change = self.GuildDB.changes[i]
			if (change.oldinfo[Field.Name]) then
				change.oldinfo[Field.Name] = FixName(change.oldinfo[Field.Name])
			end
			if (change.newinfo[Field.Name]) then
				change.newinfo[Field.Name] = FixName(change.newinfo[Field.Name])
			end
		end
	end
end

--------------------------------------------------------------------------------
function GuildTracker:UpdateGuildRoster()
--------------------------------------------------------------------------------
	local numGuildMembers = GetNumGuildMembers()
	local name, rank, rankIndex, level, class, zone, note, officernote, online, status, classconst, achievementPoints, achievementRank, isMobile, canSoR, repStanding
	local hours, days, months, years, lastOnline
	
	local players = recycleplayertable(self.GuildRoster)
	twipe(GuildRoster_reverse)
	
	self:Debug(string.format("Scanning %d guild members", numGuildMembers))
	
	for i = 1, numGuildMembers, 1 do
		name, rank, rankIndex, level, class, zone, note, officernote, online, status, classconst, achievementPoints, achievementRank, isMobile, canSoR, repStanding = GetGuildRosterInfo(i)

		-- During initial load some character names may only load partially
		if name == nil or strfind(name, "-") == nil then
			self:Debug("Found incomplete name: " .. (name or "nil"))
			return
		end

		years, months, days, hours = GetGuildRosterLastOnline(i)
		lastOnline = (online or not years) and 0 or (years * 365 + months * 30.417 + days + hours/24)
		
		tinsert(players, getplayertable(name, rankIndex, classconst, level, note, officernote, lastOnline, achievementPoints, canSoR, repStanding))
		
		-- Keep our reverse lookup table in sync
		GuildRoster_reverse[name] = #players
	end
	
	self.GuildRoster = players
end

--------------------------------------------------------------------------------
function GuildTracker:UpdateGuildChanges()
--------------------------------------------------------------------------------
	-- We don't know what guild we're updating yet
	if self.GuildDB == nil then
		return
	end
	
	-- Fail-safe when the roster returned 0 guild members; this can't be right so ignore
	if #self.GuildRoster == 0 then
		return
	end
	
	local oldRoster = self.GuildDB.roster
	
	-- If there's no saved roster data available, we can't determine any changes yet
	-- This happens when the first time we scan a guild 
	if oldRoster == nil or #oldRoster == 0 then
		return
	end
	
	self:Debug("Detecting guild changes")

	-- Sync our name lookup table
	self:FixReverseTable(oldRoster, SavedRoster_reverse)
	
	-- First update the existing entries of our SavedRoster
	for i = 1, #oldRoster do
		local info = oldRoster[i]
		local newPlayerInfo = self:FindPlayerByName(self.GuildRoster, info[Field.Name], GuildRoster_reverse)
		
		if newPlayerInfo == nil then
			self:AddGuildChange(State.GuildLeave, info, nil)
		else
			-- Rank
			if newPlayerInfo[Field.Rank] < info[Field.Rank] then
				self:AddGuildChange(State.RankUp, info, newPlayerInfo)
			elseif newPlayerInfo[Field.Rank] > info[Field.Rank] then
				self:AddGuildChange(State.RankDown, info, newPlayerInfo)
			end
			
			-- Scroll of resurrection
			if newPlayerInfo[Field.SoR] and not info[Field.SoR] then
				self:AddGuildChange(State.AccountDisabled, info, newPlayerInfo)
			elseif not newPlayerInfo[Field.SoR] and info[Field.SoR] then
				self:AddGuildChange(State.AccountEnabled, info, newPlayerInfo)
			end
			
			-- Activity
			if newPlayerInfo[Field.LastOnline] >= self.db.profile.options.inactive and info[Field.LastOnline] < self.db.profile.options.inactive then				
				self:AddGuildChange(State.Inactive, info, newPlayerInfo)
			elseif newPlayerInfo[Field.LastOnline] < self.db.profile.options.inactive and info[Field.LastOnline] >= self.db.profile.options.inactive then				
				self:AddGuildChange(State.Active, info, newPlayerInfo)
			end
			
			-- Level
			if newPlayerInfo[Field.Level] ~= info[Field.Level] and newPlayerInfo[Field.Level] >= self.db.profile.options.minlevel then
				self:AddGuildChange(State.LevelChange, info, newPlayerInfo)
			end
			
			-- Achievement Points
			if newPlayerInfo[Field.Points] ~= 0 and info[Field.Points] and newPlayerInfo[Field.Points] ~= info[Field.Points] and newPlayerInfo[Field.Level] >= self.db.profile.options.minlevel then
				self:AddGuildChange(State.PointsChange, info, newPlayerInfo)
			end

			-- Note
			if newPlayerInfo[Field.Note] ~= info[Field.Note] then
				self:AddGuildChange(State.NoteChange, info, newPlayerInfo)
			end
			
			-- Officer note
			if newPlayerInfo[Field.OfficerNote] ~= info[Field.OfficerNote] and self.GuildDB.isOfficer == C_GuildInfo:CanViewOfficerNote() then
				 self:AddGuildChange(State.OfficerNoteChange, info, newPlayerInfo)
			end
			
			if info[Field.RepStanding] and newPlayerInfo[Field.RepStanding] ~= info[Field.RepStanding] then
				self:AddGuildChange(State.RepChange, info, newPlayerInfo)
			end
		end
	end
	
	-- Then add any new entries
	for i = 1, #self.GuildRoster do
		local info = self.GuildRoster[i]
		local oldPlayerInfo = self:FindPlayerByName(oldRoster, info[Field.Name], SavedRoster_reverse)
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
	
	local pointDiff = infoJoin[Field.Points] - infoQuit[Field.Points]

	return changeJoin.timestamp == changeQuit.timestamp
		and infoJoin[Field.Class] == infoQuit[Field.Class]
		and infoJoin[Field.Rank] == infoQuit[Field.Rank]
		and infoJoin[Field.Level] == infoQuit[Field.Level]
		and infoJoin[Field.Note] == infoQuit[Field.Note]
		and infoJoin[Field.RepStanding] == infoQuit[Field.RepStanding]
		and pointDiff >= 0 and pointDiff < 100 -- arbitrary range that we'll consider the same character
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
function GuildTracker:MergeChanges()
--------------------------------------------------------------------------------
	if self.db.profile.options.tooltip.merging then
		self:MergeStateChanges(State.LevelChange)
		self:MergeStateChanges(State.PointsChange)
		self:MergeStateChanges(State.NoteChange)
		self:MergeStateChanges(State.OfficerNoteChange)
		self:MergeStateChanges(State.Active)
		self:MergeStateChanges(State.AccountEnabled)
		--self:MergeStateChanges(State.GuildJoin)
		self:MergeStateChanges(State.RankUp)
		self:MergeStateChanges(State.NameChange)
		
		self:SortAndGroupChanges()
	end
end

--------------------------------------------------------------------------------
function GuildTracker:MergeStateChanges(state)
--------------------------------------------------------------------------------
	local comboState = ComboState[state]
	
	local changes = self.GuildDB.changes
	if changes and #changes > 0 then
		for cIdx = 1, #changes do
			local change = changes[cIdx]
			if change.type == state or change.type == comboState then
				for cIdx2 = 1, #changes do
					if cIdx2 ~= cIdx then
						local change2 = changes[cIdx2]

						local isMatchByName = change.newinfo and change.newinfo[Field.Name] == change2.newinfo[Field.Name]
						if change.type == State.NameChange then
							isMatchByName = change.newinfo and change.newinfo[Field.Name] == change2.oldinfo[Field.Name]
						end

						if (change2.type == state or change2.type == comboState) and isMatchByName then
							self:Debug("Merging changes of type " .. state .. ": " .. cIdx .. "/" .. cIdx2)
							-- We found two changes of the same (or combo) type and the same name
							local first, last = change, change2
							if first.timestamp > last.timestamp then
								first, last = change2, change
							end
							first.newinfo = tcopy(last.newinfo)
							first.timestamp = last.timestamp
							
							if state == State.RankUp or state == State.RankDown then
								-- In this case we need to determine the net result
								local newrank = first.newinfo[Field.Rank]
								local oldrank = first.oldinfo[Field.Rank]
								if newrank == oldrank then
									self:Debug("Rank change cancelled")
									first.type = State.Unchanged
								else
									self:Debug("Rank change merged")
									first.type = (newrank < oldrank) and State.RankUp or State.RankDown
								end
							elseif state == State.NoteChange or state == State.OfficerNoteChange then
								-- In this case we need to determine the net result
								local newnote = (state == State.NoteChange) and first.newinfo[Field.Note] or first.newinfo[Field.OfficerNote]
								local oldnote = (state == State.NoteChange) and first.oldinfo[Field.Note] or first.oldinfo[Field.OfficerNote]
								if newnote == oldnote then
									self:Debug("Note change cancelled")
									first.type = State.Unchanged
								else
									self:Debug("Note change merged")
								end
							elseif state == State.NameChange then
								-- In this case we need to determine the net result
								local newname = first.newinfo[Field.Name]
								local oldname = first.oldinfo[Field.Name]
								if newname == oldname then
									self:Debug("Name change cancelled")
									first.type = State.Unchanged
								else
									self:Debug("Name change merged")
								end
							elseif state == State.AccountDisabled or state == State.AccountEnabled 
								or state == State.GuildLeave or state == State.GuildJoin
								or state == State.Inactive or state == State.Active then
								-- These types cancel each other out
								first.type = State.Unchanged
								self:Debug("Change cancelled")
							else
								-- Level, Points are simple
								self:Debug("Change merged")
							end
							
							last.type = State.Unchanged
						end
					end
				end --for
			end
		end --for
	end
end
	
--------------------------------------------------------------------------------
function GuildTracker:GetAlertMessage(change, msgFormat, makelink)
--------------------------------------------------------------------------------
	local state = change.type
	local info = (state == State.GuildLeave or state == State.NameChange) and change.oldinfo or change.newinfo
	local name = sanitizeName(info[Field.Name])
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
		
		local newPlayerInfo = self:FindPlayerByName(self.GuildRoster, info[Field.Name], GuildRoster_reverse)	
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
	
	self:FixReverseTable(self.GuildDB.roster, SavedRoster_reverse)
	
	-- Add any new roster entries
	for idx = 1, #self.GuildRoster do
		local info = self.GuildRoster[idx]
		local oldPlayerInfo = self:FindPlayerByName(self.GuildDB.roster, info[Field.Name], SavedRoster_reverse)
		if oldPlayerInfo == nil then
			added = added + 1
			local newInfo = tcopy(info)
			tinsert(self.GuildDB.roster, newInfo)
		end
	end
	
	self.GuildDB.updated = self.LastRosterUpdate
	self.GuildDB.isOfficer = C_GuildInfo:CanViewOfficerNote()
	
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
			PlaySound(18871) -- AlarmClockWarning1
		end
	end
end

--------------------------------------------------------------------------------
function GuildTracker:FindPlayerByName(list, name, lookuplist)
--------------------------------------------------------------------------------
	if lookuplist then
		local idx = lookuplist[name]
		if idx then
			return list[idx]
		end
	else
		for i = 1, #list do
			local info = list[i]
			if info[Field.Name] == name then
				return info
			end
		end
	end
	return nil
end

--------------------------------------------------------------------------------	
function GuildTracker:FixReverseTable(inputtable, reversetable)
--------------------------------------------------------------------------------	
	twipe(reversetable)
	for i = 1, #inputtable do
		local info = inputtable[i]
		reversetable[info[Field.Name]] = i
	end
	return reversetable
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
function GuildTracker:AutoExpireChanges()
--------------------------------------------------------------------------------
	self:Debug("Checking for expired changes")
	if self.db.profile.options.autoexpire then
		local foundExpired = false
		local expiretime = time() - self.db.profile.options.expiretime * 3600
		if self.GuildDB ~= nil then
			-- Remove 'expired' entries
			local lastUsedIdx = 1
			for i = 1, #self.GuildDB.changes do
				self.GuildDB.changes[lastUsedIdx] = self.GuildDB.changes[i]
				if self.GuildDB.changes[i].timestamp > expiretime then
					-- Do not expire this item yet
					lastUsedIdx = lastUsedIdx + 1
				else
					foundExpired = true
				end
			end
			for i = lastUsedIdx, #self.GuildDB.changes do
				self.GuildDB.changes[i] = nil
			end
		end
		if foundExpired then
			self:SortAndGroupChanges()
		end
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
	
	local msg = string.format("%s (%d %s) %s", sanitizeName(item[Field.Name]), item[Field.Level], toproper(item[Field.Class]), changeText)
	
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
					 (chat ~= "INSTANCE_CHAT" or IsInInstance()) and
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
		local noteField, note = Field.Note
		if self.GuildDB.isOfficer and self.db.profile.options.alerts.preferofficernote then
			noteField = Field.OfficerNote
		end
		note = ((state == State.GuildJoin) and change.newinfo[noteField] or change.oldinfo[noteField]) or ""
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
		template = string.format(template, level, diff)
	elseif state == State.NoteChange then
		local oldNote = change.oldinfo[Field.Note]
		local newNote = change.newinfo[Field.Note]
		template = string.format(template, oldNote, newNote)
	elseif state == State.NameChange then
		local oldName = change.oldinfo[Field.Name]
		local newName = change.newinfo[Field.Name]
		template = string.format(template, newName)
	elseif state == State.OfficerNoteChange then
		local oldNote = change.oldinfo[Field.OfficerNote]
		local newNote = change.newinfo[Field.OfficerNote]
		template = string.format(template, oldNote, newNote)
	elseif state == State.PointsChange then
		local points = change.newinfo[Field.Points]
		local diff = points - change.oldinfo[Field.Points]
		template = string.format(template, points, diff)
	elseif state == State.RepChange then
		local newStandingId = change.newinfo[Field.RepStanding]
		template = string.format(template, getglobal("FACTION_STANDING_LABEL"..newStandingId))
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
	local columns = 11
	local lineNum, colNum
	
	tooltip:Clear()

	local lineNum, colNum
	tooltip:SetColumnLayout(columns, "LEFT", "LEFT", "LEFT", "CENTER", "RIGHT", "LEFT", "CENTER", "LEFT", "RIGHT", "LEFT", "LEFT")
	
	lineNum = tooltip:AddHeader()
	tooltip:SetCell(lineNum, 1, "|cfffed100Guild Tracker", tooltip:GetHeaderFont(), "CENTER", tooltip:GetColumnCount())
	lineNum = tooltip:AddLine(" ")

	lineNum = tooltip:AddLine()

	if self.GuildDB == nil then
		self:AddMessageToTooltip("You are not in a guild", tooltip, 1)
		return
	end
	
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
	lineNum, colNum = tooltip:SetCell(lineNum, colNum, "|cffffd200".."Points", nil, "RIGHT", nil, nil, 0, padding, nil, 38)
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

	tooltip:SetCellScript(lineNum, 5, "OnMouseUp", OnSortHeader, "Points")
	tooltip:SetCellScript(lineNum, 5, "OnEnter", ShowSimpleTooltip, "Sort by Points")
	tooltip:SetCellScript(lineNum, 5, "OnLeave", HideSimpleTooltip)

	tooltip:SetCellScript(lineNum, 6, "OnMouseUp", OnSortHeader, "Rank")
	tooltip:SetCellScript(lineNum, 6, "OnEnter", ShowSimpleTooltip, "Sort by Rank")
	tooltip:SetCellScript(lineNum, 6, "OnLeave", HideSimpleTooltip)
	
	tooltip:SetCellScript(lineNum, 7, "OnMouseUp", OnSortHeader, "Offline")
	tooltip:SetCellScript(lineNum, 7, "OnEnter", ShowSimpleTooltip, "Sort by last online time")
	tooltip:SetCellScript(lineNum, 7, "OnLeave", HideSimpleTooltip)
	
	tooltip:SetCellScript(lineNum, 9, "OnMouseUp", OnSortHeader, "Timestamp")
	tooltip:SetCellScript(lineNum, 9, "OnEnter", ShowSimpleTooltip, "Sort by Timestamp")
	tooltip:SetCellScript(lineNum, 9, "OnLeave", HideSimpleTooltip)
	
	
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
							if lineNum >= CHANGE_LIMIT then
							  break
							end
						end
					end
					
				end
				
				tooltip:SetCell(headerLineNum, 1, string.format(ICON_TOGGLE, (not self.db.profile.options.tooltip.panel[stateidx]) and "Plus" or "Minus"), "LEFT")
				tooltip:SetLineScript(headerLineNum, "OnMouseDown", OnToggleButton, stateidx)
			end
			
			if lineNum >= CHANGE_LIMIT then
			  break
			end
		end
		
	else
	
		for idx,change in ipairs(self.GuildDB.changes) do
			lineNum = self:AddChangeItemToTooltip(change, tooltip, idx)
			
			if lineNum >= CHANGE_LIMIT then
			  break
			end
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

	local noteField = Field.Note
	if changeType == State.OfficerNoteChange or (changeType ~= State.NoteChange and self.GuildDB.isOfficer and self.db.profile.options.alerts.preferofficernote) then
		noteField = Field.OfficerNote
	end

	local clrChange, txtChange = self:GetStateText(changeType)
	local txtName = RAID_CLASS_COLORS_hex[item[Field.Class]] .. sanitizeName(item[Field.Name])
	local txtLevel = item[Field.Level]
	local txtPoints = item[Field.Points] or ""
	local txtRank = GuildControlGetRankName(item[Field.Rank]+1)
	local txtNote = item[noteField]
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
	local oldPoints = nil
	
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
		if oldNote == "" then
			oldNote = CLR_GRAY .. "(empty)"
		end
		if txtNote == "" then
			txtNote = CLR_DARKYELLOW .. "(empty)"
		else
			txtNote = CLR_YELLOW .. txtNote
		end
	elseif changeType == State.OfficerNoteChange then
		oldNote = changeItem.oldinfo[Field.OfficerNote]
		if oldNote == "" then
			oldNote = CLR_GRAY .. "(empty)"
		end
		if txtNote == "" then
			txtNote = CLR_DARKYELLOW .. "(empty)"
		else
			txtNote = CLR_YELLOW .. txtNote
		end
	elseif changeType == State.NameChange then
		oldName = sanitizeName(changeItem.oldinfo[Field.Name])
	elseif changeType == State.PointsChange then
		if changeItem.oldinfo[Field.Points] then
			oldPoints = changeItem.oldinfo[Field.Points] .. string.format(CLR_GRAY .. " (%s%d)", (item[Field.Points] > changeItem.oldinfo[Field.Points]) and "+" or "-", math.abs(item[Field.Points] - changeItem.oldinfo[Field.Points]))
			txtPoints = CLR_YELLOW .. txtPoints
		end
	end
	
	if txtNote == "" then
		txtNote = CLR_GRAY .. "(empty)"
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
	lineNum, colNum = tooltip:SetCell(lineNum, colNum, txtPoints)
	if oldPoints then
		tooltip:SetCellScript(lineNum, colNum-1, "OnEnter", ShowSimpleTooltip, {"Previous points:", oldPoints})
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
		local caption = (changeType == State.OfficerNoteChange) and "Previous officer note: " or "Previous note: "
		tooltip:SetCellScript(lineNum, colNum-1, "OnEnter", ShowSimpleTooltip, {caption, oldNote})
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
	
	local testitem1 = self:FindPlayerByName(self.GuildRoster, "Crossbow-Aggramar")
	testitem1[Field.Rank] = 8
	
	local testitem2 = self:FindPlayerByName(self.GuildRoster, "Boozie-Aggramar")
	testitem2[Field.LastOnline] = 65

	local testitem3 = self:FindPlayerByName(self.GuildRoster, "Exodeo-ArgentDawn")
	testitem3[Field.Level] = 15

	local testitem4 = self:FindPlayerByName(self.GuildRoster, "Atuad-Aggramar")
	testitem4[Field.Note] = "Test note"
	
	local testitem5 = self:FindPlayerByName(self.GuildRoster, "Ironica-Aggramar")
	testitem5[Field.Name] = "Orinaci"
	
	--tremove(self.GuildRoster, 1)
	
	self:UpdateGuildChanges()
	self:SaveGuildRoster()
	self:ReportNewChanges()
	self:AutoExpireChanges()
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
				scanincombat = false,
				autoexpire = false,
				expiretime = 3,
				inactive = 30,
				minlevel = 20,
				timeformat = 2,
				minimap = {
					hide = true,
					addoncompartment = false,
				},
				alerts = {
					sound = true,
					chatmessage = true,
					preferofficernote = false,
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
					[12] = true,
					[13] = true,
					[14] = false,
				},				
				tooltip = {
					merging = false,
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
				 	autorefresh = {
						name = CLR_YELLOW .. "Auto-refresh roster",
						desc = "Periodically scan guild roster for faster updates",
						descStyle = "inline",
						type = "toggle",
						width = "full",						
						order = 1,
						get = function(key) return self.db.profile.options.autorefresh	end,
						set = function(key, value)
							self.db.profile.options.autorefresh = value
							self:PLAYER_GUILD_UPDATE()
						end,
				 	},
				 	scanincombat = {
						name = CLR_YELLOW .. "Allow scanning during combat",
						desc = "Guild roster change detection will continue even while in combat",
						descStyle = "inline",
						type = "toggle",
						width = "full",						
						order = 2,
						get = function(key) return self.db.profile.options.scanincombat	end,
						set = function(key, value) self.db.profile.options.scanincombat = value end,
				 	},				 	
					minimap = {
						name = CLR_YELLOW .. "Minimap icon",
						desc = "Display a separate minimap icon",
						descStyle = "inline",
						type = "toggle",
						width = "full",
						order = 3,
						get = function(key) return not self.db.profile.options.minimap.hide end,
						set = function(key, value)
							self.db.profile.options.minimap.hide = not value
							self:UpdateMinimapIcon()
						end,
					},
					addoncompartment = {
						name = CLR_YELLOW .. "Register with addon compartment",
						desc = "Display icon in the minimap addon compartment (requires reload)",
						descStyle = "inline",
						type = "toggle",
						width = "full",
						order = 4,
						get = function(key) return self.db.profile.options.minimap.addoncompartment end,
						set = function(key, value)
							self.db.profile.options.minimap.addoncompartment = value
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
						order = 7,
						values = function() return self:GetTableValues(TimeFormat) end,
						get = function(key) return self.db.profile.options.timeformat end,
						set = function(key, value) self.db.profile.options.timeformat = value end,
					},
					historygroup = {
						name = "History",
						desc = "Control the history list of changes",
						type = "group",
						order = 2,
						args = {
							grouping = {
								name = CLR_YELLOW .. "Group changes by type",
								desc = "Create collapsible group panels in the history list",
								descStyle = "inline",
								type = "toggle",
								width = "full",
								order = 1,
								get = function(key) return self.db.profile.options.tooltip.grouping end,
								set = function(key, value) self.db.profile.options.tooltip.grouping = value end,
							},					
							merging = {
								name = CLR_YELLOW .. "Merge similar changes",
								desc = "Merge multiple changes of the same type into a single entry",
								descStyle = "inline",
								type = "toggle",
								width = "full",
								order = 1,
								get = function(key) return self.db.profile.options.tooltip.merging end,
								set = function(key, value) self.db.profile.options.tooltip.merging = value end,							
							},
							autoreset = {
								name = CLR_YELLOW .. "Auto-clear each session",
								desc = "Automatically clear all changes on logout or UI reload",
								descStyle = "inline",
								type = "toggle",
								width = "full",						
								order = 2,
								get = function(key) return self.db.profile.options.autoreset end,
								set = function(key, value) self.db.profile.options.autoreset = value end,
							},
							autoexpire = {
								name = CLR_YELLOW .. "Auto-expire by time",
								desc = "Automatically remove changes older than the configured threshold",
								descStyle = "inline",
								type = "toggle",
								width = "full",
								order = 3,
								get = function(key) return self.db.profile.options.autoexpire end,
								set = function(key, value) self.db.profile.options.autoexpire = value end,
							},
							expiretime = {
								name = function()
									return (self.db.profile.output.autoexpire and CLR_YELLOW or "").. "Expire threshold (hours)"
								end,
								desc = "Set the number of hours before detected changes will expire",
								disabled = function() return not self.db.profile.options.autoexpire end,
								type = "range",
								order = 4,
								min = 0,
								softMax = 72,
								step = 1,
								bigStep = 1,
								get = function(key) return self.db.profile.options.expiretime end,
								set = function(key, value) self.db.profile.options.expiretime = value end,
							},
						},
					},
					filtergroup = {
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
							minlevel = {
								name = "Minimum level",
								desc = "Set the minimum level to report changes in level or achievement points",
								type = "range",
								order = 22,
								min = 0,
								max = GetMaxPlayerLevel(),
								step = 1,
								bigStep = 5,
								get = function(key) return self.db.profile.options.minlevel end,
								set = function(key, value) self.db.profile.options.minlevel = value end,
							},
						},
					},
					alertsgroup = {
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
							preferofficernote = {
								name = function()
									return (C_GuildInfo:CanViewOfficerNote() and CLR_YELLOW or "").. "Prefer officer notes"
								end,							
								desc = "By default, display officer notes instead of public notes",
								descStyle = "inline",
								disabled = function() return not C_GuildInfo:CanViewOfficerNote() end,
								type = "toggle",
								width = "full",
								order = 3,
								get = function(key) return self.db.profile.options.alerts.preferofficernote end,
								set = function(key, value) self.db.profile.options.alerts.preferofficernote = value end,
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
								order = 4,
								values = function() return self:GetTableValues(ChatFormat) end,
								get = function(key) return self.db.profile.options.alerts.messageformat end,
								set = function(key, value) self.db.profile.options.alerts.messageformat = value end,
							},
						
						}
					},
					outputgroup = {
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
	for i = 1, table.getn(channels), 3 do
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

function GuildTracker:RegisterAddonCompartment()
	if self.db.profile.options.minimap.addoncompartment then
		AddonCompartmentFrame:RegisterAddon({
			text = "Guild Tracker",
			icon = [[Interface\Addons\GuildTracker\GuildTracker]],
			registerForAnyClick = true,
			notCheckable = true,
			func = function(button, inputData, menuItem)
				do_OnClick(menuItem, inputData.buttonName)
			end,
			funcOnEnter = do_OnEnter,
			funcOnLeave = do_OnLeave,
		})
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
			self.options.args.options.args.filtergroup.args[tostring(v)] = self:GenerateStateOption(v)
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
