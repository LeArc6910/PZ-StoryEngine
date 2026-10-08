-- 세력이 먼저 부탁하는 물건 목록 (서버 측 전용).
-- 무엇을 부탁할지는 게임이 이 표에서 고르고, AI 는 말투만 입힌다.
-- why 는 AI 에게 넘기는 영어 사정 설명이다. 액체 용기(병, 기름통)는 빈 통을 내밀 수 있어 넣지 않는다.
-- when = "power" | "water" | "winter" 인 부탁은 그 형편일 때만 나오고, 그때는 3배로 잘 뽑힌다 (World.lua)

if isClient() then return end

require "StoryEngine/Core"

local Needs = {}
StoryEngine.Needs = Needs

Needs.TABLE = {
    ray = {
        { tier = 1, why = "he twisted his ankle and the pain keeps him up at night", items = { { "Base.Pills", 1 } } },
        { tier = 1, why = "he is down to his last can of food", items = { { "Base.TinnedBeans", 3 } } },
        { tier = 1, why = "the batteries in his radio are almost dead", items = { { "Base.Battery", 3 } } },
        { tier = 2, why = "he cut his hand badly on a broken window", items = { { "Base.Disinfectant", 1 }, { "Base.Bandage", 3 } } },
        { tier = 2, why = "the farmhouse well pump broke and he is out of clean water", items = { { "Base.WaterRationCan", 4 } } },
        { tier = 2, when = "water", why = "the taps ran dry and the animals and the family he took in have nothing to drink", items = { { "Base.WaterRationCan", 5 } } },
        { tier = 3, why = "the cut on his hand got infected and he has a fever", items = { { "Base.Antibiotics", 1 }, { "Base.SutureNeedle", 1 } } },
        { tier = 4, why = "a neighbour he took in came to him with a gunshot wound", items = { { "Base.Antibiotics", 2 }, { "Base.SutureNeedle", 1 }, { "Base.Bandage", 3 } } },
        { tier = 4, why = "the dead broke into his barn and all he has is a kitchen knife", items = { { "Base.Shotgun", 1 }, { "Base.ShotgunShells", 6 } } },
        { tier = 5, why = "he wants to drive to Louisville to find his daughter but the truck is dead", items = { { "Base.CarBattery1", 1 }, { "Base.EngineParts", 8 } } },
        { tier = 2, why = "he wants a ham radio strong enough to call around the county for news of his daughter", items = { { "Base.HamRadio1", 1 }, { "Base.ElectricWire", 2 } } },
    },
    guard = {
        { tier = 1, why = "a patrol came back scratched up", items = { { "Base.Bandage", 2 } } },
        { tier = 1, why = "they are patching torn gear and radios", items = { { "Base.DuctTape", 2 } } },
        { tier = 2, why = "a wounded man in the camp infirmary is in pain", items = { { "Base.Pills", 1 }, { "Base.AlcoholWipes", 2 } } },
        { tier = 2, why = "the east gate is failing and needs reinforcing", items = { { "Base.NailsBox", 1 }, { "Base.Hammer", 1 } } },
        { tier = 3, when = "power", why = "the camp's radios and perimeter lights went dark when the grid died", items = { { "Base.Battery", 12 } } },
        { tier = 3, why = "a fever is spreading through the camp", items = { { "Base.Antibiotics", 3 } } },
        { tier = 3, why = "a soldier broke his leg on patrol", items = { { "Base.Splint", 1 }, { "Base.SutureNeedle", 1 } } },
        { tier = 4, why = "they have to break into a barricaded pharmacy for medicine", items = { { "Base.Sledgehammer", 1 }, { "Base.Crowbar", 1 } } },
        { tier = 4, why = "the camp's field radio burned out and they are cut off from command", items = { { "Base.ElectronicsScrap", 7 }, { "Base.ElectricWire", 4 } } },
        { tier = 5, why = "the generator that powers the camp's perimeter lights died", items = { { "Base.Generator", 1 }, { "Base.ElectricWire", 5 } } },
        { tier = 5, why = "a squad is going into Louisville and needs full medical kits", items = { { "Base.Antibiotics", 2 }, { "Base.SutureNeedle", 2 }, { "Base.Splint", 1 }, { "Base.Bandage", 2 } } },
    },
    casey = {
        { tier = 1, why = "the batteries for the ham radio are running low and it is her only link to anyone", items = { { "Base.Battery", 3 } } },
        { tier = 1, why = "she has been living on crackers for a week", items = { { "Base.TinnedBeans", 2 }, { "Base.Chocolate", 1 } } },
        { tier = 2, when = "power", why = "the grid is down and the ham rig now runs only on batteries", items = { { "Base.Battery", 6 } } },
        { tier = 2, why = "the ham rig keeps cutting out and needs spare parts", items = { { "Base.ElectronicsScrap", 4 } } },
        { tier = 2, why = "she burned her hand badly on the soldering iron", items = { { "Base.Bandage", 2 }, { "Base.Disinfectant", 1 } } },
        { tier = 3, why = "she wants to build a repeater antenna so more survivors can hear each other", items = { { "Base.ElectricWire", 3 }, { "Base.ElectronicsScrap", 4 } } },
        { tier = 3, why = "her dad's heart medicine ran out and he is getting worse", items = { { "Base.PillsBeta", 3 } } },
        { tier = 1, why = "she wants to hand a pair of walkie-talkies to neighbours who are hiding alone", items = { { "Base.WalkieTalkie4", 2 } } },
        { tier = 4, why = "a storm fried the ham rig and the backup set, and the county has gone quiet", items = { { "Base.HamRadio1", 2 }, { "Base.ElectronicsScrap", 7 } } },
        { tier = 5, why = "the power in the radio shack is failing and the station will go silent", items = { { "Base.Generator", 1 }, { "Base.ElectricWire", 5 } } },
    },
    doc = {
        { tier = 1, why = "her patients have not eaten in two days", items = { { "Base.TinnedBeans", 3 } } },
        { tier = 1, why = "the clinic's lamps died in the middle of a night shift", items = { { "Base.Battery", 3 } } },
        { tier = 2, why = "the tap ran dry and her patients need clean water", items = { { "Base.WaterRationCan", 4 } } },
        { tier = 2, why = "a bad night used up all her dressings", items = { { "Base.Bandage", 2 }, { "Base.AlcoholWipes", 2 } } },
        { tier = 3, why = "a boy in her care has an infected wound", items = { { "Base.Antibiotics", 3 } } },
        { tier = 3, why = "she has to amputate a crushed foot and has no proper saw", items = { { "Base.Saw", 1 }, { "Base.Disinfectant", 2 }, { "Base.SutureNeedle", 1 } } },
        { tier = 4, why = "the dead broke through the clinic's back door", items = { { "Base.NailsBox", 3 }, { "Base.Hammer", 1 }, { "Base.SheetMetal", 3 } } },
        { tier = 5, why = "a pregnant woman is due soon and it will not be an easy birth", items = { { "Base.SutureNeedle", 2 }, { "Base.SutureNeedleHolder", 1 }, { "Base.Antibiotics", 2 }, { "Base.Bandage", 2 } } },
        { tier = 5, why = "she needs power to keep insulin cold for a diabetic patient", items = { { "Base.Generator", 1 }, { "Base.ElectricWire", 5 } } },
    },
    pike = {
        { tier = 1, why = "the congregation is out of candles for evening prayers", items = { { "Base.Candle", 6 } } },
        { tier = 1, why = "a family arrived at the church with nothing to eat", items = { { "Base.TinnedBeans", 3 } } },
        { tier = 2, why = "the rain barrels are empty and the children are thirsty", items = { { "Base.WaterRationCan", 4 } } },
        { tier = 1, when = "winter", why = "winter came and the refugees in the church are shivering through the nights", items = { { "Base.Sheet", 4 } } },
        { tier = 2, when = "winter", why = "winter came and the church stove needs wood to keep the refugees from freezing", items = { { "Base.Firewood", 6 }, { "Base.Matches", 2 } } },
        { tier = 2, why = "one of the elders took a bad fall on the church steps", items = { { "Base.Pills", 1 }, { "Base.Bandage", 2 } } },
        { tier = 3, why = "a fever is spreading among the refugees", items = { { "Base.Antibiotics", 1 }, { "Base.PillsVitamins", 2 } } },
        { tier = 3, why = "the church doors will not hold if the dead come in numbers", items = { { "Base.NailsBox", 2 }, { "Base.Hammer", 1 }, { "Base.Saw", 1 } } },
        { tier = 4, why = "he is feeding twenty people now and the pantry is empty", items = { { "Base.CannedChili", 4 }, { "Base.TinnedSoup", 5 } } },
        { tier = 5, why = "he wants to plant a garden behind the church to feed everyone next year", items = { { "Base.CarrotBagSeed2", 3 }, { "Base.PotatoBagSeed2", 3 }, { "Base.TomatoBagSeed2", 3 }, { "Base.GardenHoe", 1 } } },
    },
    dewey = {
        { tier = 1, why = "she is out of duct tape for patching radiator hoses", items = { { "Base.DuctTape", 2 } } },
        { tier = 1, why = "she ran out of screws halfway through a job", items = { { "Base.ScrewsBox", 1 } } },
        { tier = 2, why = "she has been under cars for days and forgot to scavenge food", items = { { "Base.CannedChili", 5 } } },
        { tier = 2, why = "her work light died while she was under a truck", items = { { "Base.HandTorch", 2 }, { "Base.Battery", 3 } } },
        { tier = 3, why = "she tore her arm open on a radiator fin", items = { { "Base.Disinfectant", 1 }, { "Base.Bandage", 3 }, { "Base.Pills", 1 } } },
        { tier = 3, why = "her welding kit is empty", items = { { "Base.WeldingRods", 6 } } },
        { tier = 4, why = "she found a school bus and needs to get it running", items = { { "Base.CarBattery1", 1 }, { "Base.EngineParts", 4 } } },
        { tier = 5, why = "she is building an armoured truck to get survivors out of the county", items = { { "Base.SheetMetal", 6 }, { "Base.WeldingRods", 4 }, { "Base.BlowTorch", 1 } } },
    },
    hunter = {
        { tier = 1, why = "his snares keep breaking and he needs fresh line", items = { { "Base.Twine", 4 } } },
        { tier = 1, why = "he is out of matches for his stove", items = { { "Base.Matches", 4 } } },
        { tier = 2, when = "winter", why = "the cold snap caught him short of firewood for the cabin", items = { { "Base.Firewood", 8 } } },
        { tier = 2, why = "a rotten tooth has been killing him for a week", items = { { "Base.Pills", 2 } } },
        { tier = 2, why = "his knife snapped while he was dressing a deer", items = { { "Base.HuntingKnife", 1 } } },
        { tier = 3, why = "he is short on rifle rounds for the winter", items = { { "Base.308Box", 1 } } },
        { tier = 3, why = "a coyote bite on his hand is going bad", items = { { "Base.Antibiotics", 2 }, { "Base.Disinfectant", 2 } } },
        { tier = 4, why = "the roof of his cabin caved in under a fallen tree", items = { { "Base.NailsBox", 3 }, { "Base.Hammer", 1 }, { "Base.Saw", 1 }, { "Base.SheetMetal", 2 } } },
        { tier = 5, why = "he lost his rifle crossing the river", items = { { "Base.HuntingRifle", 1 }, { "Base.308Box", 1 } } },
    },
    rats = {
        { tier = 1, why = "the crew is out of smokes and getting restless", items = { { "Base.CigarettePack", 2 } } },
        { tier = 1, why = "they are fixing up a truck", items = { { "Base.ScrewsBox", 1 } } },
        { tier = 2, why = "they ran into a horde and burned through their shells", items = { { "Base.ShotgunShells", 15 } } },
        { tier = 2, why = "they are cutting through a fence to a warehouse", items = { { "Base.Saw", 1 }, { "Base.DuctTape", 3 } } },
        { tier = 3, why = "they are planning a big job and need rounds", items = { { "Base.Bullets9mmBox", 2 } } },
        { tier = 3, why = "Vic's brother got cut open and it looks bad", items = { { "Base.Antibiotics", 1 }, { "Base.Pills", 2 } } },
        { tier = 4, why = "they plan to hit the prison armoury and need rifle rounds", items = { { "Base.556Box", 2 } } },
        { tier = 4, why = "the battery in their getaway truck is dead", items = { { "Base.CarBattery1", 1 }, { "Base.EngineParts", 4 } } },
        { tier = 5, why = "a rival crew is moving into their territory", items = { { "Base.HuntingRifle", 1 }, { "Base.308Box", 1 } } },
        { tier = 5, why = "they want to cut into a bank vault in Louisville", items = { { "Base.BlowTorch", 2 }, { "Base.Sledgehammer", 1 }, { "Base.Crowbar", 1 } } },
    },
}

-- 후임 목소리(Voices.lua)의 부탁 (2026-10-08). 앞 사람의 개인 사정(레이의 딸, 케이시 아버지의 약 등)이 섞이지 않게
-- 후임마다 따로 둔다. 거점이 같으니 물건은 그 거점이 늘 쓰던 것들
Needs.VOICE_TABLE = {
    martha = {
        { tier = 1, why = "the hens stopped laying and she is down to her last cans", items = { { "Base.TinnedBeans", 3 } } },
        { tier = 1, why = "her old radio eats batteries and it is her only company at night", items = { { "Base.Battery", 3 } } },
        { tier = 2, why = "she tore her palm open on barbed wire mending the fence", items = { { "Base.Disinfectant", 1 }, { "Base.Bandage", 3 } } },
        { tier = 2, why = "she wants to plant Ray's garden beds again before the season turns", items = { { "Base.TomatoBagSeed2", 1 }, { "Base.CarrotBagSeed2", 1 }, { "Base.GardenHoe", 1 } } },
        { tier = 2, when = "water", why = "the taps ran dry and the animals on both farms have nothing to drink", items = { { "Base.WaterRationCan", 5 } } },
        { tier = 3, why = "the cut on her hand went bad and she is running a fever", items = { { "Base.Antibiotics", 1 }, { "Base.SutureNeedle", 1 } } },
        { tier = 4, why = "the dead broke into the barn and all she has is a pitchfork", items = { { "Base.Shotgun", 1 }, { "Base.ShotgunShells", 6 } } },
        { tier = 5, why = "she wants Ray's old pickup running again to haul the harvest to the neighbours", items = { { "Base.CarBattery1", 1 }, { "Base.EngineParts", 8 } } },
    },
    nora = {
        { tier = 1, why = "the station's spare batteries are almost gone", items = { { "Base.Battery", 3 } } },
        { tier = 1, why = "she has been living on coffee and crackers since she took over the station", items = { { "Base.TinnedSoup", 2 } } },
        { tier = 2, why = "she wants to link the Brandenburg group with the county and needs parts for a relay", items = { { "Base.ElectronicsScrap", 4 }, { "Base.ElectricWire", 2 } } },
        { tier = 2, when = "power", why = "the grid is down and the station now runs only on batteries", items = { { "Base.Battery", 6 } } },
        { tier = 2, why = "she slipped on the tower ladder and cut her leg", items = { { "Base.Bandage", 2 }, { "Base.Disinfectant", 1 } } },
        { tier = 3, why = "a storm bent the antenna mast and she needs to brace it", items = { { "Base.SheetMetal", 2 }, { "Base.ScrewsBox", 1 }, { "Base.DuctTape", 2 } } },
        { tier = 4, why = "she wants a second ham radio so the station never goes silent again", items = { { "Base.HamRadio1", 2 }, { "Base.ElectronicsScrap", 7 } } },
        { tier = 5, why = "she wants a generator so the station can broadcast through the winter", items = { { "Base.Generator", 1 }, { "Base.ElectricWire", 5 } } },
    },
    sam = {
        { tier = 1, why = "he used the last of June's dressings on a farmer's cut", items = { { "Base.Bandage", 2 } } },
        { tier = 1, why = "the patients have not eaten since yesterday", items = { { "Base.TinnedBeans", 3 } } },
        { tier = 2, why = "he is not sure he can clean wounds properly without proper supplies", items = { { "Base.AlcoholWipes", 2 }, { "Base.Disinfectant", 1 } } },
        { tier = 2, when = "water", why = "the tap ran dry and he cannot keep the patients or the instruments clean", items = { { "Base.WaterRationCan", 4 } } },
        { tier = 3, why = "a woman came in with an infected wound and June's antibiotics are gone", items = { { "Base.Antibiotics", 2 } } },
        { tier = 3, why = "he has to close a deep cut for the first time on his own", items = { { "Base.SutureNeedle", 2 }, { "Base.SutureNeedleHolder", 1 } } },
        { tier = 4, why = "a man with a broken leg was carried in and he needs to set it the way June showed him", items = { { "Base.Splint", 2 }, { "Base.Pills", 2 }, { "Base.Antibiotics", 1 } } },
        { tier = 5, why = "he wants the clinic stocked so it never runs dry the way it did when June was gone", items = { { "Base.Antibiotics", 3 }, { "Base.SutureNeedle", 3 }, { "Base.Bandage", 6 } } },
    },
    esther = {
        { tier = 1, why = "the children need something warm in their bellies", items = { { "Base.TinnedSoup", 3 } } },
        { tier = 1, when = "winter", why = "winter came and the people sleeping in the church are cold at night", items = { { "Base.Sheet", 4 } } },
        { tier = 2, when = "winter", why = "winter came and the church stove needs wood to keep everyone warm", items = { { "Base.Firewood", 8 } } },
        { tier = 2, why = "she is running the kitchen for thirty people with an empty pantry", items = { { "Base.TinnedBeans", 4 }, { "Base.CannedChili", 2 } } },
        { tier = 2, when = "water", why = "the church well went bad and she needs clean water for the families", items = { { "Base.WaterRationCan", 5 } } },
        { tier = 3, why = "a fever is going round the children's room", items = { { "Base.Pills", 2 }, { "Base.PillsVitamins", 2 } } },
        { tier = 4, why = "the church doors will not hold another night of the dead pressing on them", items = { { "Base.NailsBox", 2 }, { "Base.Hammer", 1 }, { "Base.SheetMetal", 3 } } },
        { tier = 5, why = "she wants to plant a field behind the church so nobody there goes hungry again", items = { { "Base.PotatoBagSeed2", 2 }, { "Base.TomatoBagSeed2", 2 }, { "Base.GardenHoe", 2 } } },
    },
    lenny = {
        { tier = 1, why = "he ran out of tape halfway through patching a radiator hose", items = { { "Base.DuctTape", 2 } } },
        { tier = 1, why = "his work light died while he was under a car", items = { { "Base.HandTorch", 1 }, { "Base.Battery", 2 } } },
        { tier = 2, why = "he burned his arm on an exhaust and is too stubborn to stop working", items = { { "Base.Bandage", 2 }, { "Base.Disinfectant", 1 } } },
        { tier = 2, why = "Dewey's toolbox is missing the pieces he keeps needing", items = { { "Base.ScrewsBox", 1 }, { "Base.Saw", 1 } } },
        { tier = 3, why = "he wants to learn welding the way Dewey did and the kit is empty", items = { { "Base.WeldingRods", 6 } } },
        { tier = 4, why = "a family's car died on the road and he wants to get it running for them", items = { { "Base.CarBattery1", 1 }, { "Base.EngineParts", 4 } } },
        { tier = 5, why = "he wants to finish the truck Dewey started, to prove he can", items = { { "Base.EngineParts", 8 }, { "Base.BlowTorch", 1 }, { "Base.WeldingRods", 4 } } },
    },
    kowalski = {
        { tier = 1, why = "a patrol came back scratched up and the aid bag is empty", items = { { "Base.Bandage", 2 } } },
        { tier = 1, why = "the squad is down to half rations", items = { { "Base.TinnedBeans", 3 } } },
        { tier = 2, why = "he wants the squad able to signal each other on patrol", items = { { "Base.WalkieTalkie4", 1 }, { "Base.Battery", 3 } } },
        { tier = 3, when = "power", why = "the camp's radios and perimeter lights went dark when the grid died", items = { { "Base.Battery", 12 } } },
        { tier = 3, why = "the squad is low on pistol rounds and he will not send them out empty", items = { { "Base.Bullets9mmBox", 2 } } },
        { tier = 3, why = "a soldier broke his arm on watch", items = { { "Base.Splint", 1 }, { "Base.Pills", 2 } } },
        { tier = 4, why = "the fence line is failing and he cannot hold the camp with it down", items = { { "Base.SheetMetal", 4 }, { "Base.NailsBox", 2 }, { "Base.Hammer", 1 } } },
        { tier = 5, why = "he wants rifle rounds stocked before the next big horde comes through", items = { { "Base.556Box", 3 } } },
    },
    red = {
        { tier = 1, why = "the crew is short on smokes and getting mean about it", items = { { "Base.CigarettePack", 2 } } },
        { tier = 1, why = "she is feeding the crew's kids out of her own share", items = { { "Base.TinnedBeans", 3 } } },
        { tier = 2, why = "she wants the trading tables patched up before market day", items = { { "Base.NailsBox", 1 }, { "Base.Hammer", 1 } } },
        { tier = 2, why = "one of the kids cut his foot on broken glass", items = { { "Base.Bandage", 2 }, { "Base.Disinfectant", 1 } } },
        { tier = 3, why = "she wants the crew able to defend the market without starting a war", items = { { "Base.Bullets9mmBox", 2 } } },
        { tier = 4, why = "she wants the crew's truck running for honest trade runs", items = { { "Base.CarBattery1", 1 }, { "Base.EngineParts", 4 } } },
        { tier = 5, why = "she wants a proper storeroom so the crew stops living hand to mouth", items = { { "Base.SheetMetal", 4 }, { "Base.BlowTorch", 1 }, { "Base.Crowbar", 1 } } },
    },
    dutch = {
        { tier = 1, why = "his men want their smokes and he wants them quiet", items = { { "Base.CigarettePack", 2 } } },
        { tier = 2, why = "he is putting up a toll gate on the county road", items = { { "Base.Saw", 1 }, { "Base.DuctTape", 3 } } },
        { tier = 3, why = "he wants rounds to make sure everyone pays the toll", items = { { "Base.Bullets9mmBox", 2 } } },
        { tier = 3, why = "one of his men took a knife in the side", items = { { "Base.Antibiotics", 1 }, { "Base.Pills", 2 } } },
        { tier = 4, why = "he wants rifle rounds to scare off the soldiers", items = { { "Base.556Box", 2 } } },
        { tier = 5, why = "he wants a rifle with reach to watch the road from the water tower", items = { { "Base.HuntingRifle", 1 }, { "Base.308Box", 1 } } },
    },
    caleb = {
        { tier = 1, why = "his snares keep breaking and he needs fresh line", items = { { "Base.Twine", 4 } } },
        { tier = 1, why = "the smokehouse is empty and the trap lines have been poor", items = { { "Base.TinnedBeans", 3 } } },
        { tier = 2, when = "winter", why = "the cold came early and the cabin is short of firewood", items = { { "Base.Firewood", 8 } } },
        { tier = 2, why = "he is rebuilding the cabin porch and ran out of nails", items = { { "Base.NailsBox", 1 }, { "Base.Hammer", 1 } } },
        { tier = 3, why = "he gashed his leg on a trap he was resetting", items = { { "Base.SutureNeedle", 1 }, { "Base.Disinfectant", 1 }, { "Base.Bandage", 2 } } },
        { tier = 4, why = "his father's old hunting knife broke and the woods are full of the dead", items = { { "Base.HuntingKnife", 1 }, { "Base.Shotgun", 1 }, { "Base.ShotgunShells", 6 } } },
        { tier = 5, why = "he wants Hank's rifle working again to keep the trap lines safe", items = { { "Base.HuntingRifle", 1 }, { "Base.308Box", 1 } } },
    },
}

-- 이 채널의 부탁 표 (후임이 있으면 그 후임 것)
function Needs.listOf(fid)
    local Factions = StoryEngine.Factions
    local voice = Factions and Factions.voice and Factions.voice[fid]
    if voice and Needs.VOICE_TABLE[voice] then return Needs.VOICE_TABLE[voice] end
    return Needs.TABLE[fid]
end

-- 지금 형편에 맞는 부탁만 (when 이 있으면 그 형편일 때만, 3배 가중치). only 면 그 조건의 부탁만
local function available(fid, only)
    local World = StoryEngine.World
    local out = {}
    for _, n in ipairs(Needs.listOf(fid) or {}) do
        if n.when then
            if World and World.active(n.when) and (not only or n.when == only) then
                for _ = 1, 3 do out[#out + 1] = n end
            end
        elseif not only then
            out[#out + 1] = n
        end
    end
    return out
end
Needs.available = available

-- 세력과 등급에 맞는 부탁 하나. 그 등급이 없으면 가장 가까운 낮은 등급.
-- prefer: 그 NPC 가 가장 부족한 생활 자원 (Life.needPrefer). 같은 등급에 그 자원을 채우는 부탁이 있으면 그것부터
-- strict: 그 자원을 채우는 부탁만 (급한 부탁). 그 등급 이하에 없으면 위 등급에서 찾고, 그래도 없으면 nil
-- only: 그 형편(when)의 부탁만 (World 의 파이크 난방 부탁). 그 등급 이하에 없으면 nil
function Needs.pick(fid, tier, prefer, strict, only)
    if not Needs.listOf(fid) then return nil end
    local list = available(fid, only)
    if only then
        for t = tier, 1, -1 do
            local pool = {}
            for _, n in ipairs(list) do if n.tier == t then pool[#pool + 1] = n end end
            if #pool > 0 then return pool[ZombRand(#pool) + 1] end
        end
        return nil
    end
    local Life = StoryEngine.Life
    if strict and prefer and Life then
        local order = {}
        for t = tier, 1, -1 do order[#order + 1] = t end
        for t = tier + 1, 5 do order[#order + 1] = t end
        for _, t in ipairs(order) do
            local pool = {}
            for _, n in ipairs(list) do
                if n.tier == t and Life.resourceOfItems(n.items) == prefer then pool[#pool + 1] = n end
            end
            if #pool > 0 then return pool[ZombRand(#pool) + 1] end
        end
        return nil
    end
    for t = tier, 1, -1 do
        local pool, preferred = {}, {}
        for _, n in ipairs(list) do
            if n.tier == t then
                pool[#pool + 1] = n
                if prefer and Life and Life.resourceOfItems(n.items) == prefer then preferred[#preferred + 1] = n end
            end
        end
        if #preferred > 0 then return preferred[ZombRand(#preferred) + 1] end
        if #pool > 0 then return pool[ZombRand(#pool) + 1] end
    end
    return nil
end

return Needs
