/**
 * Astra C prompts, verbatim from experiments/som-test/variant_c.py
 * (prompt_parts, prompt_steps). Do not edit the wording here without a new
 * experiment: the realism numbers were measured with exactly this text.
 */
import { pyDumps } from "./schema";

/** Step instructions as the experiment sends them, or free text from the phone. */
export type Instructions = string | Array<{ title: string; text: string }>;

export interface PromptPart {
  id: string;
  label: string;
  box: number[];
}

/** variant_c.prompt_parts */
export function promptParts(instructions: Instructions): string {
  return (
    "ამ ფოტოზე გამოყავი მოქმედებებისთვის საჭირო მხოლოდ ფიზიკური ხილული კომპონენტები. " +
    "ცარიელი ადგილი, ფონი ან ზონა, სადაც ნივთი უნდა დადგას, ნაწილი არ არის და parts-ში არ ჩასვა. " +
    "დააბრუნე object და parts: ქართული label და მჭიდრო box=[x0,y0,x1,y1], " +
    "ფოტოს სიგანის/სიმაღლის მიმართ 0..1000. ID-ები და ნაბიჯები არ შექმნა. " +
    "თუ რამდენიმე მსგავსი ან ერთგვაროვანი ნაწილია, label-ში აუცილებლად დააზუსტე " +
    "მდებარეობა (მაგ. მარჯვენა/მარცხენა/ზედა/ქვედა), რათა მოქმედების სამიზნე მკაფიოდ გაირჩეს. " +
    "იმავე label string-ში მოკლედ აღწერე ხილული განმასხვავებელი მტკიცებულება " +
    "(წვეთები, სველი კვალი, შეერთება) მხოლოდ თუ ფოტოზე ჩანს; არ მიაწერო ნავარაუდევი მტკიცებულება. " +
    "უხილავი ნაწილი არ გამოიგონო.\n" +
    pyDumps(instructions)
  );
}

/** variant_c.prompt_steps */
export function promptSteps(objectName: string, parts: PromptPart[], instructions: Instructions): string {
  return (
    "დაწერე მოცემული ნაბიჯები ქართულად, იმავე რიგით და title/text-ით. " +
    "გამოიყენე მხოლოდ ტელეფონის მიერ მინიჭებული IDs. focus/avoid/markers/arrows " +
    "მიუთითებს მხოლოდ ამ ნაწილებზე. avoid არის ნაწილი, რომელსაც არ უნდა შეეხო. " +
    "როცა მოცემულ parts სიაში მოქმედების ხილული სამიზნის რამდენიმე plausible კანდიდატია, " +
    "მიმაგრებულ ფოტოზე გადაამოწმე მდებარეობა და ხილული მტკიცებულება (წვეთები, სველი კვალი, შეერთება). " +
    "აირჩიე ყველაზე სავარაუდო box ამ ხილული მტკიცებულების, მდებარეობის, label-ისა და ინსტრუქციის მიხედვით; " +
    "არ აირჩიო მხოლოდ სიაში პირველი კანდიდატი და არ გამოიგონო მტკიცებულება. " +
    "focus-ში მიუთითე მისი ID და warn-ში ჩაწერე გაურკვევლობა/დაშვება (uncertainty). " +
    "არ დატოვო focus ცარიელი მხოლოდ იმიტომ, რომ რამდენიმე მსგავსი ხილული ნაწილია. " +
    "empty focus დასაშვებია მხოლოდ მაშინ, როცა სამიზნე ნაწილების სიაში ან ფოტოზე საერთოდ არ ჩანს (უხილავია); " +
    "ასეთ დროს არ გამოიგონო ID, არ აიძულო არარელევანტური ნაწილი, აღწერე unknown_parts-ში და warn-ში ახსენი. " +
    "თუ დასადგმელი ნივთი (მაგ. ვედრო) არ ჩანს, დატოვე empty focus; " +
    "ცარიელი ადგილის, ფონის ან დასადგმელი ზონის ID-ის გამოყენება აკრძალულია. " +
    "rotate: cw/ccw; move: up/down/left/right/toward/away. " +
    "ზომები/დოზები ფოტოდან დადასტურებულად არ მიიჩნიო. ეს კვლევაა. " +
    "პირველი JSON გასაღები იყოს steps.\n" +
    pyDumps({ object: objectName, parts, instructions })
  );
}
