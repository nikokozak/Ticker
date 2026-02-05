#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

import YAML from 'yaml';

function fail(message) {
  process.stderr.write(`${message}\n`);
  process.exitCode = 1;
}

function isNonEmptyString(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, '../..');
const defaultSpecPath = path.join(repoRoot, 'docs', 'contracts', 'ticker-proxy.openapi.v1.yaml');
const specPath = process.argv[2] ? path.resolve(repoRoot, process.argv[2]) : defaultSpecPath;

if (!fs.existsSync(specPath)) {
  fail(`OpenAPI spec not found: ${specPath}`);
  process.exit(1);
}

let spec;
try {
  spec = YAML.parse(fs.readFileSync(specPath, 'utf8'));
} catch (error) {
  fail(
    `Failed to parse YAML at ${specPath}: ${error instanceof Error ? error.message : String(error)}`
  );
  process.exit(1);
}

if (!spec || typeof spec !== 'object') {
  fail('OpenAPI spec must be a mapping/object at top-level');
  process.exit(1);
}

if (!isNonEmptyString(spec.openapi)) {
  fail('Missing required field: openapi');
}

if (!spec.info || typeof spec.info !== 'object') {
  fail('Missing required field: info');
} else {
  if (!isNonEmptyString(spec.info.title)) fail('Missing required field: info.title');
  if (!isNonEmptyString(spec.info.version)) fail('Missing required field: info.version');
}

if (!spec.paths || typeof spec.paths !== 'object' || Object.keys(spec.paths).length === 0) {
  fail('Missing required field: paths');
}

const requestIdSchema = spec?.components?.headers?.['X-Ticker-Request-Id']?.schema;
if (requestIdSchema && typeof requestIdSchema === 'object') {
  if (requestIdSchema.type !== 'string') {
    fail("X-Ticker-Request-Id schema.type must be 'string'");
  }
  if (requestIdSchema.format === 'uuid') {
    fail('X-Ticker-Request-Id must not require uuid format');
  }
}

if (process.exitCode && process.exitCode !== 0) {
  process.exit(process.exitCode);
}

process.stdout.write(
  `OpenAPI OK: ${specPath} (openapi=${spec.openapi}, title=${spec.info?.title}, version=${spec.info?.version})\n`
);
