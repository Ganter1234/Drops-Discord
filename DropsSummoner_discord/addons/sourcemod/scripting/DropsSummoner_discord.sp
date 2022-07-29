#include <sdktools>
#include <dhooks>
#include <discord_extended>
#include <ripext>

#undef REQUIRE_EXTENSIONS
#tryinclude <SteamWorks>
#define REQUIRE_EXTENSIONS
#define STEAMWORKS_ON() (CanTestFeatures() && GetFeatureStatus(FeatureType_Native, "SteamWorks_HasLicenseForApp") == FeatureStatus_Available) // Thanks CYBERC4T

public Plugin myinfo =
{
	name = "Призыватель дропа",
	author = "Phoenix (˙·٠●Феникс●٠·˙) + Ganter1234",
	version = "1.2.0 final"
};

#pragma tabsize 0

KeyValues g_hKvConfig;
Handle g_hRewardMatchEndDrops = null;
Handle g_hTimerWaitDrops = null;
char g_sLogFile[256];
char g_sApiKey[54];
int g_iOS = -1;
Address g_pDropForAllPlayersPatch = Address_Null;
ConVar g_hDSApiKey = null;
ConVar g_hDSKick = null;
ConVar g_hDSWaitTimer = null;
ConVar g_hDSInfo = null;
ConVar g_hDSPlaySound = null;
ConVar g_hDSCurrency = null;
ConVar g_hDSViewCase = null;
ConVar g_hDSPrime = null;

public void OnPluginStart()
{
	GameData hGameData = LoadGameConfigFile("DropsSummoner.games");
	
	if (!hGameData)
	{
		SetFailState("Failed to load DropsSummoner gamedata.");
		
		return;
	}
	
	g_iOS = hGameData.GetOffset("OS");
	
	if(g_iOS == -1)
	{
		SetFailState("Failed to get OS offset");
		
		return;
	}
	
	if(g_iOS == 1)
	{
		StartPrepSDKCall(SDKCall_Raw);
	}
	else
	{
		StartPrepSDKCall(SDKCall_Static);
	}
	
	PrepSDKCall_SetFromConf(hGameData, SDKConf_Signature, "CCSGameRules::RewardMatchEndDrops");
	PrepSDKCall_AddParameter(SDKType_Bool, SDKPass_Plain);
	
	if (!(g_hRewardMatchEndDrops = EndPrepSDKCall()))
	{
		SetFailState("Failed to create SDKCall for CCSGameRules::RewardMatchEndDrops");
		
		return;
	}
	
	DynamicDetour hCCSGameRules_RecordPlayerItemDrop = DynamicDetour.FromConf(hGameData, "CCSGameRules::RecordPlayerItemDrop");
	
	if (!hCCSGameRules_RecordPlayerItemDrop)
	{
		SetFailState("Failed to setup detour for CCSGameRules::RecordPlayerItemDrop");
		
		return;
	}
	
	if(!hCCSGameRules_RecordPlayerItemDrop.Enable(Hook_Post, Detour_RecordPlayerItemDrop))
	{
		SetFailState("Failed to detour CCSGameRules::RecordPlayerItemDrop.");
		
		return;
	}
	
	g_pDropForAllPlayersPatch = hGameData.GetAddress("DropForAllPlayersPatch");
	
	if(g_pDropForAllPlayersPatch != Address_Null)
	{
		// 83 F8 01 ?? [cmp eax, 1]
		if((LoadFromAddress(g_pDropForAllPlayersPatch, NumberType_Int32) & 0xFFFFFF) == 0x1F883)
		{
			g_pDropForAllPlayersPatch += view_as<Address>(2);
			
			StoreToAddress(g_pDropForAllPlayersPatch, 0xFF, NumberType_Int8);
		}
		else
		{
			g_pDropForAllPlayersPatch = Address_Null;
			
			LogError("At address g_pDropForAllPlayersPatch received not what we expected, drop for all players will be unavailable.");
		}
	}
	else
	{
		LogError("Failed to get address DropForAllPlayersPatch, drop for all players will be unavailable.");
	}
	
	delete hGameData;
	
	BuildPath(Path_SM, g_sLogFile, sizeof g_sLogFile, "logs/DropsSummoner.log");
	
	g_hDSApiKey = CreateConVar("sm_drops_apikey", "", "API ключ стима (https://steamcommunity.com/dev/apikey)");
	g_hDSKick = CreateConVar("sm_drops_kick", "0", "Кикать игрока после получения кейса? (Для IDLE)", _, true, 0.0, true, 1.0);
	g_hDSWaitTimer = CreateConVar("sm_drops_summoner_wait_timer", "182", "Длительность между попытками призвать дроп в секундах", _, true, 60.0);
	g_hDSCurrency = CreateConVar("sm_drops_currency", "5", "Валюта которая будет выводиться в сообщении, https://partner.steamgames.com/doc/store/pricing/currencies");
	g_hDSInfo = CreateConVar("sm_drops_summoner_info", "1", "Уведомлять в чате о попытках призыва дропа", _, true, 0.0, true, 1.0);
	g_hDSViewCase = CreateConVar("sm_drops_viewcase", "1", "Показывать ли в Center Text картинку кейса?", _, true, 0.0, true, 1.0);
	g_hDSPlaySound = CreateConVar("sm_drops_summoner_play_sound", "2", "Воспроизводить звук при получении дропа [0 - нет | 1 - только получившему | 2 - всем]", _, true, 0.0, true, 2.0);
	g_hDSPrime = CreateConVar("sm_drops_prime", "1", "Не показывать инфу о получении кейса если игрок без прайма?", _, true, 0.0, true, 1.0);

	AutoExecConfig(true, "drops_summoner");

	RegAdminCmd("sm_drops_test", TestMessage, ADMFLAG_ROOT);
}

public Action TestMessage(int client, int args)
{
	if(!client)
	{
		PrintToServer("Не прокатит бро, зайди на сервер и пропиши команду там)");
		return Plugin_Handled;
	}

	g_hKvConfig.Rewind();
	if(g_hKvConfig.JumpToKey("4001"))
	{
		char cPlayerID[82], sBuffer[128];
		GetClientAuthId(client, AuthId_SteamID64, cPlayerID, sizeof(cPlayerID));
		StripQuotes(cPlayerID);
		g_hKvConfig.GetString("case_name_market", sBuffer, sizeof(sBuffer));

		DataPack hPack = new DataPack();
		hPack.WriteCell(client);
		hPack.WriteString("4001");
		hPack.WriteString(sBuffer);
		char sRequest[1024];
		FormatEx(sRequest, sizeof(sRequest), "http://api.steampowered.com/ISteamUser/GetPlayerSummaries/v0002?key=%s&steamids=%s", g_sApiKey, cPlayerID);
		HTTPRequest httpClient = new HTTPRequest(sRequest);
		httpClient.Get(OnTodoReceived, hPack);

		PrintToChat(client, "[DS] Тестовое оповещение отправлено!");
	}
	else
	{
		PrintToChat(client, "[DS] Тестовое оповещение не удалось отправить, не удалось найти кейс с айди 4001 в конфиге :(");
		LogError("There is no case in the config :O (INDEX: 4001)");
	}

	return Plugin_Handled;
}

public void OnPluginEnd()
{
	if(g_pDropForAllPlayersPatch != Address_Null)
	{
		StoreToAddress(g_pDropForAllPlayersPatch, 0x01, NumberType_Int8);
	}
}

public void OnConfigsExecuted()
{
	GetConVarString(g_hDSApiKey, g_sApiKey, sizeof(g_sApiKey));
	if(!g_sApiKey[0])
		SetFailState("Введите Steam Web API ключ! https://steamcommunity.com/dev/apikey (\"sm_drops_apikey\")");
	StripQuotes(g_sApiKey);
}

public void OnMapStart()
{
	PrecacheSound("ui/panorama/case_awarded_1_uncommon_01.wav");
	CreateTimer(g_hDSWaitTimer.FloatValue, Timer_SendRewardMatchEndDrops, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
	LoadConfig();
}

void LoadConfig()
{
	char sBuffer[PLATFORM_MAX_PATH];
	g_hKvConfig = new KeyValues("Drops_Discord");
	FormatEx(sBuffer, sizeof(sBuffer), "addons/sourcemod/configs/dropssummoner_discord.ini");
	if(!g_hKvConfig.ImportFromFile(sBuffer)) SetFailState("Не найден конфиг: %s", sBuffer);
}

MRESReturn Detour_RecordPlayerItemDrop(DHookParam hParams)
{
	if(g_hTimerWaitDrops)
	{
		delete g_hTimerWaitDrops;
	}
	
	int iAccountID = hParams.GetObjectVar(1, 16, ObjectValueType_Int);
	int iClient = GetClientFromAccountID(iAccountID);
	
	if(iClient != -1 && CF_CheckPrime(iClient) == 2)
	{	
		int iDefIndex = hParams.GetObjectVar(1, 20, ObjectValueType_Int);
		int iPaintIndex = hParams.GetObjectVar(1, 24, ObjectValueType_Int);
		int iRarity = hParams.GetObjectVar(1, 28, ObjectValueType_Int);
		int iQuality = hParams.GetObjectVar(1, 32, ObjectValueType_Int);

		char sDefIndex[8]
		FormatEx(sDefIndex, sizeof(sDefIndex), "%i", iDefIndex);
		g_hKvConfig.Rewind();
		if(g_hKvConfig.JumpToKey(sDefIndex))
		{
			char cPlayerID[82], sBuffer[128];
			GetClientAuthId(iClient, AuthId_SteamID64, cPlayerID, sizeof(cPlayerID));
			StripQuotes(cPlayerID);
			g_hKvConfig.GetString("case_name_market", sBuffer, sizeof(sBuffer));

			DataPack hPack = new DataPack();
			hPack.WriteCell(iClient);
			hPack.WriteString(sDefIndex);
			hPack.WriteString(sBuffer);

			char sRequest[1024];
			FormatEx(sRequest, sizeof(sRequest), "http://api.steampowered.com/ISteamUser/GetPlayerSummaries/v0002?key=%s&steamids=%s", g_sApiKey, cPlayerID);
			HTTPRequest httpClient = new HTTPRequest(sRequest);
			httpClient.Get(OnTodoReceived, hPack);
		}
		else LogError("There is no case in the config :O (INDEX: %i)", iDefIndex);

		LogToFile(g_sLogFile, "Игроку %L выпало [%u-%u-%u-%u]", iClient, iDefIndex, iPaintIndex, iRarity, iQuality);
			
		Protobuf hSendPlayerItemFound = view_as<Protobuf>(StartMessageAll("SendPlayerItemFound", USERMSG_RELIABLE));
		hSendPlayerItemFound.SetInt("entindex", iClient);
			
		Protobuf hIteminfo = hSendPlayerItemFound.ReadMessage("iteminfo");
		hIteminfo.SetInt("defindex", iDefIndex);
		hIteminfo.SetInt("paintindex", iPaintIndex);
		hIteminfo.SetInt("rarity", iRarity);
		hIteminfo.SetInt("quality", iQuality);
		hIteminfo.SetInt("inventory", 6); //UNACK_ITEM_GIFTED
			
		EndMessage();
			
		SetHudTextParams(-1.0, 0.4, 3.0, 0, 255, 255, 255);
		ShowHudText(iClient, -1, "Вам выпал дроп, смотрите свой инвентарь");
			
		int iPlaySound = g_hDSPlaySound.IntValue;
			
		if(iPlaySound == 2)
		{
			EmitSoundToAll("ui/panorama/case_awarded_1_uncommon_01.wav", SOUND_FROM_LOCAL_PLAYER, _, SNDLEVEL_NONE);
		}
		else if(iPlaySound == 1)
		{
			EmitSoundToClient(iClient, "ui/panorama/case_awarded_1_uncommon_01.wav", SOUND_FROM_LOCAL_PLAYER, _, SNDLEVEL_NONE);
		}
	}
	
	return MRES_Ignored;
}

public void OnTodoReceived(HTTPResponse response, DataPack hPack)
{
	hPack.Reset();
	int iClient = hPack.ReadCell();
	char sDefIndex[8];
	hPack.ReadString(sDefIndex, sizeof(sDefIndex));
	char sBuffer[128];
	hPack.ReadString(sBuffer, sizeof(sBuffer));
	StripQuotes(sBuffer);
	ReplaceString(sBuffer, sizeof(sBuffer), " ", "%20");
	delete hPack;

	if (response.Status != HTTPStatus_OK) 
	{
		if(response.Status == HTTPStatus_Forbidden)
			LogError("Avatar Error 403: looks like you entered the wrong API KEY :( [Your key: %s]", g_sApiKey);
		else
			LogError("Avatar Error %i: something went wrong :(", response.Status);
		return;
	}
	if (response.Data == null) 
	{
		LogError("Avatar JSON null :(");
		return;
	}

	JSONObject res = view_as<JSONObject>(response.Data);
	JSONObject resp = view_as<JSONObject>(res.Get("response"));
	JSONArray players = view_as<JSONArray>(resp.Get("players"));
	JSONObject data = view_as<JSONObject>(players.Get(0));
	
	char szAvatar[256];
	data.GetString("avatarmedium", szAvatar, sizeof(szAvatar));

	DataPack hdPack = new DataPack();
	hdPack.WriteCell(iClient);
	hdPack.WriteString(sDefIndex);
	hdPack.WriteString(szAvatar);

	char sRequest[1024];
	FormatEx(sRequest, sizeof(sRequest), "https://steamcommunity.com/market/priceoverview/?appid=730&currency=%d&market_hash_name=%s", g_hDSCurrency.IntValue, sBuffer);
	HTTPRequest httpPrice = new HTTPRequest(sRequest);
	httpPrice.Get(OnPriceReceived, hdPack);

	delete res;
	delete resp;
	delete players;
	delete data;
}

public void OnPriceReceived(HTTPResponse response, DataPack hdPack) // Thanks HenryTownshand
{
	hdPack.Reset();
	int iClient = hdPack.ReadCell();
	char sDefIndex[8];
	hdPack.ReadString(sDefIndex, sizeof(sDefIndex));
	char szAvatar[512];
	hdPack.ReadString(szAvatar, sizeof(szAvatar));
	char szPlayerName[50];
	FormatEx(szPlayerName, sizeof(szPlayerName), "%N", iClient);
	delete hdPack;

	if (response.Status != HTTPStatus_OK) 
	{
		if(response.Status == HTTPStatus_Forbidden)
			LogError("Price Error 403: looks like you entered the wrong API KEY :( [Your key: %s]", g_sApiKey);
		else
			LogError("Price Error %i: something went wrong :(", response.Status);
		return;
	}
	if (response.Data == null) 
	{
		LogError("Price JSON null :(");
		return;
	}

	JSONObject res = view_as<JSONObject>(response.Data);
	char sPrice[256];
	res.GetString("median_price", sPrice, sizeof(sPrice));
	discord_send_message(sDefIndex, szAvatar, szPlayerName, iClient, sPrice);
	delete res;
}

public void discord_send_message(char[] sDefIndex, char[] szAvatar, char[] szPlayerName, int client, char[] sPrice)
{
	if(Discord_WebHookExists("Drops_Cases"))
	{
		int Color[10];
		Color[0] = 0x000000;
		Color[1] = 0x00FF00;
		Color[2] = 0xFF0000;
		Color[3] = 0xFF8000;
		Color[4] = 0xFFFF00;
		Color[5] = 0x0000FF;
		Color[6] = 0xFF00FF;
		Color[7] = 0x0080FF;
		Color[8] = 0x00FFFF;
		Color[9] = 0xFFFFFF;

		int random = GetRandomInt(0, 9);
		Discord_StartMessage();
		Discord_SetUsername("Drop Cases");
		Discord_SetColor(Color[random]);
		Discord_SetAuthorName(szPlayerName);
		Discord_SetAuthorImage(szAvatar);

		char sField[256], sBuffer[1024];
		g_hKvConfig.Rewind();
		g_hKvConfig.GetString("Field_Text", sField, sizeof(sField));

		if(g_hKvConfig.JumpToKey(sDefIndex))
		{
			g_hKvConfig.GetString("case_name", sBuffer, sizeof(sBuffer));
			Discord_AddField(sField, sBuffer);
			//PrintToChatAll("%s %s", sField, sBuffer);
			Discord_AddField("Цена:", sPrice);
			//PrintToChatAll("Цена: %s", sPrice);

			g_hKvConfig.GetString("image_url", sBuffer, sizeof(sBuffer));
			if(g_hDSViewCase.BoolValue) PrintHintText(client, "<font><img src='%s'></font>", sBuffer);
			Discord_SetThumbnail(sBuffer);
			//PrintToChatAll("Image: %s", sBuffer);

			GetConVarString(FindConVar("hostname"), sBuffer, sizeof(sBuffer));
			Discord_SetFooterText(sBuffer);
			//PrintToChatAll("Footer: %s", sBuffer);
		}
		else LogError("There is no case in the config :O (INDEX: %s)", sDefIndex);

		Discord_EndMessage("Drops_Cases", true);
	}
	else LogError("Webhook not available :(");

	if(g_hDSKick.BoolValue && IsClientInGame(client)) KickClient(client);
}

int GetClientFromAccountID(int iAccountID)
{
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientConnected(i) && !IsFakeClient(i) && IsClientAuthorized(i))
		{
			if(GetSteamAccountID(i) == iAccountID)
			{
				return i;
			}
		}
	}
	
	return -1;
}

stock int CF_CheckPrime(int client) // Thanks CYBERC4T
{
	if(!g_hDSPrime.BoolValue) return 2;

	if (STEAMWORKS_ON())
	{
		if(k_EUserHasLicenseResultDoesNotHaveLicense != SteamWorks_HasLicenseForApp(client, 624820)) return 2;
		else return 1;
	}
	else return 0;
}

Action Timer_SendRewardMatchEndDrops(Handle hTimer)
{
	if(g_hDSInfo.BoolValue)
	{
		g_hTimerWaitDrops = CreateTimer(1.2, Timer_WaitDrops);
		
		PrintToChatAll(" \x07Пытаемся призвать дроп");
	}
	
	if(g_iOS == 1)
	{
		SDKCall(g_hRewardMatchEndDrops, 0xDEADC0DE, false);
	}
	else
	{
		SDKCall(g_hRewardMatchEndDrops, false);
	}
	
	return Plugin_Continue;
}

Action Timer_WaitDrops(Handle hTimer)
{
	g_hTimerWaitDrops = null;
	
	PrintToChatAll(" \x07Попытка провалилась :(");
}