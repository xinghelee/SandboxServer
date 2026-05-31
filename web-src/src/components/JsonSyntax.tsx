type JsonTokenKind = 'plain' | 'key' | 'string' | 'number' | 'boolean' | 'null' | 'punct';

export function isJsonText(text: string): boolean {
  const trimmed = text.trim();
  if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) return false;
  try {
    JSON.parse(trimmed);
    return true;
  } catch {
    return false;
  }
}

function tokenizeJson(text: string): Array<{ kind: JsonTokenKind; text: string }> {
  const tokens: Array<{ kind: JsonTokenKind; text: string }> = [];
  const re = /("(?:\\.|[^"\\])*"(?=\s*:))|("(?:\\.|[^"\\])*")|\b(true|false)\b|\bnull\b|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?|[{}\[\],:]/g;
  let last = 0;
  let match: RegExpExecArray | null;
  while ((match = re.exec(text))) {
    if (match.index > last) tokens.push({ kind: 'plain', text: text.slice(last, match.index) });
    const raw = match[0];
    let kind: Exclude<JsonTokenKind, 'plain'>;
    if (match[1]) kind = 'key';
    else if (match[2]) kind = 'string';
    else if (raw === 'true' || raw === 'false') kind = 'boolean';
    else if (raw === 'null') kind = 'null';
    else if (/^[{}\[\],:]$/.test(raw)) kind = 'punct';
    else kind = 'number';
    tokens.push({ kind, text: raw });
    last = re.lastIndex;
  }
  if (last < text.length) tokens.push({ kind: 'plain', text: text.slice(last) });
  return tokens;
}

export function JsonSyntax({ text }: { text: string }) {
  return (
    <>
      {tokenizeJson(text).map((token, index) => (
        <span key={index} class={token.kind === 'plain' ? undefined : `json-token-${token.kind}`}>
          {token.text}
        </span>
      ))}
    </>
  );
}
