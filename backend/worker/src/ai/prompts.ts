/**
 * Astra C prompts. The structure (and the rules on IDs, avoid, empty focus,
 * arrows, "steps first") comes from experiments/som-test/variant_c.py
 * (prompt_parts, prompt_steps). On 2026-10-17 the wording was rewritten, at
 * the person's request, to the app design's short tone (Camera/artboards/car.tsx);
 * the realism numbers in docs/AI_LIVE_CHECK.md were measured with the older,
 * longer text.
 */
import { pyDumps } from "./schema";
import { MAX_ROUNDS } from "./validate";

/** Step instructions as the experiment sends them, or free text from the phone. */
export type Instructions = string | Array<{ title: string; text: string }>;

export interface PromptPart {
  id: string;
  label: string;
  box: number[];
}

/**
 * A later photo of the same task (multi-photo session, 2026-10-17). The phone
 * sends it as is; the server keeps no session state.
 */
export interface Context {
  /** 1..MAX_ROUNDS; round 1 context requires answers. */
  round: number;
  /** What the previous round asked the person to photograph. */
  photoPrompt: string;
  /** Titles of every step already done, in order. */
  doneSteps: string[];
  previousObject?: string;
  answers?: Array<{ question: string; answer: string; unit?: string }>;
}

const quoted = (text: string) => `„${text}“`;
const doneList = (steps: string[]) => (steps.length ? steps.map(quoted).join(", ") : "არაფერი");

/** variant_c.prompt_parts, short labels. */
export function promptParts(instructions: Instructions, context?: Context): string {
  const lead = context
    ? `ეს არის იმავე დავალების მე-${context.round} ფოტო. უკვე შესრულებულია: ${doneList(context.doneSteps)}. ` +
      `წინა ფოტოს შემდეგ მომხმარებელს ვთხოვეთ: ${quoted(context.photoPrompt)}. ` +
      "ამ ახალ ფოტოზე გამოყავი გაგრძელებისთვის საჭირო ხილული ნაწილები; " +
      "object შეიძლება ახალი იყოს (მაგ. „მოხსნილი სიფონი“).\n"
    : "";
  return (
    lead +
    "ამ ფოტოზე გამოყავი მოქმედებებისთვის საჭირო მხოლოდ ფიზიკური ხილული კომპონენტები. " +
    "ცარიელი ადგილი, ფონი ან ზონა, სადაც ნივთი უნდა დადგას, ნაწილი არ არის და parts-ში არ ჩასვა. " +
    "დააბრუნე object და parts: ქართული label და მჭიდრო box=[x0,y0,x1,y1], " +
    "ფოტოს სიგანის/სიმაღლის მიმართ 0..1000. ID-ები და ნაბიჯები არ შექმნა. " +
    "object არის სცენის ან ობიექტის მოკლე სახელი, მაქსიმუმ 3 სიტყვა (მაგ. „ძრავის განყოფილება“, „ნიჟარის სიფონი“). " +
    "label მოკლეა, მაქსიმუმ 5 სიტყვა (მაგ. „ზეთის საზომი ღერო“). " +
    "თუ რამდენიმე მსგავსი ან ერთგვაროვანი ნაწილია, label-ში აუცილებლად დააზუსტე " +
    "მდებარეობა (მარჯვენა/მარცხენა/ზედა/ქვედა), რათა მოქმედების სამიზნე მკაფიოდ გაირჩეს. " +
    "ხილული განმასხვავებელი მტკიცებულება (მაგ. „წვეთებით“, „სველი“) label-ში დაამატე მხოლოდ 1–2 სიტყვით " +
    "და მხოლოდ თუ ფოტოზე ჩანს; არ მიაწერო ნავარაუდევი მტკიცებულება. " +
    "უხილავი ნაწილი არ გამოიგონო.\n" +
    pyDumps(context ? { instructions, context } : instructions)
  );
}

/**
 * When the steps call asks for another photo (`continuation`). The last
 * allowed round may only complete; schemaSteps enforces the same.
 */
function continuationRule(context: Context | undefined, maxRound: number, count?: number): string {
  const round = context?.round ?? 1;
  let rule = "";
  if (context) {
    rule +=
      `ეს მე-${round} ფოტოა, გადაღებული თხოვნით ${quoted(context.photoPrompt)}; ` +
      `შესრულებული ნაბიჯები არ გაიმეორო: ${doneList(context.doneSteps)}; გააგრძელე აქედან. `;
  }
  if (round >= maxRound) {
    return rule + "ახალი ფოტო აღარ შეიძლება: continuation=complete, prompt/reason null, და დაასრულე ამ ფოტოთი. ";
  }
  return (
    rule +
    "ბოლოს continuation: needs_photo მხოლოდ მაშინ, როცა შემდეგი ნაბიჯები მოითხოვს მდგომარეობას, " +
    "რომელიც ამ ფოტოზე არ ჩანს ან ჯერ არ არსებობს (მოხსნილი ნაწილი, შიგნითა მხარე, სხვა კუთხე, გახსნილი საფარი). " +
    "მაშინ ნაბიჯები დაასრულე იმ მდგომარეობამდე, რომლის შემდეგაც ახალი ფოტოა საჭირო; " +
    "prompt — მოკლე ბრძანება რა გადაიღოს (≤60 სიმბ., მაგ. „გადაიღე მოხსნილი სიფონის შიგნითა მხარე ახლოდან“), " +
    "reason — ერთი წინადადება რატომ (≤100). " +
    `სხვა შემთხვევაში complete, prompt/reason null, და ინსტრუქცია სრულია${count ? ` (ჩვეულებრივ ${count} ნაბიჯი)` : ""}. `
  );
}

/** variant_c.prompt_steps, in the design's short, imperative tone. */
export function promptSteps(
  objectName: string,
  parts: PromptPart[],
  instructions: Instructions,
  context?: Context,
  opts: { maxRound?: number; count?: number } = {},
): string {
  return (
    "დაწერე მოცემული ნაბიჯები ქართულად, იმავე რიგით. ტონი: მოკლე, მკაფიო, მეგობრული. " +
    "title: ბრძანებითი, მაქსიმუმ 4 სიტყვა, ნომრის გარეშე (მაგ. „იპოვე ზეთის საზომი“). " +
    "text: 1–2 მოკლე წინადადება, მაქსიმუმ 120 სიმბოლო — სად არის ნაწილი და რა გააკეთოს " +
    "(მაგ. „ყვითელი რგოლი ძრავის საფარის ქვემოთ. ეს არის ზეთის საზომი ღერო.“). " +
    "tip: ერთი პრაქტიკული რჩევა, თუ ნამდვილად სჭირდება (მაგ. „ძრავი გამორთული უნდა იყოს და 5 წუთი გაცივებული.“), სხვა შემთხვევაში null. " +
    "warn: ერთი წინადადება მხოლოდ რეალურ საფრთხეზე ან დაზიანების რისკზე (მაგ. „MAX-ს ნუ გადააცილებ: ზედმეტი ზეთი ძრავს ავნებს.“), სხვა შემთხვევაში null. " +
    "tools: მაქსიმუმ 3, თითო name მოკლე სახელი (მაგ. „ქაღალდის ხელსახოცი“) და icon სიიდან ან null; ან ცარიელი. " +
    "icon: ნაბიჯის მთავარი მოქმედება სიიდან, თუ არცერთი არ ერგება — null. " +
    "გამოიყენე მხოლოდ ტელეფონის მიერ მინიჭებული IDs. focus/avoid/markers/arrows " +
    "მიუთითებს მხოლოდ ამ ნაწილებზე. avoid არის ნაწილი, რომელსაც არ უნდა შეეხო. " +
    "ნაბიჯები უპირატესად ფოტოზე ხილულ ნაწილებზე ააგე; თუ მოთხოვნას უხილავი კომპონენტი სჭირდება, " +
    "ერთ ნაბიჯში მოკლედ თქვი, სად ეძებოს, და რამდენიმე ნაბიჯად ნუ გაშლი. " +
    "როცა არაცარიელია focus, markers-ში ჩასვი ერთი მარკერი ფოკუს-ნაწილზე; label 1–3 სიტყვაა — " +
    "ნაწილის სახელი ან მოკლე არსებითი (მაგ. „ზეთის თავსახური“, „სველი შეერთება“), არა მოქმედება. " +
    "როცა სამიზნის რამდენიმე plausible კანდიდატია, მიმაგრებულ ფოტოზე გადაამოწმე მდებარეობა და ხილული მტკიცებულება " +
    "და აირჩიე ყველაზე სავარაუდო ID; არ აირჩიო მხოლოდ სიაში პირველი და არ დატოვო focus ცარიელი ამის გამო. " +
    "empty focus დასაშვებია მხოლოდ მაშინ, როცა სამიზნე სიაში ან ფოტოზე საერთოდ არ ჩანს (უხილავია); " +
    "მაშინ არ გამოიგონო ID, არ აიძულო არარელევანტური ნაწილი და აღწერე unknown_parts-ში. " +
    "თუ დასადგმელი ნივთი (მაგ. ვედრო) არ ჩანს, დატოვე empty focus; " +
    "ცარიელი ადგილის, ფონის ან დასადგმელი ზონის ID-ის გამოყენება აკრძალულია. " +
    "გაურკვევლობას, არჩევანის ახსნას ან ფოტოს შეზღუდვას text-ში, tip-ში და warn-ში ნუ წერ. " +
    "ზომები/დოზები ფოტოდან დადასტურებულად არ მიიჩნიო. " +
    "rotate: cw/ccw; move: up/down/left/right/toward/away. " +
    continuationRule(context, opts.maxRound ?? MAX_ROUNDS, opts.count) +
    "პირველი JSON გასაღები იყოს steps.\n" +
    pyDumps({ object: objectName, parts, instructions, context })
  );
}
