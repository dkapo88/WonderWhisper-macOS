import Foundation

/// Cheap structural check of a Qwen safetensors checkpoint before MLX sees it.
///
/// mlx-swift 0.31.6 loads weights lazily and its `Load` primitive waits on the
/// file-read future with `wait()` instead of `get()`, so a failed `pread`
/// (truncated file, I/O error) is swallowed: eval "succeeds", the weights stay
/// uninitialized, and greedy decode emits 448 `!` tokens. `checkedEval` cannot
/// see that error. This check reads only the JSON headers (~70 KB) and proves
/// every tensor's byte range is inside its file, which catches truncation.
/// Anything subtler is left to the load-time canary decode.
enum QwenWeightIntegrity {
  struct ShardReport: Equatable {
    let file: String
    let fileSize: Int64
    let dataEnd: Int64
    let tensorCount: Int
  }

  enum Failure: Error, Equatable, CustomStringConvertible {
    case noShards
    case missingShard(String)
    case unreadable(String, String)
    case badHeader(String, String)
    case truncated(file: String, fileSize: Int64, needed: Int64)

    var description: String {
      switch self {
      case .noShards:
        return "no safetensors shards"
      case .missingShard(let file):
        return "missing shard \(file)"
      case .unreadable(let file, let reason):
        return "cannot read \(file): \(reason)"
      case .badHeader(let file, let reason):
        return "bad safetensors header in \(file): \(reason)"
      case .truncated(let file, let fileSize, let needed):
        return "\(file) is truncated (\(fileSize) bytes, tensors need \(needed))"
      }
    }
  }

  static let indexFileName = "model.safetensors.index.json"
  /// Real headers are ~70 KB; anything near this is corruption, not a header.
  static let maxHeaderBytes: UInt64 = 64 * 1024 * 1024

  /// Shard file names the loader will read: the index's weight_map values, or
  /// every `*.safetensors` in the directory when there is no index.
  static func shardNames(in directory: URL) throws -> [String] {
    let fm = FileManager.default
    let index = directory.appendingPathComponent(indexFileName)
    if fm.fileExists(atPath: index.path) {
      let data: Data
      do {
        data = try Data(contentsOf: index)
      } catch {
        throw Failure.unreadable(indexFileName, error.localizedDescription)
      }
      guard
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let map = json["weight_map"] as? [String: String]
      else {
        throw Failure.badHeader(indexFileName, "no weight_map")
      }
      let names = Array(Set(map.values)).sorted()
      guard !names.isEmpty else { throw Failure.noShards }
      return names
    }
    let items = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
    let names = items.filter { $0.hasSuffix(".safetensors") }.sorted()
    guard !names.isEmpty else { throw Failure.noShards }
    return names
  }

  /// Validates every shard. Throws the first failure.
  static func verify(directory: URL) throws -> [ShardReport] {
    try shardNames(in: directory).map { name in
      let url = directory.appendingPathComponent(name)
      guard FileManager.default.fileExists(atPath: url.path) else {
        throw Failure.missingShard(name)
      }
      return try verifyShard(at: url)
    }
  }

  static func verifyShard(at url: URL) throws -> ShardReport {
    let name = url.lastPathComponent
    let handle: FileHandle
    do {
      handle = try FileHandle(forReadingFrom: url)
    } catch {
      throw Failure.unreadable(name, error.localizedDescription)
    }
    defer { try? handle.close() }

    let fileSize: Int64
    do {
      fileSize = Int64(try handle.seekToEnd())
      try handle.seek(toOffset: 0)
    } catch {
      throw Failure.unreadable(name, error.localizedDescription)
    }

    let lengthBytes: Data
    do {
      lengthBytes = try handle.read(upToCount: 8) ?? Data()
    } catch {
      throw Failure.unreadable(name, error.localizedDescription)
    }
    guard lengthBytes.count == 8 else { throw Failure.badHeader(name, "file shorter than 8 bytes") }
    let headerLength = lengthBytes.enumerated().reduce(UInt64(0)) { acc, pair in
      acc | (UInt64(pair.element) << (8 * UInt64(pair.offset)))
    }
    guard headerLength > 0, headerLength <= maxHeaderBytes else {
      throw Failure.badHeader(name, "header length \(headerLength)")
    }
    guard Int64(8 + headerLength) <= fileSize else {
      throw Failure.truncated(file: name, fileSize: fileSize, needed: Int64(8 + headerLength))
    }

    let headerData: Data
    do {
      headerData = try handle.read(upToCount: Int(headerLength)) ?? Data()
    } catch {
      throw Failure.unreadable(name, error.localizedDescription)
    }
    guard headerData.count == Int(headerLength),
          let header = try? JSONSerialization.jsonObject(with: headerData) as? [String: Any]
    else {
      throw Failure.badHeader(name, "header is not JSON")
    }

    var maxEnd: Int64 = 0
    var tensors = 0
    for (key, value) in header where key != "__metadata__" {
      guard let entry = value as? [String: Any],
            let offsets = entry["data_offsets"] as? [NSNumber],
            offsets.count == 2
      else {
        throw Failure.badHeader(name, "tensor \(key) has no data_offsets")
      }
      let begin = offsets[0].int64Value
      let end = offsets[1].int64Value
      guard begin >= 0, end >= begin else {
        throw Failure.badHeader(name, "tensor \(key) has offsets \(begin)..\(end)")
      }
      maxEnd = max(maxEnd, end)
      tensors += 1
    }
    let needed = 8 + Int64(headerLength) + maxEnd
    guard needed <= fileSize else {
      throw Failure.truncated(file: name, fileSize: fileSize, needed: needed)
    }
    return ShardReport(file: name, fileSize: fileSize, dataEnd: needed, tensorCount: tensors)
  }

  /// "name=bytes" for every regular file in the model directory, for load logs.
  static func fileSizeSummary(in directory: URL) -> String {
    let fm = FileManager.default
    let names = ((try? fm.contentsOfDirectory(atPath: directory.path)) ?? [])
      .filter { !$0.hasPrefix(".") }
      .sorted()
    return names.map { name -> String in
      let path = directory.appendingPathComponent(name).path
      let size = (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
      return "\(name)=\(size.map(String.init) ?? "?")"
    }
    .joined(separator: " ")
  }
}
