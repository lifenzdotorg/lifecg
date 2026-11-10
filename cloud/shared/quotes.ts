// Tracks which quotation marks are open at the end of a stretch of text, so a slide split can close
// them at the end of the slide and reopen them on the next (FORMAT.md splitting rule 4).

const CLOSE: Record<string, string> = { '“': '”', '"': '"', '‘': '’', "'": "'" };
const isLetter = (c: string | undefined) => !!c && /[\p{L}\p{N}]/u.test(c);
const isOpenContext = (c: string | undefined) => c === undefined || /[\s(\[—–“"‘'-]/.test(c);

export function scanQuotes(text: string, stack: string[] = []): string[] {
  const st = [...stack];
  const chars = [...text];
  for (let i = 0; i < chars.length; i++) {
    const c = chars[i];
    const prev = chars[i - 1];
    const next = chars[i + 1];
    switch (c) {
      case '“':
        st.push(c);
        break;
      case '”': {
        const j = st.lastIndexOf('“');
        if (j >= 0) st.splice(j, 1);
        break;
      }
      case '"':
        if (st[st.length - 1] === '"') st.pop();
        else if (st.includes('"') && !isOpenContext(prev)) st.splice(st.lastIndexOf('"'), 1);
        else st.push('"');
        break;
      case '‘':
        st.push(c);
        break;
      case '’':
        if (isLetter(prev) && isLetter(next)) break; // apostrophe
        if (st.includes('‘')) st.splice(st.lastIndexOf('‘'), 1);
        break;
      case "'":
        if (isLetter(prev) && isLetter(next)) break; // apostrophe (Jacob's)
        if (isOpenContext(prev) && next !== undefined && !/\s/.test(next)) st.push("'");
        else if (st.includes("'")) st.splice(st.lastIndexOf("'"), 1);
        break;
    }
  }
  return st;
}

export const closingFor = (stack: string[]) => [...stack].reverse().map((c) => CLOSE[c]).join('');
export const reopenFor = (stack: string[]) => stack.join('');
