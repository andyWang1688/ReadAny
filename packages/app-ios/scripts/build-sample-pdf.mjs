// 生成 UI 测试用的多页 PDF 样书（无外部依赖，纯手写 PDF 结构）。
// 用法：node packages/app-ios/scripts/build-sample-pdf.mjs
import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const pages = [
  "Shudeng PDF Sample - Page One",
  "Shudeng PDF Sample - Page Two",
  "Shudeng PDF Sample - Page Three",
];

const objects = [];
const add = (body) => objects.push(body);
const catalogId = add("<< /Type /Catalog /Pages 2 0 R >>");
const pagesId = add("");
const fontId = add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>");
const pageIds = [];

for (const text of pages) {
  const stream = `BT /F1 18 Tf 72 720 Td (${text}) Tj ET`;
  const contentId = add(`<< /Length ${stream.length} >>\nstream\n${stream}\nendstream`);
  pageIds.push(
    add(
      `<< /Type /Page /Parent ${pagesId} 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 ${fontId} 0 R >> >> /Contents ${contentId} 0 R >>`,
    ),
  );
}

objects[pagesId - 1] =
  `<< /Type /Pages /Kids [${pageIds.map((id) => `${id} 0 R`).join(" ")}] /Count ${pageIds.length} >>`;

let pdf = "%PDF-1.4\n";
const offsets = [];
objects.forEach((body, index) => {
  offsets.push(pdf.length);
  pdf += `${index + 1} 0 obj\n${body}\nendobj\n`;
});
const xrefOffset = pdf.length;
pdf += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
for (const offset of offsets) pdf += `${String(offset).padStart(10, "0")} 00000 n \n`;
pdf += `trailer\n<< /Size ${objects.length + 1} /Root ${catalogId} 0 R >>\nstartxref\n${xrefOffset}\n%%EOF\n`;

const target = join(
  dirname(fileURLToPath(import.meta.url)),
  "..",
  "Shudeng",
  "Resources",
  "ui-test-sample-pdf.pdf",
);
writeFileSync(target, Buffer.from(pdf, "latin1"));
console.log(`wrote ${target} (${pages.length} pages)`);
