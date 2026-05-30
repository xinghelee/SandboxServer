import Foundation
#if SWIFT_PACKAGE
import SandboxServerAPI
#endif

/// Grades an app binary's static hardening into a scored report — the "IPA security check" view.
/// Pure static analysis over the Mach-O facts (`MachOInspector`) plus the provisioning entitlements
/// (`ProvisioningInspector`); no third-party deps. Each check carries a weight; the score is the
/// fraction of applicable weight that passed. Informational checks (weight 0) never affect the score.
enum SecurityInspector {
    /// status: "pass" | "fail" | "info" | "unknown" — drives the console chip color.
    struct Check: Encodable, Sendable {
        let id: String
        let title: String
        let status: String
        let detail: String
        let weight: Int
    }

    struct Report: Encodable, Sendable {
        let supported: Bool
        let arch: String?       // which slice was graded
        let score: Int          // 0–100 over applicable (non-unknown, weighted) checks
        let grade: String       // A / B / C / D
        let checks: [Check]
    }

    static func evaluate(macho: MachOInspector.Info, provisioning: ProvisioningInspector.Info) -> Report {
        guard macho.supported, let slice = primarySlice(macho.slices) else {
            return Report(supported: false, arch: nil, score: 0, grade: "—", checks: [])
        }

        var checks: [Check] = []

        // MH_PIE → ASLR. The single most important mitigation.
        checks.append(boolCheck(
            id: "pie", title: "PIE / ASLR", value: slice.pie, weight: 25,
            pass: "Position-independent — address space layout is randomized.",
            fail: "Not position-independent — no ASLR (fixed load address).",
            unknown: "Could not read the Mach-O flags."))

        // Stack canary (a `stack_chk` symbol).
        checks.append(boolCheck(
            id: "stackCanary", title: "Stack canary", value: slice.stackCanary, weight: 20,
            pass: "Stack-protector symbols present — stack-smashing is detected.",
            fail: "No stack-protector symbols found.",
            unknown: "No symbol table to inspect."))

        // ARC (an `_objc_release` symbol).
        checks.append(boolCheck(
            id: "arc", title: "ARC", value: slice.arc, weight: 15,
            pass: "Automatic Reference Counting symbols present.",
            fail: "No ARC symbols found (manual retain/release).",
            unknown: "No symbol table to inspect."))

        // Code signature load command.
        checks.append(boolCheck(
            id: "codeSignature", title: "Code signature", value: slice.codeSignature, weight: 15,
            pass: "Has an embedded code signature.",
            fail: "No LC_CODE_SIGNATURE — unsigned binary.",
            unknown: "Could not read the load commands."))

        // get-task-allow (debuggable) — from the provisioning entitlements. PASS means NOT debuggable.
        let debuggable = getTaskAllow(provisioning)
        switch debuggable {
        case .some(true):
            checks.append(Check(id: "getTaskAllow", title: "Not debuggable", status: "fail",
                detail: "get-task-allow is true — a debugger can attach (development build).", weight: 25))
        case .some(false):
            checks.append(Check(id: "getTaskAllow", title: "Not debuggable", status: "pass",
                detail: "get-task-allow is false — debugger attachment is disallowed.", weight: 25))
        case .none:
            checks.append(Check(id: "getTaskAllow", title: "Not debuggable", status: "unknown",
                detail: "No provisioning entitlements to read (Simulator / App Store build).", weight: 25))
        }

        // Informational (weight 0) — context, not scored.
        checks.append(Check(
            id: "encryption", title: "FairPlay encryption",
            status: slice.encrypted ? "info" : "info",
            detail: slice.encrypted
                ? "Binary is FairPlay-encrypted (App Store build)."
                : "Not FairPlay-encrypted (Simulator / development / decrypted).",
            weight: 0))
        if slice.restrict == true {
            checks.append(Check(id: "restrict", title: "__RESTRICT segment", status: "info",
                detail: "Has a __RESTRICT segment (anti-debug hardening).", weight: 0))
        }

        let (score, grade) = grade(checks)
        return Report(supported: true, arch: "\(slice.cpuType) \(slice.cpuSubtype)",
                      score: score, grade: grade, checks: checks)
    }

    // MARK: - Helpers

    /// Prefer a fully-parsed arm64 slice (real device arch), else the first slice with hardening data,
    /// else the first slice at all.
    private static func primarySlice(_ slices: [MachOInspector.Slice]) -> MachOInspector.Slice? {
        slices.first { $0.cpuType == "arm64" && $0.pie != nil }
            ?? slices.first { $0.pie != nil }
            ?? slices.first
    }

    private static func boolCheck(id: String, title: String, value: Bool?, weight: Int,
                                  pass: String, fail: String, unknown: String) -> Check {
        switch value {
        case .some(true):  return Check(id: id, title: title, status: "pass", detail: pass, weight: weight)
        case .some(false): return Check(id: id, title: title, status: "fail", detail: fail, weight: weight)
        case .none:        return Check(id: id, title: title, status: "unknown", detail: unknown, weight: weight)
        }
    }

    /// Reads `get-task-allow` from the provisioning entitlements, or nil when unavailable.
    private static func getTaskAllow(_ p: ProvisioningInspector.Info) -> Bool? {
        guard p.present, case .object(let ent)? = p.entitlements,
              case .bool(let v)? = ent["get-task-allow"] else { return nil }
        return v
    }

    /// Score = passed weight / (passed + failed weight) × 100, ignoring unknown/info. Grade by band.
    private static func grade(_ checks: [Check]) -> (Int, String) {
        var got = 0, total = 0
        for c in checks where c.weight > 0 {
            if c.status == "pass" { got += c.weight; total += c.weight }
            else if c.status == "fail" { total += c.weight }
            // unknown → excluded from the denominator (don't punish what we can't see)
        }
        guard total > 0 else { return (0, "—") }
        let score = Int((Double(got) / Double(total) * 100).rounded())
        let grade = score >= 85 ? "A" : score >= 70 ? "B" : score >= 50 ? "C" : "D"
        return (score, grade)
    }
}
