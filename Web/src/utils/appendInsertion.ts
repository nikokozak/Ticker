export interface AppendInsertion {
  from: number;
  insert: string;
  insertedEnd: number;
}

export function computeAppendInsertion(docLength: number, fragment: string): AppendInsertion {
  const from = Math.max(0, Math.floor(docLength));
  const separator = from > 0 ? '\n\n' : '';
  const insert = `${separator}${fragment}`;

  return {
    from,
    insert,
    insertedEnd: from + insert.length,
  };
}
