import { convertDatabase } from './convertDatabase';

const [source, output] = process.argv.slice(2);
if (!source || !output) {
  console.error('Usage: npm run convert-doc-json -- SOURCE_DB OUTPUT_DB');
  process.exitCode = 2;
} else {
  try {
    const report = convertDatabase(source, output);
    for (const row of report) {
      console.log(
        `${row.streamId}: converted; ${row.spansKept} spans kept; `
        + `${row.legacyRowsFoldedIn} legacy rows folded in`,
      );
    }
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  }
}
