import Foundation
import PushupCore

/// A parsed command line.
public enum Command: Equatable {
    case replay(data: String, out: String, config: String?, model: String?, mode: ReplayMode, sessionConfig: String?)
    case features(data: String, out: String, config: String?, sessionConfig: String?)
    case synth(out: String, seed: UInt64)
    case synthOne(name: String, out: String, seed: UInt64)
    case help
}

/// The command line was malformed (exit code 2).
public struct UsageError: Error, Equatable {
    public let message: String
}

public enum CLI {
    public static let usage = """
    usage:
      pushup-eval replay   --data <dir> --out <predictions.json> [--config <config.json>] [--model <compiled .mlmodelc path>]
                           [--mode raw|session] [--session-config <session.json>]
      pushup-eval features --data <dir> --out <features.csv>     [--config <config.json>] [--session-config <session.json>]
      pushup-eval synth    --out <dir> [--seed <int>] [--only <name>]
      pushup-eval --help

    replay    run every recorded session in <dir> and write the counts as JSON. --mode raw (the default) feeds a
              bare counting pipeline. --mode session runs each take through the workout session engine the app
              uses (start hold, gates, finishing), adding started, startTime, endPhase and gateCounts per take.
              --session-config takes a JSON file of SessionConfig keys and needs --mode session. In session mode
              --config, if given, replaces the config's pipeline block.
    features  write one CSV row per frame with the 25 features and the heuristic label, then the session
              engine's torso_ratio, wrist_motion_ratio, raw_depth, gate_failure, session_phase, session_reps
    synth     write a small synthetic dataset (clearly labelled synthetic) for exercising the tools;
              with --only, write just one named session (clean-8: one clean set of 8 reps)

    exit codes: 0 success, 1 runtime failure, 2 usage error
    """

    public static let defaultSeed: UInt64 = 1

    /// Parses the arguments after the executable name.
    public static func parse(_ arguments: [String]) -> Result<Command, UsageError> {
        guard let first = arguments.first else {
            return .failure(UsageError(message: "missing subcommand"))
        }
        if first == "--help" || first == "-h" || first == "help" {
            return .success(.help)
        }
        let rest = Array(arguments.dropFirst())
        if rest.contains("--help") || rest.contains("-h") {
            return .success(.help)
        }

        switch first {
        case "replay":
            return options(rest, required: ["data", "out"], optional: ["config", "model", "mode", "session-config"]).flatMap { values in
                var mode = ReplayMode.raw
                if let text = values["mode"] {
                    guard let parsed = ReplayMode(rawValue: text) else {
                        return .failure(UsageError(message: "--mode must be raw or session, got '\(text)'"))
                    }
                    mode = parsed
                }
                if values["session-config"] != nil, mode != .session {
                    return .failure(UsageError(message: "--session-config needs --mode session"))
                }
                return .success(.replay(
                    data: values["data"]!, out: values["out"]!, config: values["config"], model: values["model"],
                    mode: mode, sessionConfig: values["session-config"]
                ))
            }
        case "features":
            return options(rest, required: ["data", "out"], optional: ["config", "session-config"]).map {
                .features(data: $0["data"]!, out: $0["out"]!, config: $0["config"], sessionConfig: $0["session-config"])
            }
        case "synth":
            return options(rest, required: ["out"], optional: ["seed", "only"]).flatMap { values in
                var seed = defaultSeed
                if let text = values["seed"] {
                    guard let parsed = UInt64(text) else {
                        return .failure(UsageError(message: "--seed must be a non-negative integer, got '\(text)'"))
                    }
                    seed = parsed
                }
                if let name = values["only"] {
                    guard SyntheticDataset.singleSessionNames.contains(name) else {
                        let known = SyntheticDataset.singleSessionNames.joined(separator: ", ")
                        return .failure(UsageError(message: "--only must be one of: \(known), got '\(name)'"))
                    }
                    return .success(.synthOne(name: name, out: values["out"]!, seed: seed))
                }
                return .success(.synth(out: values["out"]!, seed: seed))
            }
        default:
            return .failure(UsageError(message: "unknown subcommand '\(first)'"))
        }
    }

    /// Reads `--name value` and `--name=value` pairs, rejecting unknown,
    /// repeated and valueless options and requiring `required` ones.
    private static func options(
        _ arguments: [String],
        required: [String],
        optional: [String]
    ) -> Result<[String: String], UsageError> {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else {
                return .failure(UsageError(message: "unexpected argument '\(argument)'"))
            }
            var name = String(argument.dropFirst(2))
            var value: String?
            if let equals = name.firstIndex(of: "=") {
                value = String(name[name.index(after: equals)...])
                name = String(name[..<equals])
            }
            guard required.contains(name) || optional.contains(name) else {
                return .failure(UsageError(message: "unknown option '--\(name)'"))
            }
            if value == nil {
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                    return .failure(UsageError(message: "option '--\(name)' needs a value"))
                }
                value = arguments[index + 1]
                index += 1
            }
            guard values[name] == nil else {
                return .failure(UsageError(message: "option '--\(name)' given more than once"))
            }
            values[name] = value
            index += 1
        }
        for name in required where values[name] == nil {
            return .failure(UsageError(message: "missing required option '--\(name)'"))
        }
        return .success(values)
    }

    /// Runs a command. Progress goes to `out`, warnings to `err`.
    public static func run(_ command: Command, out: (String) -> Void, err: (String) -> Void) throws {
        switch command {
        case .help:
            out(usage)

        case .replay(let data, let outPath, let configPath, let modelPath, let mode, let sessionConfigPath):
            let config = try loadConfig(configPath)
            let source: ClassifierSource = modelPath.map { .coreML(modelURL: URL(fileURLWithPath: $0)) } ?? .heuristic
            let sessionConfig = mode == .session
                ? try loadSessionConfig(sessionConfigPath, pipeline: configPath == nil ? nil : config)
                : nil
            let result = try Replay.run(
                directory: URL(fileURLWithPath: data), config: config, source: source,
                mode: mode, sessionConfig: sessionConfig
            )
            warnSkipped(result.skipped, err: err)
            try write(try Replay.encode(result), to: outPath)
            out("replayed \(result.sessions.count) sessions (\(result.skipped.count) skipped) into \(outPath)")

        case .features(let data, let outPath, let configPath, let sessionConfigPath):
            let config = try loadConfig(configPath)
            let sessionConfig = try loadSessionConfig(sessionConfigPath, pipeline: configPath == nil ? nil : config)
            let loaded = try SessionLoader.load(directory: URL(fileURLWithPath: data))
            warnSkipped(loaded.skipped, err: err)
            let csv = FeaturesCSV.render(sessions: loaded.sessions, config: config, sessionConfig: sessionConfig)
            try write(Data(csv.utf8), to: outPath)
            out("wrote features for \(loaded.sessions.count) sessions into \(outPath)")

        case .synth(let outPath, let seed):
            let names = try SyntheticDataset.write(to: URL(fileURLWithPath: outPath), seed: seed)
            out("wrote \(names.count) synthetic sessions (seed \(seed)) into \(outPath)")

        case .synthOne(let name, let outPath, let seed):
            let fileName = try SyntheticDataset.writeSession(named: name, to: URL(fileURLWithPath: outPath), seed: seed)
            out("wrote synthetic session \(name) (seed \(seed)) as \(fileName) into \(outPath)")
        }
    }

    /// Process entry point: returns the exit code.
    public static func main(arguments: [String], out: (String) -> Void, err: (String) -> Void) -> Int32 {
        switch parse(arguments) {
        case .failure(let problem):
            err("error: \(problem.message)\n\n\(usage)")
            return 2
        case .success(let command):
            do {
                try run(command, out: out, err: err)
                return 0
            } catch {
                err("error: \(error)")
                return 1
            }
        }
    }

    static func loadConfig(_ path: String?) throws -> PipelineConfig {
        guard let path else { return .default }
        do {
            return try JSONDecoder().decode(PipelineConfig.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        } catch {
            throw EvalError.configUnreadable(path, SessionLoader.describe(error))
        }
    }

    /// The session config from a file (the default when there is no path). A
    /// `pipeline` passed in (from `--config`) replaces the file's `pipeline` block.
    static func loadSessionConfig(_ path: String?, pipeline: PipelineConfig? = nil) throws -> SessionConfig {
        var config = SessionConfig.default
        if let path {
            do {
                config = try JSONDecoder().decode(SessionConfig.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            } catch {
                throw EvalError.configUnreadable(path, SessionLoader.describe(error))
            }
        }
        if let pipeline { config.pipeline = pipeline }
        return config
    }

    private static func warnSkipped(_ skipped: [SkippedFile], err: (String) -> Void) {
        for item in skipped {
            err("warning: skipping \(item.file): \(item.reason)")
        }
    }

    private static func write(_ data: Data, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            throw EvalError.writeFailed(path, error.localizedDescription)
        }
    }
}
