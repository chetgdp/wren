// Runs in the offscreen document: fetch a PDF's bytes, extract markdown with
// the vendored pdf-inspector wasm build, and convert it to sentence blocks.
// The wasm (~5MB) loads lazily on the first PDF and stays cached until Chrome
// reaps the document.

import { mdToBlocks } from "./md2blocks.js";

let wasmReady = null;

function ensureWasm() {
  if (!wasmReady)
    wasmReady = import("./vendor/pdf-inspector/pdf_inspector_wasm.js")
      .then(async (mod) => {
        await mod.default(
          chrome.runtime.getURL("vendor/pdf-inspector/pdf_inspector_wasm_bg.wasm")
        );
        return mod;
      })
      .catch((e) => {
        wasmReady = null; // a failed init shouldn't poison later attempts
        throw e;
      });
  return wasmReady;
}

// The %PDF- marker may sit after a BOM or junk prologue; the spec allows it
// anywhere in the first 1024 bytes.
function looksLikePdf(bytes) {
  const head = new TextDecoder("latin1").decode(bytes.subarray(0, 1024));
  return head.includes("%PDF-");
}

export async function extractPdf(url) {
  const res = await fetch(url, { credentials: "include" });
  if (!res.ok) return { error: `fetch failed (${res.status})` };
  const bytes = new Uint8Array(await res.arrayBuffer());
  if (!looksLikePdf(bytes)) return { error: "not a PDF" };
  const mod = await ensureWasm();
  const result = mod.processPdf(bytes, { profile: "compact" });
  if (!result.markdown || result.pdfType === "Scanned" || result.pdfType === "ImageBased")
    return {
      pdfType: result.pdfType,
      error: "This PDF has no text layer to read. It needs OCR.",
    };
  const blocks = mdToBlocks(result.markdown);
  if (!blocks.length)
    return { pdfType: result.pdfType, error: "No readable text found in this PDF." };
  if (result.pagesNeedingOcr.length)
    blocks.unshift(
      `Note: skipping ${result.pagesNeedingOcr.length} scanned ` +
        `page${result.pagesNeedingOcr.length === 1 ? "" : "s"} of ${result.pageCount}.`
    );
  return { blocks, pdfType: result.pdfType, title: result.title ?? null };
}
