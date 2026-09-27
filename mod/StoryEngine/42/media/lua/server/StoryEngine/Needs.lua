-- 세력이 먼저 부탁하는 물건 목록 (서버 측 전용).
-- 무엇을 부탁할지는 게임이 이 표에서 고르고, AI 는 말투만 입힌다.
-- why 는 AI 에게 넘기는 영어 사정 설명이다. 액체 용기(병, 기름통)는 빈 통을 내밀 수 있어 넣지 않는다.

if isClient() then return end

require "StoryEngine/Core"

local Needs = {}
StoryEngine.Needs = Needs

Needs.TABLE = {
    ray = {
        { tier = 1, why = "he twisted his ankle and the pain keeps him up at night", items = { { "Base.Pills", 2 } } },
        { tier = 1, why = "he is down to his last can of food", items = { { "Base.TinnedBeans", 3 } } },
        { tier = 1, why = "the batteries in his radio are almost dead", items = { { "Base.Battery", 2 } } },
        { tier = 2, why = "he cut his hand badly on a broken window", items = { { "Base.Disinfectant", 1 }, { "Base.Bandage", 3 } } },
        { tier = 2, why = "the farmhouse well pump broke and he is out of clean water", items = { { "Base.WaterRationCan", 3 } } },
        { tier = 3, why = "the cut on his hand got infected and he has a fever", items = { { "Base.Antibiotics", 1 }, { "Base.SutureNeedle", 1 } } },
        { tier = 4, why = "a neighbour he took in came to him with a gunshot wound", items = { { "Base.Antibiotics", 2 }, { "Base.SutureNeedle", 2 }, { "Base.Bandage", 5 } } },
        { tier = 4, why = "the dead broke into his barn and all he has is a kitchen knife", items = { { "Base.Shotgun", 1 }, { "Base.ShotgunShellsBox", 1 } } },
        { tier = 5, why = "he wants to drive to Louisville to find his daughter but the truck is dead", items = { { "Base.CarBattery1", 1 }, { "Base.EngineParts", 5 } } },
        { tier = 5, why = "he is setting out for Louisville to find his daughter and needs a radio strong enough to call for help on the way", items = { { "Base.HamRadio1", 1 } } },
    },
    guard = {
        { tier = 1, why = "a patrol came back scratched up", items = { { "Base.Bandage", 4 } } },
        { tier = 1, why = "they are patching torn gear and radios", items = { { "Base.DuctTape", 2 } } },
        { tier = 2, why = "a wounded man in the camp infirmary is in pain", items = { { "Base.Pills", 3 }, { "Base.AlcoholWipes", 2 } } },
        { tier = 2, why = "the east gate is failing and needs reinforcing", items = { { "Base.NailsBox", 1 }, { "Base.Hammer", 1 } } },
        { tier = 3, why = "a fever is spreading through the camp", items = { { "Base.Antibiotics", 2 } } },
        { tier = 3, why = "a soldier broke his leg on patrol", items = { { "Base.Splint", 2 }, { "Base.SutureNeedle", 1 } } },
        { tier = 4, why = "they have to break into a barricaded pharmacy for medicine", items = { { "Base.Sledgehammer", 1 }, { "Base.Crowbar", 1 } } },
        { tier = 4, why = "the camp's field radio burned out and they are cut off from command", items = { { "Base.ElectronicsScrap", 10 }, { "Base.ElectricWire", 5 } } },
        { tier = 5, why = "the generator that powers the camp's perimeter lights died", items = { { "Base.Generator", 1 } } },
        { tier = 5, why = "a squad is going into Louisville and needs full medical kits", items = { { "Base.Antibiotics", 3 }, { "Base.SutureNeedle", 3 }, { "Base.Splint", 3 }, { "Base.Bandage", 6 } } },
    },
    casey = {
        { tier = 1, why = "the batteries for the ham radio are running low and it is their only link to anyone", items = { { "Base.Battery", 4 } } },
        { tier = 1, why = "they have been living on crackers for a week", items = { { "Base.TinnedBeans", 2 }, { "Base.Chocolate", 1 } } },
        { tier = 2, why = "the ham rig keeps cutting out and needs spare parts", items = { { "Base.ElectronicsScrap", 5 } } },
        { tier = 2, why = "they burned their hand badly on the soldering iron", items = { { "Base.Bandage", 2 }, { "Base.Disinfectant", 1 } } },
        { tier = 3, why = "they want to build a repeater antenna so more survivors can hear each other", items = { { "Base.ElectricWire", 5 }, { "Base.ElectronicsScrap", 8 } } },
        { tier = 3, why = "their dad's heart medicine ran out and he is getting worse", items = { { "Base.PillsBeta", 2 } } },
        { tier = 4, why = "they want to give a second walkie-talkie to a neighbour who is hiding alone", items = { { "Base.WalkieTalkie4", 1 } } },
        { tier = 5, why = "the power in the radio shack is failing and the station will go silent", items = { { "Base.Generator", 1 } } },
    },
    doc = {
        { tier = 1, why = "her patients have not eaten in two days", items = { { "Base.TinnedBeans", 3 } } },
        { tier = 1, why = "the clinic's lamps died in the middle of a night shift", items = { { "Base.Battery", 3 } } },
        { tier = 2, why = "the tap ran dry and her patients need clean water", items = { { "Base.WaterRationCan", 3 } } },
        { tier = 2, why = "a bad night used up all her dressings", items = { { "Base.Bandage", 5 }, { "Base.AlcoholWipes", 3 } } },
        { tier = 3, why = "a boy in her care has an infected wound", items = { { "Base.Antibiotics", 2 } } },
        { tier = 3, why = "she has to amputate a crushed foot and has no proper saw", items = { { "Base.Saw", 1 }, { "Base.Disinfectant", 2 } } },
        { tier = 4, why = "the dead broke through the clinic's back door", items = { { "Base.NailsBox", 2 }, { "Base.Hammer", 1 } } },
        { tier = 5, why = "a pregnant woman is due soon and it will not be an easy birth", items = { { "Base.SutureNeedle", 3 }, { "Base.SutureNeedleHolder", 1 }, { "Base.Antibiotics", 2 }, { "Base.Bandage", 8 } } },
        { tier = 5, why = "she needs power to keep insulin cold for a diabetic patient", items = { { "Base.Generator", 1 } } },
    },
    pike = {
        { tier = 1, why = "the congregation is out of candles for evening prayers", items = { { "Base.Candle", 4 } } },
        { tier = 1, why = "a family arrived at the church with nothing to eat", items = { { "Base.TinnedBeans", 3 } } },
        { tier = 2, why = "the rain barrels are empty and the children are thirsty", items = { { "Base.WaterRationCan", 4 } } },
        { tier = 2, why = "one of the elders took a bad fall on the church steps", items = { { "Base.Pills", 2 }, { "Base.Bandage", 2 } } },
        { tier = 3, why = "a fever is spreading among the refugees", items = { { "Base.Antibiotics", 1 }, { "Base.PillsVitamins", 2 } } },
        { tier = 3, why = "the church doors will not hold if the dead come in numbers", items = { { "Base.NailsBox", 1 }, { "Base.Hammer", 1 } } },
        { tier = 4, why = "he is feeding twenty people now and the pantry is empty", items = { { "Base.CannedChili", 6 }, { "Base.TinnedSoup", 6 } } },
        { tier = 5, why = "he wants to plant a garden behind the church to feed everyone next year", items = { { "Base.CarrotBagSeed2", 3 }, { "Base.PotatoBagSeed2", 3 }, { "Base.TomatoBagSeed2", 3 }, { "Base.GardenHoe", 1 } } },
    },
    dewey = {
        { tier = 1, why = "he is out of duct tape for patching radiator hoses", items = { { "Base.DuctTape", 2 } } },
        { tier = 1, why = "he ran out of screws halfway through a job", items = { { "Base.ScrewsBox", 1 } } },
        { tier = 2, why = "he has been under cars for days and forgot to scavenge food", items = { { "Base.CannedChili", 3 } } },
        { tier = 2, why = "his work light died while he was under a truck", items = { { "Base.HandTorch", 1 }, { "Base.Battery", 2 } } },
        { tier = 3, why = "he tore his arm open on a radiator fin", items = { { "Base.Disinfectant", 1 }, { "Base.Bandage", 3 } } },
        { tier = 3, why = "his welding kit is empty", items = { { "Base.WeldingRods", 3 } } },
        { tier = 4, why = "he found a school bus and needs to get it running", items = { { "Base.CarBattery1", 1 } } },
        { tier = 5, why = "he is building an armoured truck to get survivors out of the county", items = { { "Base.SheetMetal", 6 }, { "Base.WeldingRods", 4 }, { "Base.BlowTorch", 1 } } },
    },
    hunter = {
        { tier = 1, why = "his snares keep breaking and he needs fresh line", items = { { "Base.Twine", 3 } } },
        { tier = 1, why = "he is out of matches for his stove", items = { { "Base.Matches", 3 } } },
        { tier = 2, why = "a rotten tooth has been killing him for a week", items = { { "Base.Pills", 3 } } },
        { tier = 2, why = "his knife snapped while he was dressing a deer", items = { { "Base.HuntingKnife", 1 } } },
        { tier = 3, why = "he is short on rifle rounds for the winter", items = { { "Base.308Box", 1 } } },
        { tier = 3, why = "a coyote bite on his hand is going bad", items = { { "Base.Antibiotics", 1 }, { "Base.Disinfectant", 1 } } },
        { tier = 4, why = "the roof of his cabin caved in under a fallen tree", items = { { "Base.NailsBox", 2 }, { "Base.Hammer", 1 }, { "Base.Saw", 1 } } },
        { tier = 5, why = "he lost his rifle crossing the river", items = { { "Base.HuntingRifle", 1 }, { "Base.308Box", 1 } } },
    },
    rats = {
        { tier = 1, why = "the crew is out of smokes and getting restless", items = { { "Base.CigarettePack", 2 } } },
        { tier = 1, why = "they are fixing up a truck", items = { { "Base.ScrewsBox", 1 } } },
        { tier = 2, why = "they ran into a horde and burned through their shells", items = { { "Base.ShotgunShells", 10 } } },
        { tier = 2, why = "they are cutting through a fence to a warehouse", items = { { "Base.Saw", 1 }, { "Base.DuctTape", 1 } } },
        { tier = 3, why = "they are planning a big job and need rounds", items = { { "Base.Bullets9mm", 30 } } },
        { tier = 3, why = "Vic's brother got cut open and it looks bad", items = { { "Base.Antibiotics", 1 }, { "Base.Pills", 2 } } },
        { tier = 4, why = "they plan to hit the prison armoury and need rifle rounds", items = { { "Base.556Box", 2 } } },
        { tier = 4, why = "the battery in their getaway truck is dead", items = { { "Base.CarBattery1", 1 } } },
        { tier = 5, why = "a rival crew is moving into their territory", items = { { "Base.HuntingRifle", 1 }, { "Base.308Box", 2 } } },
        { tier = 5, why = "they want to cut into a bank vault in Louisville", items = { { "Base.BlowTorch", 2 }, { "Base.Sledgehammer", 1 } } },
    },
}

-- 세력과 등급에 맞는 부탁 하나. 그 등급이 없으면 가장 가까운 낮은 등급.
function Needs.pick(fid, tier)
    local list = Needs.TABLE[fid]
    if not list then return nil end
    for t = tier, 1, -1 do
        local pool = {}
        for _, n in ipairs(list) do
            if n.tier == t then pool[#pool + 1] = n end
        end
        if #pool > 0 then return pool[ZombRand(#pool) + 1] end
    end
    return nil
end

return Needs
