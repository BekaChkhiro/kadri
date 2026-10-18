/**
 * Capability "tools_v2" (2026-10-18): the tool catalog and step actions. The
 * same 32 ids, in this order, are in KadriCore's ToolCatalog and the app's
 * "tool-<id>" image assets.
 */

export const TOOL_CATALOG: ReadonlyArray<{ id: string; name: string }> = [
  { id: "ph1", name: "ჯვარედინი სახრახნისი PH1" },
  { id: "ph2", name: "ჯვარედინი სახრახნისი PH2" },
  { id: "flat_small", name: "ბრტყელი სახრახნისი (პატარა)" },
  { id: "flat_large", name: "ბრტყელი სახრახნისი (დიდი)" },
  { id: "torx_t10", name: "Torx სახრახნისი T10" },
  { id: "torx_t20", name: "Torx სახრახნისი T20" },
  { id: "hex_key", name: "ექვსკუთხა გასაღები" },
  { id: "adjustable_wrench", name: "რეგულირებადი გასაღები" },
  { id: "open_wrench", name: "ქანჩის გასაღები" },
  { id: "socket_wrench", name: "თავაკიანი გასაღები" },
  { id: "pipe_wrench", name: "მილის გასაღები" },
  { id: "pliers", name: "ბრტყელტუჩა" },
  { id: "needle_pliers", name: "წვრილტუჩა" },
  { id: "wire_cutter", name: "მავთულის საჭრელი" },
  { id: "wire_stripper", name: "კაბელის გამწმენდი" },
  { id: "crimper_rj45", name: "RJ45 კრიმპერი" },
  { id: "multimeter", name: "მულტიმეტრი" },
  { id: "voltage_tester", name: "ძაბვის ინდიკატორი" },
  { id: "flashlight", name: "ფანარი" },
  { id: "bucket", name: "ვედრო" },
  { id: "towel", name: "ტილო" },
  { id: "gloves", name: "ხელთათმანები" },
  { id: "antistatic_strap", name: "ანტისტატიკური სამაჯური" },
  { id: "thermal_paste", name: "თერმოპასტა" },
  { id: "cable_ties", name: "კაბელის სამაგრები" },
  { id: "tape_measure", name: "რულეტკა" },
  { id: "level", name: "თარაზო" },
  { id: "drill", name: "დრელი" },
  { id: "hammer", name: "ჩაქუჩი" },
  { id: "utility_knife", name: "საკანცელარიო დანა" },
  { id: "plumber_tape", name: "ფუმლენტა" },
  { id: "spudger", name: "პლასტმასის სპუჯერი" },
];

export const TOOL_IDS = TOOL_CATALOG.map((t) => t.id);

export const ACTION_KINDS = [
  "rotate_cw", "rotate_ccw", "press", "pull", "lift", "slide", "lever_up", "lever_down", "align", "tighten_order",
] as const;

export const ACTION_AMOUNTS = ["¼", "½", "1", "hand_tight_plus_quarter"] as const;

/** Kinds where `amount` means something; `order` is only for tighten_order. */
export const AMOUNT_KINDS: readonly string[] = ["rotate_cw", "rotate_ccw", "tighten_order"];

const SCREWDRIVERS = ["ph1", "ph2", "flat_small", "flat_large", "torx_t10", "torx_t20"];
const FIXED_WRENCHES = ["hex_key", "open_wrench", "socket_wrench"];
const ADJUSTABLE = ["adjustable_wrench", "pipe_wrench"];

/** Tools where a size means something; on the rest validate.ts drops size and fitCheck. */
export function toolHasSize(id: string): boolean {
  return [...SCREWDRIVERS, ...FIXED_WRENCHES, ...ADJUSTABLE, "drill"].includes(id);
}

/**
 * How the person checks an unconfirmed ("typical") size themselves (≤100),
 * for a card whose model sent no fitCheck; null for tools without a size.
 */
export function genericFitCheck(id: string): string | null {
  if (SCREWDRIVERS.includes(id)) return "მჭიდროდ უნდა ჩაჯდეს და არ ამოხტეს; თუ ხტება ან თამაშობს, სცადე მეზობელი ზომა";
  if (FIXED_WRENCHES.includes(id)) {
    return "უნდა ჩაჯდეს თამაშის გარეშე; თუ ბრუნავს, სცადე 1 მმ-ით პატარა/დიდი; ზუსტი არ გაქვს — რეგულირებადი";
  }
  if (ADJUSTABLE.includes(id)) return "ყბები ქანჩის წახნაგებს მჭიდროდ მოარგე; თუ ცურავს, კიდევ მოუჭირე რეგულატორი";
  if (id === "drill") return "ბურღის დიამეტრი დიუბელს უნდა ემთხვეოდეს — ზომა დიუბელის შეფუთვაზე წერია";
  return null;
}
