#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

function fail(message) {
  process.stderr.write(`${message}\n`);
  process.exitCode = 1;
}

function readText(filePath) {
  return fs.readFileSync(filePath, 'utf8');
}

function readJson(filePath) {
  try {
    return JSON.parse(readText(filePath));
  } catch (error) {
    throw new Error(`Failed to parse JSON at ${filePath}: ${error instanceof Error ? error.message : String(error)}`);
  }
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function walkFiles(dirPath, predicate) {
  const entries = fs.readdirSync(dirPath, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const fullPath = path.join(dirPath, entry.name);
    if (entry.isDirectory()) {
      files.push(...walkFiles(fullPath, predicate));
      continue;
    }
    if (entry.isFile() && predicate(fullPath)) {
      files.push(fullPath);
    }
  }
  return files;
}

function scanBalanced(text, startIndex, openChar, closeChar) {
  let index = startIndex;
  let depth = 0;
  let inString = false;
  let inLineComment = false;
  let inBlockComment = false;
  let escaped = false;

  if (text[index] !== openChar) {
    throw new Error(`scanBalanced: expected '${openChar}' at index ${startIndex}`);
  }

  for (; index < text.length; index += 1) {
    const ch = text[index];
    const next = index + 1 < text.length ? text[index + 1] : '';

    if (inLineComment) {
      if (ch === '\n') inLineComment = false;
      continue;
    }
    if (inBlockComment) {
      if (ch === '*' && next === '/') {
        inBlockComment = false;
        index += 1;
      }
      continue;
    }

    if (!inString) {
      if (ch === '/' && next === '/') {
        inLineComment = true;
        index += 1;
        continue;
      }
      if (ch === '/' && next === '*') {
        inBlockComment = true;
        index += 1;
        continue;
      }
    }

    if (inString) {
      if (escaped) {
        escaped = false;
        continue;
      }
      if (ch === '\\') {
        escaped = true;
        continue;
      }
      if (ch === '"') {
        inString = false;
      }
      continue;
    }

    if (ch === '"') {
      inString = true;
      continue;
    }

    if (ch === openChar) {
      depth += 1;
      continue;
    }

    if (ch === closeChar) {
      depth -= 1;
      if (depth === 0) {
        return index;
      }
    }
  }

  throw new Error(`scanBalanced: unterminated '${openChar}...${closeChar}' starting at index ${startIndex}`);
}

function splitTopLevel(text, delimiterChar) {
  const parts = [];
  let start = 0;

  let parenDepth = 0;
  let bracketDepth = 0;
  let braceDepth = 0;
  let inString = false;
  let inLineComment = false;
  let inBlockComment = false;
  let escaped = false;

  for (let index = 0; index < text.length; index += 1) {
    const ch = text[index];
    const next = index + 1 < text.length ? text[index + 1] : '';

    if (inLineComment) {
      if (ch === '\n') inLineComment = false;
      continue;
    }
    if (inBlockComment) {
      if (ch === '*' && next === '/') {
        inBlockComment = false;
        index += 1;
      }
      continue;
    }

    if (!inString) {
      if (ch === '/' && next === '/') {
        inLineComment = true;
        index += 1;
        continue;
      }
      if (ch === '/' && next === '*') {
        inBlockComment = true;
        index += 1;
        continue;
      }
    }

    if (inString) {
      if (escaped) {
        escaped = false;
        continue;
      }
      if (ch === '\\') {
        escaped = true;
        continue;
      }
      if (ch === '"') {
        inString = false;
      }
      continue;
    }

    if (ch === '"') {
      inString = true;
      continue;
    }

    if (ch === '(') parenDepth += 1;
    else if (ch === ')') parenDepth -= 1;
    else if (ch === '[') bracketDepth += 1;
    else if (ch === ']') bracketDepth -= 1;
    else if (ch === '{') braceDepth += 1;
    else if (ch === '}') braceDepth -= 1;

    if (
      ch === delimiterChar &&
      parenDepth === 0 &&
      bracketDepth === 0 &&
      braceDepth === 0 &&
      !inString &&
      !inLineComment &&
      !inBlockComment
    ) {
      parts.push(text.slice(start, index));
      start = index + 1;
    }
  }

  parts.push(text.slice(start));
  return parts;
}

function findTopLevelColon(text) {
  let parenDepth = 0;
  let bracketDepth = 0;
  let braceDepth = 0;
  let inString = false;
  let inLineComment = false;
  let inBlockComment = false;
  let escaped = false;

  for (let index = 0; index < text.length; index += 1) {
    const ch = text[index];
    const next = index + 1 < text.length ? text[index + 1] : '';

    if (inLineComment) {
      if (ch === '\n') inLineComment = false;
      continue;
    }
    if (inBlockComment) {
      if (ch === '*' && next === '/') {
        inBlockComment = false;
        index += 1;
      }
      continue;
    }

    if (!inString) {
      if (ch === '/' && next === '/') {
        inLineComment = true;
        index += 1;
        continue;
      }
      if (ch === '/' && next === '*') {
        inBlockComment = true;
        index += 1;
        continue;
      }
    }

    if (inString) {
      if (escaped) {
        escaped = false;
        continue;
      }
      if (ch === '\\') {
        escaped = true;
        continue;
      }
      if (ch === '"') {
        inString = false;
      }
      continue;
    }

    if (ch === '"') {
      inString = true;
      continue;
    }

    if (ch === '(') parenDepth += 1;
    else if (ch === ')') parenDepth -= 1;
    else if (ch === '[') bracketDepth += 1;
    else if (ch === ']') bracketDepth -= 1;
    else if (ch === '{') braceDepth += 1;
    else if (ch === '}') braceDepth -= 1;

    if (ch === ':' && parenDepth === 0 && bracketDepth === 0 && braceDepth === 0) {
      return index;
    }
  }

  return -1;
}

function parseSwiftStringLiteral(expr) {
  const trimmed = expr.trim();
  if (!trimmed.startsWith('"')) return null;

  let out = '';
  let escaped = false;
  for (let index = 1; index < trimmed.length; index += 1) {
    const ch = trimmed[index];
    if (escaped) {
      out += ch;
      escaped = false;
      continue;
    }
    if (ch === '\\') {
      escaped = true;
      continue;
    }
    if (ch === '"') {
      // Only accept if the closing quote ends the expression (ignoring whitespace).
      const rest = trimmed.slice(index + 1).trim();
      if (rest.length > 0) return null;
      return out;
    }
    out += ch;
  }
  return null;
}

function parseBridgeMessageCalls(swiftText, filePath) {
  const calls = [];
  let index = 0;

  while (true) {
    const found = swiftText.indexOf('BridgeMessage(', index);
    if (found === -1) break;

    const openIndex = found + 'BridgeMessage'.length;
    if (swiftText[openIndex] !== '(') {
      index = found + 1;
      continue;
    }

    const closeIndex = scanBalanced(swiftText, openIndex, '(', ')');
    const argsText = swiftText.slice(openIndex + 1, closeIndex);
    const args = new Map();

    for (const part of splitTopLevel(argsText, ',')) {
      const trimmed = part.trim();
      if (trimmed.length === 0) continue;
      const colonIndex = findTopLevelColon(trimmed);
      if (colonIndex === -1) continue;
      const name = trimmed.slice(0, colonIndex).trim();
      const value = trimmed.slice(colonIndex + 1).trim();
      if (name.length === 0) continue;
      args.set(name, value);
    }

    const typeExpr = args.get('type');
    const typeLiteral = typeExpr ? parseSwiftStringLiteral(typeExpr) : null;

    if (typeLiteral) {
      calls.push({
        filePath,
        startIndex: found,
        endIndex: closeIndex + 1,
        type: typeLiteral,
        payloadExpr: args.get('payload') ?? null,
        callbackIdExpr: args.get('callbackId') ?? null,
      });
    }

    index = closeIndex + 1;
  }

  return calls;
}

function extractDictionaryLiteralKeys(expr) {
  const trimmed = expr.trim();
  if (!trimmed.startsWith('[')) return null;

  const endIndex = scanBalanced(trimmed, 0, '[', ']');
  const inner = trimmed.slice(1, endIndex);
  const keys = new Set();

  for (const entry of splitTopLevel(inner, ',')) {
    const trimmedEntry = entry.trim();
    if (trimmedEntry.length === 0) continue;
    if (trimmedEntry === ':') continue; // [:]

    const colonIndex = findTopLevelColon(trimmedEntry);
    if (colonIndex === -1) continue;
    const keyExpr = trimmedEntry.slice(0, colonIndex).trim();
    const key = parseSwiftStringLiteral(keyExpr);
    if (key) keys.add(key);
  }

  return keys;
}

function findLastDictionaryAssignment(swiftText, variableName, beforeIndex) {
  const head = swiftText.slice(0, beforeIndex);
  const pattern = new RegExp(String.raw`(?:let|var)\s+${escapeRegExp(variableName)}\b[^=]*=\s*\[`, 'g');
  let lastMatch = null;

  for (const match of head.matchAll(pattern)) {
    lastMatch = match;
  }
  if (!lastMatch) return null;

  const literalStart = (lastMatch.index ?? 0) + lastMatch[0].length - 1; // points to '['
  if (swiftText[literalStart] !== '[') return null;
  const literalEnd = scanBalanced(swiftText, literalStart, '[', ']');
  const literalText = swiftText.slice(literalStart, literalEnd + 1);
  return {
    startIndex: lastMatch.index ?? 0,
    literalStartIndex: literalStart,
    literalEndIndex: literalEnd,
    literalText,
  };
}

function findBracketAssignments(text, variableName) {
  const pattern = new RegExp(String.raw`${escapeRegExp(variableName)}\s*\[\s*"([^"]+)"\s*\]\s*=`, 'g');
  const keys = new Set();
  for (const match of text.matchAll(pattern)) {
    keys.add(match[1]);
  }
  return keys;
}

function resolvePayloadKeys(call, swiftText) {
  const payloadExpr = call.payloadExpr;
  if (!payloadExpr) return { keys: new Set(), unresolved: false };

  const trimmed = payloadExpr.trim();
  if (trimmed === 'nil') return { keys: new Set(), unresolved: false };

  const literalKeys = extractDictionaryLiteralKeys(trimmed);
  if (literalKeys) return { keys: literalKeys, unresolved: false };

  const identMatch = trimmed.match(/^([A-Za-z_][A-Za-z0-9_]*)$/);
  if (!identMatch) return { keys: new Set(), unresolved: true };

  const name = identMatch[1];
  const assignment = findLastDictionaryAssignment(swiftText, name, call.startIndex);
  const initKeys = assignment ? extractDictionaryLiteralKeys(assignment.literalText) ?? new Set() : new Set();
  const assignedKeys = findBracketAssignments(swiftText.slice(assignment?.startIndex ?? 0, call.startIndex), name);

  return {
    keys: new Set([...initKeys, ...assignedKeys]),
    unresolved: !assignment && initKeys.size === 0 && assignedKeys.size === 0,
  };
}

function extractWebSwiftToWebTypes(webBridgeText) {
  const match = webBridgeText.match(/SWIFT_TO_WEB_MESSAGE_TYPES\s*=\s*\[(?<body>[\s\S]*?)\]\s*as\s*const/);
  if (!match || !match.groups?.body) {
    return null;
  }

  const body = match.groups.body;
  const types = new Set();
  for (const entry of body.matchAll(/['"]([^'"]+)['"]/g)) {
    types.add(entry[1]);
  }
  return types;
}

function setDiff(a, b) {
  const onlyA = [];
  for (const value of a) if (!b.has(value)) onlyA.push(value);
  const onlyB = [];
  for (const value of b) if (!a.has(value)) onlyB.push(value);
  return { onlyA: onlyA.sort(), onlyB: onlyB.sort() };
}

function sorted(values) {
  return [...values].sort();
}

function main() {
  const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
  const contractPaths = [
    path.join(repoRoot, 'docs', 'contracts', 'bridge.v1.json'),
    path.join(repoRoot, 'docs', 'contracts', 'bridge.v2.json'),
  ].filter((p) => fs.existsSync(p));
  const webBridgePath = path.join(repoRoot, 'Web', 'src', 'types', 'bridge.ts');
  const sourcesDir = path.join(repoRoot, 'Sources');

  if (contractPaths.length === 0) {
    throw new Error('No bridge contract files found.');
  }

  const messages = {};
  for (const contractPath of contractPaths) {
    const contract = readJson(contractPath);
    const contractMessages = contract?.swiftToWeb?.messages;
    if (!contractMessages || typeof contractMessages !== 'object') {
      throw new Error(`Contract missing swiftToWeb.messages: ${contractPath}`);
    }

    for (const [type, spec] of Object.entries(contractMessages)) {
      if (messages[type]) {
        fail(`Duplicate bridge message "${type}" across contracts.`);
        continue;
      }
      messages[type] = spec;
    }
  }

  const contractTypes = new Set(Object.keys(messages));
  if (!contractTypes.has('callback')) {
    fail('Contract must include "callback" message type.');
  }

  const webBridgeText = readText(webBridgePath);
  const webTypes = extractWebSwiftToWebTypes(webBridgeText);
  if (!webTypes) {
    fail(`Web bridge is missing SWIFT_TO_WEB_MESSAGE_TYPES (required for contract tests): ${webBridgePath}`);
  } else {
    const diff = setDiff(contractTypes, webTypes);
    if (diff.onlyA.length > 0 || diff.onlyB.length > 0) {
      fail(`Web SWIFT_TO_WEB_MESSAGE_TYPES does not match contract:`);
      if (diff.onlyA.length > 0) fail(`  Missing in Web: ${diff.onlyA.join(', ')}`);
      if (diff.onlyB.length > 0) fail(`  Extra in Web: ${diff.onlyB.join(', ')}`);
    }
  }

  const swiftFiles = walkFiles(sourcesDir, (p) => p.endsWith('.swift'));
  const calls = [];
  for (const filePath of swiftFiles) {
    const text = readText(filePath);
    calls.push(...parseBridgeMessageCalls(text, path.relative(repoRoot, filePath)));
  }

  const swiftTypes = new Set(calls.map((c) => c.type));
  const typeDiff = setDiff(contractTypes, swiftTypes);
  if (typeDiff.onlyA.length > 0 || typeDiff.onlyB.length > 0) {
    fail(`Swift BridgeMessage types do not match contract:`);
    if (typeDiff.onlyA.length > 0) fail(`  Missing in Swift: ${typeDiff.onlyA.join(', ')}`);
    if (typeDiff.onlyB.length > 0) fail(`  Extra in Swift: ${typeDiff.onlyB.join(', ')}`);
  }

  // Per-type payload contract validation.
  const byType = new Map();
  for (const call of calls) {
    const list = byType.get(call.type) ?? [];
    list.push(call);
    byType.set(call.type, list);
  }

  for (const type of sorted(contractTypes)) {
    const spec = messages[type];
    if (!spec || typeof spec !== 'object') {
      fail(`Contract entry for "${type}" must be an object.`);
      continue;
    }

    const requiredKeys = Array.isArray(spec.requiredPayloadKeys) ? spec.requiredPayloadKeys : null;
    const optionalKeys = Array.isArray(spec.optionalPayloadKeys) ? spec.optionalPayloadKeys : [];
    const requiresCallbackId = spec.requiredCallbackId === true;

    if (!requiredKeys) {
      fail(`Contract entry for "${type}" missing requiredPayloadKeys array.`);
      continue;
    }

    const typeCalls = byType.get(type) ?? [];
    if (typeCalls.length === 0) {
      fail(`No Swift BridgeMessage call sites found for contract type "${type}".`);
      continue;
    }

    const unionKeys = new Set();
    for (const call of typeCalls) {
      const filePath = path.join(repoRoot, call.filePath);
      const swiftText = readText(filePath);
      const resolved = resolvePayloadKeys(call, swiftText);

      for (const key of resolved.keys) unionKeys.add(key);

      const missingRequired = requiredKeys.filter((key) => !resolved.keys.has(key));
      if (missingRequired.length > 0) {
        fail(
          `Swift BridgeMessage("${type}") missing required payload keys: ${missingRequired.join(
            ', '
          )} (${call.filePath})`
        );
      }

      if (resolved.unresolved && requiredKeys.length > 0) {
        fail(
          `Swift BridgeMessage("${type}") payload could not be statically analyzed (expected dict literal or simple var): (${call.filePath})`
        );
      }

      if (requiresCallbackId) {
        if (!call.callbackIdExpr || call.callbackIdExpr.trim() === 'nil') {
          fail(`Swift BridgeMessage("${type}") missing required callbackId (${call.filePath})`);
        }
      }
    }

    const missingOptional = optionalKeys.filter((key) => !unionKeys.has(key));
    if (missingOptional.length > 0) {
      fail(`Swift BridgeMessage("${type}") missing optional payload keys referenced by contract: ${missingOptional.join(', ')}`);
    }
  }
}

try {
  main();
} catch (error) {
  fail(error instanceof Error ? error.message : String(error));
}
