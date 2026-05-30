// Static hardening grader — the TS twin of Sources/.../BundlePlugin/SecurityInspector.swift.
// Same checks, same weights, same A/B/C/D bands, so an uploaded-IPA grade matches the device grade.

import type { MachOInfo, MachOSlice, SecurityCheck, SecurityReport, SecurityStatus } from '../../api/types';

interface Entitlements {
  [key: string]: unknown;
}

export function evaluateSecurity(macho: MachOInfo, entitlements: Entitlements | null): SecurityReport {
  const slice = primarySlice(macho.slices);
  if (!macho.supported || !slice) {
    return { supported: false, arch: null, score: 0, grade: '—', checks: [] };
  }

  const checks: SecurityCheck[] = [];

  checks.push(boolCheck('pie', 'PIE / ASLR', slice.pie, 25,
    'Position-independent — address space layout is randomized.',
    'Not position-independent — no ASLR (fixed load address).',
    'Could not read the Mach-O flags.'));

  checks.push(boolCheck('stackCanary', 'Stack canary', slice.stackCanary, 20,
    'Stack-protector symbols present — stack-smashing is detected.',
    'No stack-protector symbols found.',
    'No symbol table to inspect.'));

  checks.push(boolCheck('arc', 'ARC', slice.arc, 15,
    'Automatic Reference Counting symbols present.',
    'No ARC symbols found (manual retain/release).',
    'No symbol table to inspect.'));

  checks.push(boolCheck('codeSignature', 'Code signature', slice.codeSignature, 15,
    'Has an embedded code signature.',
    'No LC_CODE_SIGNATURE — unsigned binary.',
    'Could not read the load commands.'));

  const debuggable = getTaskAllow(entitlements);
  if (debuggable === true) {
    checks.push(check('getTaskAllow', 'Not debuggable', 'fail',
      'get-task-allow is true — a debugger can attach (development build).', 25));
  } else if (debuggable === false) {
    checks.push(check('getTaskAllow', 'Not debuggable', 'pass',
      'get-task-allow is false — debugger attachment is disallowed.', 25));
  } else {
    checks.push(check('getTaskAllow', 'Not debuggable', 'unknown',
      'No provisioning entitlements to read (Simulator / App Store build).', 25));
  }

  checks.push(check('encryption', 'FairPlay encryption', 'info',
    slice.encrypted
      ? 'Binary is FairPlay-encrypted (App Store build).'
      : 'Not FairPlay-encrypted (Simulator / development / decrypted).',
    0));
  if (slice.restrict === true) {
    checks.push(check('restrict', '__RESTRICT segment', 'info',
      'Has a __RESTRICT segment (anti-debug hardening).', 0));
  }

  const { score, grade } = gradeChecks(checks);
  return { supported: true, arch: `${slice.cpuType} ${slice.cpuSubtype}`, score, grade, checks };
}

function primarySlice(slices: MachOSlice[]): MachOSlice | undefined {
  return (
    slices.find((s) => s.cpuType === 'arm64' && s.pie != null) ??
    slices.find((s) => s.pie != null) ??
    slices[0]
  );
}

function boolCheck(
  id: string, title: string, value: boolean | null | undefined, weight: number,
  pass: string, fail: string, unknown: string,
): SecurityCheck {
  if (value === true) return check(id, title, 'pass', pass, weight);
  if (value === false) return check(id, title, 'fail', fail, weight);
  return check(id, title, 'unknown', unknown, weight);
}

function check(id: string, title: string, status: SecurityStatus, detail: string, weight: number): SecurityCheck {
  return { id, title, status, detail, weight };
}

function getTaskAllow(ent: Entitlements | null): boolean | null {
  if (!ent) return null;
  const v = ent['get-task-allow'];
  return typeof v === 'boolean' ? v : null;
}

function gradeChecks(checks: SecurityCheck[]): { score: number; grade: string } {
  let got = 0;
  let total = 0;
  for (const c of checks) {
    if (c.weight <= 0) continue;
    if (c.status === 'pass') {
      got += c.weight;
      total += c.weight;
    } else if (c.status === 'fail') {
      total += c.weight;
    }
  }
  if (total === 0) return { score: 0, grade: '—' };
  const score = Math.round((got / total) * 100);
  const grade = score >= 85 ? 'A' : score >= 70 ? 'B' : score >= 50 ? 'C' : 'D';
  return { score, grade };
}
