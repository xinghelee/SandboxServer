// Orchestrates a browser-side IPA analysis: read the zip → locate the primary Payload/<app>.app →
// parse Info.plist (summary + privacy), the Mach-O executable (arch + hardening), and the embedded
// provisioning entitlements (get-task-allow) → grade security. Produces a report whose pieces reuse
// the same wire types the device Bundle panel renders, so one set of UI components shows both.

import type {
  BundleSummary,
  BundlePrivacy,
  UsageDescription,
  ATSInfo,
  MachOInfo as MachOInfoWire,
  SecurityReport,
} from '../../api/types';
import { readCentralDirectory, extractEntry, type ZipEntry } from './zip';
import { parsePlist, type PlistValue } from './plist';
import { inspectMachO } from './macho';
import { evaluateSecurity } from './security';

export interface IpaReport {
  fileName: string;
  fileSize: number;
  appPath: string; // e.g. Payload/Foo.app
  summary: BundleSummary;
  macho: MachOInfoWire;
  security: SecurityReport;
  privacy: BundlePrivacy;
  warnings: string[];
}

const INFO_PLIST_RE = /^Payload\/[^/]+\.app\/Info\.plist$/;

export async function analyzeIpa(file: File): Promise<IpaReport> {
  const buf = new Uint8Array(await file.arrayBuffer());
  const entries = readCentralDirectory(buf);
  const warnings: string[] = [];

  // The primary app is the shallowest Payload/<name>.app/Info.plist.
  const infoEntry = entries
    .filter((e) => INFO_PLIST_RE.test(e.name))
    .sort((a, b) => a.name.length - b.name.length)[0];
  if (!infoEntry) throw new Error('No Payload/<App>.app/Info.plist found — is this an IPA?');

  const appPath = infoEntry.name.slice(0, infoEntry.name.lastIndexOf('/')); // Payload/Foo.app
  const info = asObject(parsePlist(await extractEntry(buf, infoEntry)));

  const summary = buildSummary(info, appPath, buf, entries, warnings);
  const privacy = buildPrivacy(info);

  // Mach-O of the main executable.
  let macho: MachOInfoWire = { supported: false, fileSize: 0, fat: false, slices: [] };
  const exeName = str(info['CFBundleExecutable']);
  if (exeName) {
    const exeEntry = entries.find((e) => e.name === `${appPath}/${exeName}`);
    if (exeEntry) {
      try {
        const exeBytes = await extractEntry(buf, exeEntry);
        macho = inspectMachO(exeBytes, `${appPath}/${exeName}`) as MachOInfoWire;
      } catch (e) {
        warnings.push(`Could not read the executable: ${e instanceof Error ? e.message : String(e)}`);
      }
    } else {
      warnings.push(`Executable "${exeName}" listed in Info.plist was not found in the archive.`);
    }
  } else {
    warnings.push('Info.plist has no CFBundleExecutable.');
  }

  // Entitlements (for get-task-allow) from embedded.mobileprovision — best-effort.
  const entitlements = await readEntitlements(buf, entries, appPath, warnings);
  const security = evaluateSecurity(macho, entitlements);

  return { fileName: file.name, fileSize: file.size, appPath, summary, macho, security, privacy, warnings };
}

// --- Info.plist → summary ---

function buildSummary(
  info: Record<string, PlistValue>,
  appPath: string,
  buf: Uint8Array,
  entries: ZipEntry[],
  warnings: string[],
): BundleSummary {
  const families = (asArray(info['UIDeviceFamily']) ?? [])
    .map((v) => (typeof v === 'number' ? v : Number(v)))
    .map((code) =>
      code === 1 ? 'iPhone' : code === 2 ? 'iPad' : code === 3 ? 'tv' : code === 4 ? 'watch' : `family(${code})`,
    );

  // Best-effort icon: a CFBundleIconFiles base name → the largest matching PNG in the app dir.
  const icon = extractIcon(info, appPath, buf, entries, warnings);

  return {
    supported: true,
    bundleId: str(info['CFBundleIdentifier']),
    bundlePath: appPath,
    displayName: str(info['CFBundleDisplayName']) ?? str(info['CFBundleName']),
    shortVersion: str(info['CFBundleShortVersionString']),
    build: str(info['CFBundleVersion']),
    minimumOSVersion: str(info['MinimumOSVersion']) ?? str(info['LSMinimumSystemVersion']),
    platform: str(info['DTPlatformName']),
    deviceFamilies: families,
    sdkName: str(info['DTSDKName']),
    icon,
  };
}

function extractIcon(
  info: Record<string, PlistValue>,
  appPath: string,
  buf: Uint8Array,
  entries: ZipEntry[],
  warnings: string[],
): string | undefined {
  try {
    const icons = asObject(info['CFBundleIcons']);
    const primary = asObject(icons['CFBundlePrimaryIcon']);
    const files = asArray(primary['CFBundleIconFiles']);
    const base = files && files.length ? str(files[files.length - 1]) : undefined;
    if (!base) return undefined;
    // Match Payload/Foo.app/<base>*.png, prefer the largest (≈ highest @Nx).
    const candidates = entries
      .filter((e) => e.name.startsWith(`${appPath}/${base}`) && e.name.toLowerCase().endsWith('.png'))
      .sort((a, b) => b.uncompressedSize - a.uncompressedSize);
    const hit = candidates[0];
    if (!hit) return undefined;
    // Note: bundled PNGs are CgBI-optimized (Apple's premultiplied/BGRA variant); browsers can't
    // always decode them. Icon preview is skipped for uploaded IPAs (best-effort, see helper).
    return pngDataUrlSync(buf, hit, warnings);
  } catch {
    return undefined;
  }
}

function pngDataUrlSync(_buf: Uint8Array, _entry: ZipEntry, warnings: string[]): string | undefined {
  // Extraction is async (deflate); to keep summary synchronous we skip inline icon decoding for
  // uploaded IPAs and note it. (The device path already renders the runtime icon.)
  warnings.push('App icon preview is skipped for uploaded IPAs (bundled PNGs are CgBI-encoded).');
  return undefined;
}

// --- Info.plist → privacy ---

function buildPrivacy(info: Record<string, PlistValue>): BundlePrivacy {
  const usageDescriptions: UsageDescription[] = [];
  for (const key of Object.keys(info).sort()) {
    if (!key.endsWith('UsageDescription')) continue;
    usageDescriptions.push({ key, purpose: str(info[key]) ?? '' });
  }

  const urlSchemes: string[] = (asArray(info['CFBundleURLTypes']) ?? []).flatMap((t) => {
    const schemes = asArray(asObject(t)['CFBundleURLSchemes']);
    return (schemes ?? []).map((s) => str(s) ?? '').filter(Boolean);
  });

  const backgroundModes = (asArray(info['UIBackgroundModes']) ?? []).map((m) => str(m) ?? '').filter(Boolean);

  let ats: ATSInfo | null = null;
  const atsDict = info['NSAppTransportSecurity'];
  if (atsDict && typeof atsDict === 'object' && !Array.isArray(atsDict)) {
    const d = atsDict as Record<string, PlistValue>;
    const domains = asObject(d['NSExceptionDomains']);
    ats = {
      allowsArbitraryLoads: d['NSAllowsArbitraryLoads'] === true,
      exceptionDomains: Object.keys(domains).sort(),
    };
  }

  return { usageDescriptions, urlSchemes, backgroundModes, ats };
}

// --- provisioning entitlements ---

async function readEntitlements(
  buf: Uint8Array,
  entries: ZipEntry[],
  appPath: string,
  warnings: string[],
): Promise<Record<string, unknown> | null> {
  const entry = entries.find((e) => e.name === `${appPath}/embedded.mobileprovision`);
  if (!entry) return null; // App Store IPAs have no embedded profile
  try {
    const blob = await extractEntry(buf, entry);
    const xml = sliceEmbeddedPlist(blob);
    if (!xml) return null;
    const plist = parsePlist(xml);
    const root = asObject(plist as PlistValue);
    const ent = root['Entitlements'];
    return ent && typeof ent === 'object' && !Array.isArray(ent) ? (ent as Record<string, unknown>) : null;
  } catch (e) {
    warnings.push(`Could not read provisioning entitlements: ${e instanceof Error ? e.message : String(e)}`);
    return null;
  }
}

/** Slice the XML plist out of a CMS-signed mobileprovision (same trick as the device side). */
function sliceEmbeddedPlist(blob: Uint8Array): Uint8Array | null {
  const text = latin1(blob);
  const start = text.indexOf('<?xml');
  const altStart = start < 0 ? text.indexOf('<plist') : start;
  const end = text.lastIndexOf('</plist>');
  if (altStart < 0 || end < 0 || altStart >= end) return null;
  return blob.subarray(altStart, end + '</plist>'.length);
}

// --- small typed helpers over PlistValue ---

function asObject(v: PlistValue | undefined): Record<string, PlistValue> {
  return v && typeof v === 'object' && !Array.isArray(v) && !('$date' in v) && !('$data' in v)
    ? (v as Record<string, PlistValue>)
    : {};
}

function asArray(v: PlistValue | undefined): PlistValue[] | undefined {
  return Array.isArray(v) ? v : undefined;
}

function str(v: PlistValue | undefined): string | undefined {
  return typeof v === 'string' ? v : undefined;
}

function latin1(bytes: Uint8Array): string {
  let s = '';
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    s += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return s;
}
