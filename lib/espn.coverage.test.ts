import { writeFileSync } from "node:fs";
import { it } from "vitest";
import { resolveImages } from "./images/resolve";

const NFL = ["Patrick Mahomes","Josh Allen","Lamar Jackson","Joe Burrow","Jalen Hurts","Justin Jefferson",
"Ja'Marr Chase","Tyreek Hill","Travis Kelce","Christian McCaffrey","Saquon Barkley","Micah Parsons",
"Myles Garrett","T.J. Watt","Aaron Donald","Nick Bosa","CeeDee Lamb","A.J. Brown","Davante Adams",
"Derrick Henry","Dak Prescott","Trevor Lawrence","Caleb Williams","Jayden Daniels","Bijan Robinson",
"Sauce Gardner","Trent Williams","George Kittle","Aaron Rodgers","Brock Purdy"];

const NBA = ["LeBron James","Stephen Curry","Kevin Durant","Giannis Antetokounmpo","Nikola Jokic",
"Luka Doncic","Joel Embiid","Jayson Tatum","Anthony Davis","Damian Lillard","Devin Booker",
"Shai Gilgeous-Alexander","Anthony Edwards","Victor Wembanyama","Kawhi Leonard","Jimmy Butler",
"Donovan Mitchell","Trae Young","Ja Morant","Zion Williamson","Paolo Banchero","Tyrese Haliburton",
"Jaylen Brown","Karl-Anthony Towns","De'Aaron Fox","Domantas Sabonis","Bam Adebayo","Rudy Gobert",
"Klay Thompson","Chris Paul"];

const ALLTIME = ["Michael Jordan","Kobe Bryant","Magic Johnson","Larry Bird","Shaquille O'Neal",
"Tim Duncan","Hakeem Olajuwon","Kareem Abdul-Jabbar","Wilt Chamberlain","Bill Russell",
"Tom Brady","Jerry Rice","Joe Montana","Peyton Manning","Walter Payton","Lawrence Taylor",
"Barry Sanders","Emmitt Smith","Brett Favre","Ray Lewis"];

it.runIf(!!process.env.COVER)("coverage", { timeout: 900_000 }, async () => {
  const out: string[] = [];
  for (const [label, names] of [["NFL current stars", NFL], ["NBA current stars", NBA], ["All-time greats", ALLTIME]] as [string,string[]][]) {
    const r = await resolveImages(names.map((n) => ({ name: n, title: n })), { freeOnly: true });
    const free = r.filter((x) => x.source !== "generated").length;
    out.push(`${label.padEnd(20)} FREE ${free}/${names.length} (${Math.round(free/names.length*100)}%)`);
    const miss = r.map((x,i)=>x.source==="generated"?names[i]:null).filter(Boolean);
    if (miss.length) out.push(`   no free image: ${miss.join(", ")}`);
  }
  writeFileSync("/tmp/stars.txt", out.join("\n"));
});
