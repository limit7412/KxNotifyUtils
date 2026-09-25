// thumbnail.html の各候補を 1600x1600 の PNG として out/ に書き出す。
// BOOTH の一覧はサムネイルを正方形に切り抜くため、候補はすべて 1:1 で作る。
import { chromium } from "playwright";
import { mkdir } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

const dir = path.dirname(fileURLToPath(import.meta.url));
const out = path.join(dir, "out");
await mkdir(out, { recursive: true });

const browser = await chromium.launch(
  process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : {}
);
const page = await browser.newPage({ viewport: { width: 1800, height: 1800 }, deviceScaleFactor: 2 });
await page.goto("file://" + path.join(dir, "thumbnail.html"));
await page.evaluate(() => document.fonts.ready);

for (const id of ["a", "b", "c", "d"]) {
  const file = path.join(out, `thumbnail-${id}.png`);
  await page.locator(`#${id}`).screenshot({ path: file });
  console.log(file);
}
await browser.close();
